//! Tabela de mensagens — Fase 3.
//!
//! Tudo aqui já passou pela sessão: o corpo persistido de uma mensagem de
//! texto é sempre plaintext já decifrado (recebida) ou ainda não cifrado
//! (pendente de envio) — a cifragem em si é responsabilidade de
//! `crypto::ratchet`/`crypto::aead`, chamada pela camada de sessão antes de
//! qualquer bytes irem para a rede. Cifrar o banco em repouso (D7) protege
//! contra quem tem acesso ao arquivo, não substitui a cifragem de sessão.
//!
//! `PacketType::MsgTyping` nunca entra aqui — é um indicador efêmero por
//! desenho (`docs/protocol.md` §6.2) — as funções de inserção recusam com
//! `Error::InvalidState` em vez de silenciosamente persistir, como uma
//! segunda barreira além da checagem que a camada FFI já faz.

use crate::wire::packet_type::PacketType;
use crate::{Error, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Outgoing = 0,
    Incoming = 1,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeliveryState {
    /// Persistida, ainda não entregue ao transporte.
    Pending = 0,
    /// Entregue ao transporte (`RTCDataChannel.send` retornou sem erro).
    Sent = 1,
    /// Confirmada pelo par (via `MSG_RECEIPT`) — nenhum código ainda produz
    /// este estado; reservado para a tela de chat (Fase 3, F6).
    Delivered = 2,
    /// O transporte relatou falha permanente de envio — nenhum código ainda
    /// produz este estado; reservado para a Fase 3, F6.
    Failed = 3,
}

impl DeliveryState {
    fn from_i64(value: i64) -> Result<Self> {
        match value {
            0 => Ok(Self::Pending),
            1 => Ok(Self::Sent),
            2 => Ok(Self::Delivered),
            3 => Ok(Self::Failed),
            _ => Err(Error::Store),
        }
    }
}

/// Uma mensagem já persistida, como a UI/outbox precisam dela.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredMessage {
    pub id: i64,
    pub direction: Direction,
    /// `MsgText` ou `AudioChunk` (Fase 5) — os únicos dois tipos que chegam
    /// a esta tabela. Para `AudioChunk`, `body` é `hex(file_id)`, não texto
    /// de verdade — decidido em `ffi/transfer.rs`/`ffi/session.rs`, que são
    /// quem monta e interpreta esse valor; esta camada só guarda e devolve.
    pub packet_type: PacketType,
    pub body: String,
    pub delivery_state: DeliveryState,
    pub created_at_unix_secs: i64,
}

fn reject_typing(packet_type: PacketType) -> Result<()> {
    if packet_type == PacketType::MsgTyping {
        return Err(Error::InvalidState(
            "MSG_TYPING é efêmero e nunca deve ser persistido",
        ));
    }
    Ok(())
}

/// Persiste uma mensagem de saída como `Pending`, antes de qualquer tentativa
/// de envio — a cifragem e o envio acontecem depois, de posse do `id`
/// devolvido aqui.
pub fn insert_pending(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
    packet_type: PacketType,
    body: &str,
    created_at_unix_secs: i64,
) -> Result<i64> {
    reject_typing(packet_type)?;
    insert(
        conn,
        contact_device_id,
        Direction::Outgoing,
        packet_type,
        body,
        DeliveryState::Pending,
        created_at_unix_secs,
    )
}

/// Persiste uma mensagem recebida e já decifrada.
pub fn insert_incoming(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
    packet_type: PacketType,
    body: &str,
    received_at_unix_secs: i64,
) -> Result<i64> {
    reject_typing(packet_type)?;
    insert(
        conn,
        contact_device_id,
        Direction::Incoming,
        packet_type,
        body,
        DeliveryState::Delivered,
        received_at_unix_secs,
    )
}

#[allow(clippy::too_many_arguments)]
fn insert(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
    direction: Direction,
    packet_type: PacketType,
    body: &str,
    delivery_state: DeliveryState,
    created_at_unix_secs: i64,
) -> Result<i64> {
    conn.execute(
        "INSERT INTO messages
            (contact_device_id, direction, packet_type, body, delivery_state, ratchet_counter, created_at_unix_secs)
         VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6)",
        rusqlite::params![
            contact_device_id.as_slice(),
            direction as i64,
            packet_type.to_u8(),
            body,
            delivery_state as i64,
            created_at_unix_secs,
        ],
    )
    .map_err(|_| Error::Store)?;

    Ok(conn.last_insert_rowid())
}

/// Marca uma mensagem de saída como entregue ao transporte.
///
/// Idempotente por construção da query (`UPDATE` sem condição de estado): se
/// a linha não existe mais, ou já está marcada, isso não é um erro — quem
/// chama já tem o resultado que queria.
pub fn mark_sent(conn: &rusqlite::Connection, message_id: i64) -> Result<()> {
    conn.execute(
        "UPDATE messages SET delivery_state = ?1 WHERE id = ?2",
        rusqlite::params![DeliveryState::Sent as i64, message_id],
    )
    .map_err(|_| Error::Store)?;
    Ok(())
}

/// Todas as mensagens de um contato, mais antigas primeiro.
pub fn list_for_contact(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
) -> Result<Vec<StoredMessage>> {
    let mut statement = conn
        .prepare(
            "SELECT id, direction, packet_type, body, delivery_state, created_at_unix_secs
             FROM messages
             WHERE contact_device_id = ?1
             ORDER BY created_at_unix_secs ASC, id ASC",
        )
        .map_err(|_| Error::Store)?;

    let rows = statement
        .query_map([contact_device_id.as_slice()], row_to_message)
        .map_err(|_| Error::Store)?;

    let mut messages = Vec::new();
    for row in rows {
        messages.push(row.map_err(|_| Error::Store)?);
    }
    Ok(messages)
}

/// Mensagens de saída ainda não entregues, mais antigas primeiro — a fila que
/// o outbox (Fase 3, F6) drena assim que o transporte fica disponível.
pub fn list_pending(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
) -> Result<Vec<StoredMessage>> {
    let mut statement = conn
        .prepare(
            "SELECT id, direction, packet_type, body, delivery_state, created_at_unix_secs
             FROM messages
             WHERE contact_device_id = ?1 AND direction = ?2 AND delivery_state = ?3
             ORDER BY created_at_unix_secs ASC, id ASC",
        )
        .map_err(|_| Error::Store)?;

    let rows = statement
        .query_map(
            rusqlite::params![
                contact_device_id.as_slice(),
                Direction::Outgoing as i64,
                DeliveryState::Pending as i64,
            ],
            row_to_message,
        )
        .map_err(|_| Error::Store)?;

    let mut messages = Vec::new();
    for row in rows {
        messages.push(row.map_err(|_| Error::Store)?);
    }
    Ok(messages)
}

fn row_to_message(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredMessage> {
    let id: i64 = row.get(0)?;
    let direction: i64 = row.get(1)?;
    let packet_type: i64 = row.get(2)?;
    let body: String = row.get(3)?;
    let delivery_state: i64 = row.get(4)?;
    let created_at_unix_secs: i64 = row.get(5)?;

    let direction = match direction {
        0 => Direction::Outgoing,
        1 => Direction::Incoming,
        _ => return Err(rusqlite::Error::InvalidQuery),
    };
    let packet_type =
        PacketType::from_u8(packet_type as u8).map_err(|_| rusqlite::Error::InvalidQuery)?;
    let delivery_state =
        DeliveryState::from_i64(delivery_state).map_err(|_| rusqlite::Error::InvalidQuery)?;

    Ok(StoredMessage {
        id,
        direction,
        packet_type,
        body,
        delivery_state,
        created_at_unix_secs,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::schema::migrate;

    fn conn_with_contact(device_id: [u8; 16]) -> rusqlite::Connection {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        migrate(&conn).unwrap();
        conn.execute(
            "INSERT INTO contacts (device_id, signing_pubkey, dh_pubkey, paired_at, nickname)
             VALUES (?1, ?2, ?3, 1700000000, NULL)",
            rusqlite::params![device_id.as_slice(), [1u8; 32], [2u8; 32]],
        )
        .unwrap();
        conn
    }

    #[test]
    fn mensagem_pendente_e_persistida_e_listada() {
        let contact = [7u8; 16];
        let conn = conn_with_contact(contact);

        let id = insert_pending(&conn, &contact, PacketType::MsgText, "oi", 1000).unwrap();

        let listed = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, id);
        assert_eq!(listed[0].direction, Direction::Outgoing);
        assert_eq!(listed[0].body, "oi");
        assert_eq!(listed[0].delivery_state, DeliveryState::Pending);
    }

    #[test]
    fn mensagem_recebida_e_persistida_como_delivered() {
        let contact = [8u8; 16];
        let conn = conn_with_contact(contact);

        insert_incoming(&conn, &contact, PacketType::MsgText, "recebida", 2000).unwrap();

        let listed = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed[0].direction, Direction::Incoming);
        assert_eq!(listed[0].delivery_state, DeliveryState::Delivered);
    }

    #[test]
    fn msg_typing_e_rejeitada_em_ambas_as_insercoes() {
        let contact = [9u8; 16];
        let conn = conn_with_contact(contact);

        assert!(matches!(
            insert_pending(&conn, &contact, PacketType::MsgTyping, "", 0),
            Err(Error::InvalidState(_))
        ));
        assert!(matches!(
            insert_incoming(&conn, &contact, PacketType::MsgTyping, "", 0),
            Err(Error::InvalidState(_))
        ));
        assert!(list_for_contact(&conn, &contact).unwrap().is_empty());
    }

    #[test]
    fn mark_sent_muda_o_estado_e_e_idempotente() {
        let contact = [10u8; 16];
        let conn = conn_with_contact(contact);
        let id = insert_pending(&conn, &contact, PacketType::MsgText, "x", 0).unwrap();

        mark_sent(&conn, id).unwrap();
        mark_sent(&conn, id).unwrap(); // segunda chamada não deveria errar

        let listed = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed[0].delivery_state, DeliveryState::Sent);
    }

    #[test]
    fn mark_sent_de_id_inexistente_nao_erra() {
        let contact = [11u8; 16];
        let conn = conn_with_contact(contact);
        mark_sent(&conn, 99999).unwrap();
    }

    #[test]
    fn list_pending_so_traz_saida_ainda_nao_enviada() {
        let contact = [12u8; 16];
        let conn = conn_with_contact(contact);

        let pendente = insert_pending(&conn, &contact, PacketType::MsgText, "a", 0).unwrap();
        let ja_enviada = insert_pending(&conn, &contact, PacketType::MsgText, "b", 1).unwrap();
        mark_sent(&conn, ja_enviada).unwrap();
        insert_incoming(&conn, &contact, PacketType::MsgText, "c", 2).unwrap();

        let pending = list_pending(&conn, &contact).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].id, pendente);
    }

    #[test]
    fn ordem_e_sempre_do_mais_antigo_para_o_mais_novo() {
        let contact = [13u8; 16];
        let conn = conn_with_contact(contact);

        insert_incoming(&conn, &contact, PacketType::MsgText, "terceira", 300).unwrap();
        insert_incoming(&conn, &contact, PacketType::MsgText, "primeira", 100).unwrap();
        insert_incoming(&conn, &contact, PacketType::MsgText, "segunda", 200).unwrap();

        let listed = list_for_contact(&conn, &contact).unwrap();
        let bodies: Vec<&str> = listed.iter().map(|m| m.body.as_str()).collect();
        assert_eq!(bodies, vec!["primeira", "segunda", "terceira"]);
    }
}
