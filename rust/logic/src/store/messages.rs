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

use rusqlite::OptionalExtension;
use zeroize::Zeroize;

use crate::wire::packet_type::PacketType;
use crate::{Error, Result};

pub const UNREAD_EXPIRATION_CEILING_SECS: i64 = 7 * 86400; // 7 dias de teto se não lida
pub const EPHEMERAL_AAD: &[u8] = b"viska-ephemeral-body-v1";
pub const EXPIRED_BODY_PLACEHOLDER: &str = "<mensagem expirada e destruída>";

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
    pub is_ephemeral: bool,
    pub reply_to_id: Option<i64>,
    pub view_once: bool,
    pub reactions: Vec<String>,
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
/// de envio. Se o contato tiver TTL efêmero configurado, o corpo é cifrado
/// com uma chave individual descartável `K_msg` (F3 / D13).
pub fn insert_pending(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
    packet_type: PacketType,
    body: &str,
    created_at_unix_secs: i64,
) -> Result<i64> {
    insert_pending_opts(
        conn,
        contact_device_id,
        packet_type,
        body,
        created_at_unix_secs,
        None,
        false,
    )
}

/// Persiste uma mensagem de saída como `Pending` com opções de resposta e visualização única.
pub fn insert_pending_opts(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
    packet_type: PacketType,
    body: &str,
    created_at_unix_secs: i64,
    reply_to_id: Option<i64>,
    view_once: bool,
) -> Result<i64> {
    reject_typing(packet_type)?;
    let ttl = crate::store::contacts::get_ephemeral_ttl(conn, contact_device_id).unwrap_or(0);
    insert_with_options(
        conn,
        contact_device_id,
        Direction::Outgoing,
        packet_type,
        body,
        DeliveryState::Pending,
        created_at_unix_secs,
        ttl,
        reply_to_id,
        view_once,
    )
}

/// Persiste uma mensagem recebida e já decifrada pela sessão.
pub fn insert_incoming(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
    packet_type: PacketType,
    body: &str,
    received_at_unix_secs: i64,
) -> Result<i64> {
    insert_incoming_opts(
        conn,
        contact_device_id,
        packet_type,
        body,
        received_at_unix_secs,
        None,
        false,
    )
}

/// Persiste uma mensagem recebida com opções de resposta e visualização única.
pub fn insert_incoming_opts(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
    packet_type: PacketType,
    body: &str,
    received_at_unix_secs: i64,
    reply_to_id: Option<i64>,
    view_once: bool,
) -> Result<i64> {
    reject_typing(packet_type)?;
    let ttl = crate::store::contacts::get_ephemeral_ttl(conn, contact_device_id).unwrap_or(0);
    insert_with_options(
        conn,
        contact_device_id,
        Direction::Incoming,
        packet_type,
        body,
        DeliveryState::Delivered,
        received_at_unix_secs,
        ttl,
        reply_to_id,
        view_once,
    )
}

/// Inserção de mensagem com TTL efêmero explícito.
#[allow(clippy::too_many_arguments)]
pub fn insert_with_ttl(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
    direction: Direction,
    packet_type: PacketType,
    body: &str,
    delivery_state: DeliveryState,
    created_at_unix_secs: i64,
    ttl_secs: i64,
) -> Result<i64> {
    insert_with_options(
        conn,
        contact_device_id,
        direction,
        packet_type,
        body,
        delivery_state,
        created_at_unix_secs,
        ttl_secs,
        None,
        false,
    )
}

/// Inserção completa de mensagem com TTL, reply_to_id e view_once.
#[allow(clippy::too_many_arguments)]
pub fn insert_with_options(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
    direction: Direction,
    packet_type: PacketType,
    body: &str,
    delivery_state: DeliveryState,
    created_at_unix_secs: i64,
    ttl_secs: i64,
    reply_to_id: Option<i64>,
    view_once: bool,
) -> Result<i64> {
    reject_typing(packet_type)?;

    let is_ephemeral = ttl_secs > 0 || view_once;
    let view_once_int = if view_once { 1 } else { 0 };
    if is_ephemeral {
        // Criptografia individual por mensagem com chave descartável K_msg (F3 / D13).
        let k_msg_bytes = crate::util::rng::array::<32>()?;
        let k_msg = crate::crypto::kdf::Key::from_bytes(k_msg_bytes);
        let mut cipher_buf = body.as_bytes().to_vec();
        crate::crypto::aead::seal_xchacha(&k_msg, EPHEMERAL_AAD, &mut cipher_buf)?;
        let hex_body = hex::encode(&cipher_buf);
        cipher_buf.zeroize();

        conn.execute(
            "INSERT INTO messages
                (contact_device_id, direction, packet_type, body, delivery_state, ratchet_counter, created_at_unix_secs, is_ephemeral, reply_to_id, view_once)
             VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, 1, ?7, ?8)",
            rusqlite::params![
                contact_device_id.as_slice(),
                direction as i64,
                packet_type.to_u8(),
                hex_body,
                delivery_state as i64,
                created_at_unix_secs,
                reply_to_id,
                view_once_int,
            ],
        )
        .map_err(|_| Error::Store)?;

        let message_id = conn.last_insert_rowid();

        let effective_ttl = if ttl_secs > 0 { ttl_secs } else { 60 };
        let (read_at, expires_at) = match direction {
            Direction::Outgoing => {
                // Mensagem de saída: conta a partir da criação
                (Some(created_at_unix_secs), created_at_unix_secs.saturating_add(effective_ttl))
            }
            Direction::Incoming => {
                // Mensagem de entrada: aguarda leitura (com teto máximo se não lida)
                (None, created_at_unix_secs.saturating_add(UNREAD_EXPIRATION_CEILING_SECS))
            }
        };

        conn.execute(
            "INSERT INTO ephemeral_message_keys (message_id, key, read_at, expires_at)
             VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![
                message_id,
                k_msg.as_bytes().as_slice(),
                read_at,
                expires_at,
            ],
        )
        .map_err(|_| Error::Store)?;

        Ok(message_id)
    } else {
        conn.execute(
            "INSERT INTO messages
                (contact_device_id, direction, packet_type, body, delivery_state, ratchet_counter, created_at_unix_secs, is_ephemeral, reply_to_id, view_once)
             VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, 0, ?7, ?8)",
            rusqlite::params![
                contact_device_id.as_slice(),
                direction as i64,
                packet_type.to_u8(),
                body,
                delivery_state as i64,
                created_at_unix_secs,
                reply_to_id,
                view_once_int,
            ],
        )
        .map_err(|_| Error::Store)?;

        Ok(conn.last_insert_rowid())
    }
}

/// Marca uma mensagem efêmera como lida, disparando o temporizador regressivo
/// a partir do carimbo de data/hora atual (`unix_now`).
pub fn mark_message_read(
    conn: &rusqlite::Connection,
    message_id: i64,
    unix_now: i64,
) -> Result<()> {
    let ttl: Option<i64> = conn
        .query_row(
            "SELECT c.ephemeral_ttl FROM messages m
             JOIN contacts c ON m.contact_device_id = c.device_id
             WHERE m.id = ?1",
            [message_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| Error::Store)?;

    if let Some(ttl) = ttl {
        if ttl > 0 {
            let expires_at = unix_now.saturating_add(ttl);
            conn.execute(
                "UPDATE ephemeral_message_keys
                 SET read_at = ?1, expires_at = ?2
                 WHERE message_id = ?3 AND read_at IS NULL",
                rusqlite::params![unix_now, expires_at, message_id],
            )
            .map_err(|_| Error::Store)?;
        }
    }
    Ok(())
}

/// Destrói chaves de mensagens efêmeras vencidas (crypto-shredding por mensagem).
pub fn sweep_expired_ephemeral_messages(
    conn: &rusqlite::Connection,
    unix_now: i64,
) -> Result<usize> {
    let deleted = conn
        .execute(
            "DELETE FROM ephemeral_message_keys WHERE expires_at <= ?1",
            [unix_now],
        )
        .map_err(|_| Error::Store)?;
    Ok(deleted)
}

/// Marca uma mensagem de saída como entregue ao transporte.
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
            "SELECT id, direction, packet_type, body, delivery_state, created_at_unix_secs, is_ephemeral, reply_to_id, view_once
             FROM messages
             WHERE contact_device_id = ?1
             ORDER BY created_at_unix_secs ASC, id ASC",
        )
        .map_err(|_| Error::Store)?;

    let rows = statement
        .query_map([contact_device_id.as_slice()], |row| {
            let id: i64 = row.get(0)?;
            let direction: i64 = row.get(1)?;
            let packet_type: i64 = row.get(2)?;
            let raw_body: String = row.get(3)?;
            let delivery_state: i64 = row.get(4)?;
            let created_at_unix_secs: i64 = row.get(5)?;
            let is_ephemeral: i64 = row.get(6)?;
            let reply_to_id: Option<i64> = row.get(7)?;
            let view_once: i64 = row.get(8).unwrap_or(0);
            Ok((id, direction, packet_type, raw_body, delivery_state, created_at_unix_secs, is_ephemeral, reply_to_id, view_once))
        })
        .map_err(|_| Error::Store)?;

    let mut messages = Vec::new();
    for row in rows {
        let (id, direction, packet_type, raw_body, delivery_state, created_at_unix_secs, is_ephemeral, reply_to_id, view_once) =
            row.map_err(|_| Error::Store)?;

        let direction = match direction {
            0 => Direction::Outgoing,
            1 => Direction::Incoming,
            _ => return Err(Error::Store),
        };
        let packet_type =
            PacketType::from_u8(packet_type as u8).map_err(|_| Error::Store)?;
        let delivery_state =
            DeliveryState::from_i64(delivery_state)?;
        let is_ephemeral = is_ephemeral != 0;

        let body = decode_ephemeral_or_plain(conn, id, raw_body, is_ephemeral)?;
        let reactions = get_reactions_for_message(conn, id)?;

        messages.push(StoredMessage {
            id,
            direction,
            packet_type,
            body,
            delivery_state,
            created_at_unix_secs,
            is_ephemeral,
            reply_to_id,
            view_once: view_once != 0,
            reactions,
        });
    }
    Ok(messages)
}

/// Mensagens de saída ainda não entregues, mais antigas primeiro.
pub fn list_pending(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
) -> Result<Vec<StoredMessage>> {
    let mut statement = conn
        .prepare(
            "SELECT id, direction, packet_type, body, delivery_state, created_at_unix_secs, is_ephemeral, reply_to_id, view_once
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
            |row| {
                let id: i64 = row.get(0)?;
                let direction: i64 = row.get(1)?;
                let packet_type: i64 = row.get(2)?;
                let raw_body: String = row.get(3)?;
                let delivery_state: i64 = row.get(4)?;
                let created_at_unix_secs: i64 = row.get(5)?;
                let is_ephemeral: i64 = row.get(6)?;
                let reply_to_id: Option<i64> = row.get(7)?;
                let view_once: i64 = row.get(8).unwrap_or(0);
                Ok((id, direction, packet_type, raw_body, delivery_state, created_at_unix_secs, is_ephemeral, reply_to_id, view_once))
            },
        )
        .map_err(|_| Error::Store)?;

    let mut messages = Vec::new();
    for row in rows {
        let (id, direction, packet_type, raw_body, delivery_state, created_at_unix_secs, is_ephemeral, reply_to_id, view_once) =
            row.map_err(|_| Error::Store)?;

        let direction = match direction {
            0 => Direction::Outgoing,
            1 => Direction::Incoming,
            _ => return Err(Error::Store),
        };
        let packet_type =
            PacketType::from_u8(packet_type as u8).map_err(|_| Error::Store)?;
        let delivery_state =
            DeliveryState::from_i64(delivery_state)?;
        let is_ephemeral = is_ephemeral != 0;

        let body = decode_ephemeral_or_plain(conn, id, raw_body, is_ephemeral)?;

        messages.push(StoredMessage {
            id,
            direction,
            packet_type,
            body,
            delivery_state,
            created_at_unix_secs,
            is_ephemeral,
            reply_to_id,
            view_once: view_once != 0,
            reactions: Vec::new(),
        });
    }
    Ok(messages)
}

/// Adiciona ou substitui uma reação emoji de um contato em uma mensagem.
pub fn add_reaction(
    conn: &rusqlite::Connection,
    message_id: i64,
    contact_device_id: &[u8; 16],
    emoji: &str,
    created_at_unix_secs: i64,
) -> Result<()> {
    conn.execute(
        "INSERT INTO message_reactions (message_id, contact_device_id, emoji, created_at_unix_secs)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(message_id, contact_device_id) DO UPDATE SET
             emoji = excluded.emoji,
             created_at_unix_secs = excluded.created_at_unix_secs",
        rusqlite::params![
            message_id,
            contact_device_id.as_slice(),
            emoji,
            created_at_unix_secs,
        ],
    )
    .map_err(|_| Error::Store)?;
    Ok(())
}

/// Consulta todas as reações emoji vinculadas a uma mensagem.
pub fn get_reactions_for_message(
    conn: &rusqlite::Connection,
    message_id: i64,
) -> Result<Vec<String>> {
    let mut statement = conn
        .prepare(
            "SELECT emoji FROM message_reactions
             WHERE message_id = ?1
             ORDER BY created_at_unix_secs ASC",
        )
        .map_err(|_| Error::Store)?;

    let rows = statement
        .query_map([message_id], |row| row.get(0))
        .map_err(|_| Error::Store)?;

    let mut reactions = Vec::new();
    for r in rows {
        reactions.push(r.map_err(|_| Error::Store)?);
    }
    Ok(reactions)
}

fn decode_ephemeral_or_plain(
    conn: &rusqlite::Connection,
    message_id: i64,
    raw_body: String,
    is_ephemeral: bool,
) -> Result<String> {
    if !is_ephemeral {
        return Ok(raw_body);
    }

    let key_opt: Option<Vec<u8>> = conn
        .query_row(
            "SELECT key FROM ephemeral_message_keys WHERE message_id = ?1",
            [message_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| Error::Store)?;

    match key_opt {
        Some(key_bytes) if key_bytes.len() == 32 => {
            let mut key_arr = [0u8; 32];
            key_arr.copy_from_slice(&key_bytes);
            let key = crate::crypto::kdf::Key::from_bytes(key_arr);
            match hex::decode(&raw_body) {
                Ok(mut cipher_buf) => {
                    let result = match crate::crypto::aead::open_xchacha(
                        &key,
                        EPHEMERAL_AAD,
                        &mut cipher_buf,
                    ) {
                        Ok(()) => String::from_utf8_lossy(&cipher_buf).to_string(),
                        Err(_) => "<mensagem efêmera corrompida>".to_string(),
                    };
                    cipher_buf.zeroize();
                    Ok(result)
                }
                Err(_) => Ok("<mensagem efêmera malformada>".to_string()),
            }
        }
        _ => Ok(EXPIRED_BODY_PLACEHOLDER.to_string()),
    }
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
    fn pending_message_is_persisted_and_listed() {
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
    fn incoming_message_is_persisted_as_delivered() {
        let contact = [8u8; 16];
        let conn = conn_with_contact(contact);

        insert_incoming(&conn, &contact, PacketType::MsgText, "recebida", 2000).unwrap();

        let listed = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed[0].direction, Direction::Incoming);
        assert_eq!(listed[0].delivery_state, DeliveryState::Delivered);
    }

    #[test]
    fn msg_typing_is_rejected_in_both_insertions() {
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
    fn mark_sent_changes_state_and_is_idempotent() {
        let contact = [10u8; 16];
        let conn = conn_with_contact(contact);
        let id = insert_pending(&conn, &contact, PacketType::MsgText, "x", 0).unwrap();

        mark_sent(&conn, id).unwrap();
        mark_sent(&conn, id).unwrap(); // segunda chamada não deveria errar

        let listed = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed[0].delivery_state, DeliveryState::Sent);
    }

    #[test]
    fn mark_sent_on_nonexistent_id_does_not_error() {
        let contact = [11u8; 16];
        let conn = conn_with_contact(contact);
        mark_sent(&conn, 99999).unwrap();
    }

    #[test]
    fn list_pending_only_returns_unsent_outgoing_messages() {
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
    fn order_is_always_oldest_to_newest() {
        let contact = [13u8; 16];
        let conn = conn_with_contact(contact);

        insert_incoming(&conn, &contact, PacketType::MsgText, "terceira", 300).unwrap();
        insert_incoming(&conn, &contact, PacketType::MsgText, "primeira", 100).unwrap();
        insert_incoming(&conn, &contact, PacketType::MsgText, "segunda", 200).unwrap();

        let listed = list_for_contact(&conn, &contact).unwrap();
        let bodies: Vec<&str> = listed.iter().map(|m| m.body.as_str()).collect();
        assert_eq!(bodies, vec!["primeira", "segunda", "terceira"]);
    }

    #[test]
    fn ephemeral_message_encrypted_with_k_msg_and_destroyed_upon_expiry() {
        let contact = [14u8; 16];
        let conn = conn_with_contact(contact);

        // Ativa TTL de 60 segundos
        crate::store::contacts::set_ephemeral_ttl(&conn, &contact, 60).unwrap();

        let id = insert_incoming(&conn, &contact, PacketType::MsgText, "segredo efêmero", 1000).unwrap();

        // Antes da leitura: mensagem pode ser lida (com teto padrão de não lida)
        let listed = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].body, "segredo efêmero");
        assert!(listed[0].is_ephemeral);

        // Marca como lida no tempo 1010 -> expiração passa a ser 1010 + 60 = 1070
        mark_message_read(&conn, id, 1010).unwrap();

        // No tempo 1060: ainda não expirou
        assert_eq!(list_for_contact(&conn, &contact).unwrap()[0].body, "segredo efêmero");

        // No tempo 1071: expira e é varrida
        let swept = sweep_expired_ephemeral_messages(&conn, 1071).unwrap();
        assert_eq!(swept, 1);

        // Releitura: chave K_msg foi destruída (crypto-shredding), corpo exibe placeholder
        let listed_after = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed_after[0].body, EXPIRED_BODY_PLACEHOLDER);

        // Verifica que o corpo bruto no banco é hex cifrado, não plaintext
        let raw_body: String = conn
            .query_row("SELECT body FROM messages WHERE id = ?1", [id], |r| r.get(0))
            .unwrap();
        assert_ne!(raw_body, "segredo efêmero");
        assert!(hex::decode(&raw_body).is_ok());
    }

    #[test]
    fn unread_ephemeral_message_respects_expiration_ceiling() {
        let contact = [15u8; 16];
        let conn = conn_with_contact(contact);
        crate::store::contacts::set_ephemeral_ttl(&conn, &contact, 60).unwrap();

        insert_incoming(&conn, &contact, PacketType::MsgText, "nunca aberta", 1000).unwrap();

        // 6 dias depois: ainda viva
        sweep_expired_ephemeral_messages(&conn, 1000 + 6 * 86400).unwrap();
        assert_eq!(list_for_contact(&conn, &contact).unwrap()[0].body, "nunca aberta");

        // 8 dias depois (acima do teto de 7 dias): deve ser destruída
        sweep_expired_ephemeral_messages(&conn, 1000 + 8 * 86400).unwrap();
        assert_eq!(list_for_contact(&conn, &contact).unwrap()[0].body, EXPIRED_BODY_PLACEHOLDER);
    }

    #[test]
    fn message_with_reply_and_view_once() {
        let contact = [16u8; 16];
        let conn = conn_with_contact(contact);

        let id1 = insert_pending(&conn, &contact, PacketType::MsgText, "primeira mensagem", 1000).unwrap();
        let id2 = insert_pending_opts(
            &conn,
            &contact,
            PacketType::MsgText,
            "resposta à primeira",
            1005,
            Some(id1),
            true,
        )
        .unwrap();

        let listed = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed.len(), 2);
        assert_eq!(listed[0].id, id1);
        assert_eq!(listed[0].reply_to_id, None);
        assert!(!listed[0].view_once);

        assert_eq!(listed[1].id, id2);
        assert_eq!(listed[1].reply_to_id, Some(id1));
        assert!(listed[1].view_once);
        assert!(listed[1].is_ephemeral);
    }

    #[test]
    fn add_and_query_reactions_on_messages() {
        let contact = [17u8; 16];
        let conn = conn_with_contact(contact);

        let id = insert_incoming(&conn, &contact, PacketType::MsgText, "mensagem com reações", 1000).unwrap();

        // Adiciona reação
        add_reaction(&conn, id, &contact, "❤️", 1001).unwrap();
        let reactions = get_reactions_for_message(&conn, id).unwrap();
        assert_eq!(reactions, vec!["❤️"]);

        // Atualiza reação com novo emoji do mesmo contato
        add_reaction(&conn, id, &contact, "🔥", 1002).unwrap();
        let reactions_updated = get_reactions_for_message(&conn, id).unwrap();
        assert_eq!(reactions_updated, vec!["🔥"]);

        // Reações aparecem carregadas em list_for_contact
        let listed = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed[0].reactions, vec!["🔥"]);
    }
}
