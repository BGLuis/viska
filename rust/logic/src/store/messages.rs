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
    /// Cifrada e entregue ao Dart para envio, mas ainda sem `Sent`. Tira a
    /// linha de `list_pending`, de modo que duas drenagens seguidas não
    /// cifrem o mesmo corpo duas vezes.
    Sending = 4,
    /// O destinatário viu a oferta de arquivo e a recusou (`FILE_REJECT`, §7.7).
    /// `delivery_state` é INTEGER sem CHECK, então um estado novo não pede migration (em uso: 0 a 7; o próximo livre é o 8).
    Rejected = 5,
    /// Os bytes cifrados saíram do Rust, mas o processo morreu (ou a Core foi
    /// trancada) antes de saber se o transporte os entregou. Fica fora de
    /// `list_pending`: recifrar e reenviar sozinho entregaria a mesma mensagem
    /// duas vezes ao par. Só a pessoa decide reenviar (`resend_unknown`).
    Unknown = 6,
    /// O destinatário nunca respondeu à oferta dentro do prazo do emissor (§7.7).
    Expired = 7,
}

impl DeliveryState {
    fn from_i64(value: i64) -> Result<Self> {
        match value {
            0 => Ok(Self::Pending),
            1 => Ok(Self::Sent),
            2 => Ok(Self::Delivered),
            3 => Ok(Self::Failed),
            4 => Ok(Self::Sending),
            5 => Ok(Self::Rejected),
            6 => Ok(Self::Unknown),
            7 => Ok(Self::Expired),
            _ => Err(Error::Store),
        }
    }
}

/// Uma mensagem já persistida, como a UI/outbox precisam dela.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredMessage {
    pub id: i64,
    pub global_id: Option<String>,
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

fn reject_non_storable(packet_type: PacketType) -> Result<()> {
    if packet_type == PacketType::MsgTyping {
        return Err(Error::InvalidState(
            "MSG_TYPING é efêmero e nunca deve ser persistido",
        ));
    }
    if packet_type == PacketType::MsgReceipt {
        return Err(Error::InvalidState(
            "MSG_RECEIPT é um sinalizador de controle de entrega e nunca deve ser persistido na timeline",
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

#[derive(serde::Deserialize)]
struct BodyMetadataHelper {
    id: Option<String>,
    #[serde(rename = "viewOnce")]
    view_once: Option<bool>,
    reply: Option<ReplyMetadataHelper>,
}

#[derive(serde::Deserialize)]
struct ReplyMetadataHelper {
    id: Option<serde_json::Value>,
    #[serde(rename = "globalId")]
    global_id: Option<String>,
}

#[derive(serde::Deserialize)]
struct ReactionMetadataHelper {
    #[serde(rename = "type")]
    msg_type: Option<String>,
    #[serde(rename = "targetId")]
    target_id: Option<serde_json::Value>,
    emoji: Option<String>,
}

/// Identifica se o corpo transporta um comando estruturado de reação com emoji e destino.
pub fn parse_reaction_metadata(body: &str) -> Option<(String, String)> {
    let trimmed = body.trim_start();
    if !trimmed.starts_with('{') {
        return None;
    }
    if let Ok(parsed) = serde_json::from_str::<ReactionMetadataHelper>(trimmed) {
        if parsed.msg_type.as_deref() == Some("reaction") {
            let target_str = match parsed.target_id? {
                serde_json::Value::String(s) => s,
                serde_json::Value::Number(n) => n.to_string(),
                _ => return None,
            };
            let emoji = parsed.emoji?;
            return Some((target_str, emoji));
        }
    }
    None
}

/// Extrai metadados estruturados (global_id, reply_to_id, view_once) do payload JSON da mensagem.
fn parse_body_metadata(conn: &rusqlite::Connection, body: &str) -> (Option<String>, Option<i64>, bool) {
    let trimmed = body.trim_start();
    if !trimmed.starts_with('{') {
        return (None, None, false);
    }
    if let Ok(parsed) = serde_json::from_str::<BodyMetadataHelper>(trimmed) {
        let global_id = parsed.id;
        let view_once = parsed.view_once.unwrap_or(false);
        let mut reply_to_id = None;

        if let Some(r) = parsed.reply {
            // Tenta resolver primeiro via identificador global único
            if let Some(gid) = r.global_id {
                reply_to_id = conn
                    .query_row(
                        "SELECT id FROM messages WHERE global_id = ?1",
                        [gid],
                        |row| row.get(0),
                    )
                    .optional()
                    .unwrap_or(None);
            }
            if reply_to_id.is_none() {
                if let Some(val) = r.id {
                    match val {
                        serde_json::Value::String(s) => {
                            reply_to_id = conn
                                .query_row(
                                    "SELECT id FROM messages WHERE global_id = ?1",
                                    [&s],
                                    |row| row.get(0),
                                )
                                .optional()
                                .unwrap_or(None);
                            if reply_to_id.is_none() {
                                if let Ok(num) = s.parse::<i64>() {
                                    reply_to_id = conn
                                        .query_row(
                                            "SELECT id FROM messages WHERE id = ?1",
                                            [num],
                                            |row| row.get(0),
                                        )
                                        .optional()
                                        .unwrap_or(None);
                                }
                            }
                        }
                        serde_json::Value::Number(n) => {
                            if let Some(num) = n.as_i64() {
                                reply_to_id = conn
                                    .query_row(
                                        "SELECT id FROM messages WHERE id = ?1",
                                        [num],
                                        |row| row.get(0),
                                    )
                                    .optional()
                                    .unwrap_or(None);
                            }
                        }
                        _ => {}
                    }
                }
            }
        }

        (global_id, reply_to_id, view_once)
    } else {
        (None, None, false)
    }
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
    reject_non_storable(packet_type)?;
    let (meta_global_id, meta_reply, meta_view_once) = parse_body_metadata(conn, body);
    let final_reply = reply_to_id.or(meta_reply);
    let final_view_once = view_once || meta_view_once;
    let ttl = crate::store::contacts::get_ephemeral_ttl(conn, contact_device_id).unwrap_or(0);
    insert_with_options_internal(
        conn,
        contact_device_id,
        Direction::Outgoing,
        packet_type,
        body,
        DeliveryState::Pending,
        created_at_unix_secs,
        ttl,
        final_reply,
        final_view_once,
        meta_global_id,
    )
}

/// Persiste uma mensagem recebida e já decifrada pela sessão. Idempotente por `global_id`:
/// uma repetição devolve o id da linha existente.
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
    reject_non_storable(packet_type)?;
    let (meta_global_id, meta_reply, meta_view_once) = parse_body_metadata(conn, body);
    let final_reply = reply_to_id.or(meta_reply);
    let final_view_once = view_once || meta_view_once;
    let ttl = crate::store::contacts::get_ephemeral_ttl(conn, contact_device_id).unwrap_or(0);
    insert_with_options_internal(
        conn,
        contact_device_id,
        Direction::Incoming,
        packet_type,
        body,
        DeliveryState::Delivered,
        received_at_unix_secs,
        ttl,
        final_reply,
        final_view_once,
        meta_global_id,
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
    let (meta_global_id, meta_reply, meta_view_once) = parse_body_metadata(conn, body);
    let final_reply = reply_to_id.or(meta_reply);
    let final_view_once = view_once || meta_view_once;
    insert_with_options_internal(
        conn,
        contact_device_id,
        direction,
        packet_type,
        body,
        delivery_state,
        created_at_unix_secs,
        ttl_secs,
        final_reply,
        final_view_once,
        meta_global_id,
    )
}

#[allow(clippy::too_many_arguments)]
fn insert_with_options_internal(
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
    global_id: Option<String>,
) -> Result<i64> {
    reject_non_storable(packet_type)?;

    // Reenvio de `flush_pending` sai recifrado com novo passo do ratchet, então só o
    // `global_id` do corpo identifica a repetição. O acesso ao banco é serializado por
    // `with_conn`, logo consultar e inserir não corre contra outra inserção.
    if direction == Direction::Incoming {
        if let Some(gid) = global_id.as_deref().filter(|g| !g.is_empty()) {
            let existing: Option<i64> = conn
                .query_row(
                    "SELECT id FROM messages
                     WHERE global_id = ?1 AND contact_device_id = ?2 AND direction = ?3",
                    rusqlite::params![gid, contact_device_id.as_slice(), Direction::Incoming as i64],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|_| Error::Store)?;
            if let Some(id) = existing {
                return Ok(id);
            }
        }
    }

    let final_global_id = match global_id {
        Some(gid) if !gid.is_empty() => gid,
        _ => hex::encode(crate::util::rng::array::<16>()?),
    };

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
                (contact_device_id, direction, packet_type, body, delivery_state, ratchet_counter, created_at_unix_secs, is_ephemeral, reply_to_id, view_once, global_id, body_cipher_version)
             VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, 1, ?7, ?8, ?9, 1)",
            rusqlite::params![
                contact_device_id.as_slice(),
                direction as i64,
                packet_type.to_u8(),
                hex_body,
                delivery_state as i64,
                created_at_unix_secs,
                reply_to_id,
                view_once_int,
                final_global_id,
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
                (contact_device_id, direction, packet_type, body, delivery_state, ratchet_counter, created_at_unix_secs, is_ephemeral, reply_to_id, view_once, global_id, body_cipher_version)
             VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, 0, ?7, ?8, ?9, 1)",
            rusqlite::params![
                contact_device_id.as_slice(),
                direction as i64,
                packet_type.to_u8(),
                body,
                delivery_state as i64,
                created_at_unix_secs,
                reply_to_id,
                view_once_int,
                final_global_id,
            ],
        )
        .map_err(|_| Error::Store)?;

        Ok(conn.last_insert_rowid())
    }
}

/// Marca uma mensagem efêmera como lida, disparando o temporizador regressivo
/// a partir do carimbo de data/hora atual (`unix_now`).
///
/// Para mensagens de visualização única (`view_once == true`), destrói a chave efêmera
/// imediatamente no primeiro `mark_message_read` (U-04 / crypto-shredding imediato).
pub fn mark_message_read(
    conn: &rusqlite::Connection,
    message_id: i64,
    unix_now: i64,
) -> Result<()> {
    let row_info: Option<(i64, i64)> = conn
        .query_row(
            "SELECT m.view_once, COALESCE(c.ephemeral_ttl, 0) FROM messages m
             LEFT JOIN contacts c ON m.contact_device_id = c.device_id
             WHERE m.id = ?1",
            [message_id],
            |row| Ok((row.get(0).unwrap_or(0), row.get(1).unwrap_or(0))),
        )
        .optional()
        .map_err(|_| Error::Store)?;

    if let Some((view_once, ttl)) = row_info {
        if view_once != 0 {
            // Visualização única: destrói a chave individual K_msg e trunca o WAL para não
            // deixar vestígios em disco.
            let deleted = conn
                .execute(
                    "DELETE FROM ephemeral_message_keys WHERE message_id = ?1",
                    [message_id],
                )
                .map_err(|_| Error::Store)?;
            if deleted > 0 {
                conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
                    .map_err(|_| Error::Store)?;
            }
        } else if ttl > 0 {
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
///
/// Ao remover chaves com `PRAGMA secure_delete = ON`, o SQLite zera o conteúdo
/// das células liberadas. O `wal_checkpoint(TRUNCATE)` sincroniza as páginas e
/// trunca o WAL para não reter cópias antigas das chaves (S-14).
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
    if deleted > 0 {
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
            .map_err(|_| Error::Store)?;
    }
    Ok(deleted)
}

/// Marca uma mensagem de saída como entregue ao transporte.
///
/// Só avança de `Pending`/`Sending`/`Unknown`: o envio de um arquivo termina
/// depois do bombeamento, e uma recusa que chegou no meio dele não pode ser
/// sobrescrita. `Unknown` entra porque `lock()` pode marcá-lo enquanto um envio
/// em voo ainda vai terminar: o `send` que retornou sem erro é a confirmação
/// que faltava, e deixar a linha incerta ofereceria um reenvio duplicado.
pub fn mark_sent(conn: &rusqlite::Connection, message_id: i64) -> Result<()> {
    conn.execute(
        "UPDATE messages SET delivery_state = ?1 WHERE id = ?2 AND delivery_state IN (?3, ?4, ?5)",
        rusqlite::params![
            DeliveryState::Sent as i64,
            message_id,
            DeliveryState::Pending as i64,
            DeliveryState::Sending as i64,
            DeliveryState::Unknown as i64
        ],
    )
    .map_err(|_| Error::Store)?;
    Ok(())
}

/// Move uma mensagem entre dois estados, só se ela ainda estiver em `from`:
/// uma linha que já avançou (`Sent`, `Delivered`) nunca é rebaixada.
fn transition(
    conn: &rusqlite::Connection,
    message_id: i64,
    from: DeliveryState,
    to: DeliveryState,
) -> Result<()> {
    conn.execute(
        "UPDATE messages SET delivery_state = ?1 WHERE id = ?2 AND delivery_state = ?3",
        rusqlite::params![to as i64, message_id, from as i64],
    )
    .map_err(|_| Error::Store)?;
    Ok(())
}

/// Tira a mensagem da fila de pendentes quando seus bytes cifrados saem para
/// o transporte.
pub fn mark_sending(conn: &rusqlite::Connection, message_id: i64) -> Result<()> {
    transition(conn, message_id, DeliveryState::Pending, DeliveryState::Sending)
}

/// Devolve à fila uma mensagem que não chegou a sair.
pub fn requeue(conn: &rusqlite::Connection, message_id: i64) -> Result<()> {
    transition(conn, message_id, DeliveryState::Sending, DeliveryState::Pending)
}

/// Marca como `Unknown` todo texto deixado em `Sending`. Usada na abertura e em
/// `lock()`: ali o Rust perdeu a pista de se os bytes saíram, e devolvê-los à
/// fila recifraria uma mensagem que o par talvez já tenha. Só texto, porque
/// `list_pending` (que `Unknown` evita) só drena `MSG_TEXT`.
pub fn mark_all_sending_unknown(conn: &rusqlite::Connection) -> Result<usize> {
    conn.execute(
        "UPDATE messages SET delivery_state = ?1
         WHERE direction = ?2 AND delivery_state = ?3 AND packet_type = ?4",
        rusqlite::params![
            DeliveryState::Unknown as i64,
            Direction::Outgoing as i64,
            DeliveryState::Sending as i64,
            PacketType::MsgText.to_u8() as i64
        ],
    )
    .map_err(|_| Error::Store)
}

/// Como [`mark_all_sending_unknown`], para um único contato. Usada quando o
/// par reabre a sessão (§11.4): o texto em `Sending` saiu (ou não) pela sessão
/// que o par provavelmente já perdeu, e recifrá-lo poderia entregá-lo duas vezes.
pub fn mark_sending_unknown_for_contact(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
) -> Result<usize> {
    conn.execute(
        "UPDATE messages SET delivery_state = ?1
         WHERE contact_device_id = ?2 AND direction = ?3 AND delivery_state = ?4
           AND packet_type = ?5",
        rusqlite::params![
            DeliveryState::Unknown as i64,
            contact_device_id.as_slice(),
            Direction::Outgoing as i64,
            DeliveryState::Sending as i64,
            PacketType::MsgText.to_u8() as i64
        ],
    )
    .map_err(|_| Error::Store)
}

/// Devolve à fila um texto `Unknown`, por pedido explícito da pessoa. A linha
/// (e o `global_id` dentro do corpo) é a mesma, então o par deduplica se a
/// primeira cópia tinha chegado.
pub fn resend_unknown(conn: &rusqlite::Connection, message_id: i64) -> Result<()> {
    transition(conn, message_id, DeliveryState::Unknown, DeliveryState::Pending)
}

/// Devolve à fila os `Sending` de um contato: o reset de uma sessão
/// falha não pode mexer nos envios em voo das sessões saudáveis dos outros.
pub fn requeue_sending_for_contact(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
) -> Result<usize> {
    conn.execute(
        "UPDATE messages SET delivery_state = ?1
         WHERE contact_device_id = ?2 AND direction = ?3 AND delivery_state = ?4",
        rusqlite::params![
            DeliveryState::Pending as i64,
            contact_device_id.as_slice(),
            Direction::Outgoing as i64,
            DeliveryState::Sending as i64
        ],
    )
    .map_err(|_| Error::Store)
}

/// Marca uma mensagem de saída como falha. Só sai de `Pending` ou `Sending`:
/// uma mensagem que já foi `Sent` ou `Delivered` chegou ao par, e rebaixá-la a
/// falha faria a UI oferecer um reenvio de algo que ele já recebeu. `Sending`
/// entra porque é um `Pending` com bytes já cifrados; sem ele a falha de uma
/// linha em voo seria ignorada em silêncio.
pub fn mark_failed(conn: &rusqlite::Connection, message_id: i64) -> Result<()> {
    conn.execute(
        "UPDATE messages SET delivery_state = ?1 WHERE id = ?2 AND delivery_state IN (?3, ?4)",
        rusqlite::params![
            DeliveryState::Failed as i64,
            message_id,
            DeliveryState::Pending as i64,
            DeliveryState::Sending as i64
        ],
    )
    .map_err(|_| Error::Store)?;
    Ok(())
}

/// Marca como falha os envios de arquivo e de nota de voz que ficaram
/// `Pending`. A transferência vive só em memória (U-03): sem o handle ativo
/// ela não retoma, então a linha não pode continuar como "Enviando…". Também
/// a tira de `list_pending`, que reenviaria o nome do arquivo como texto.
pub fn fail_pending_transfers(conn: &rusqlite::Connection) -> Result<usize> {
    conn.execute(
        "UPDATE messages SET delivery_state = ?1
         WHERE direction = ?2 AND delivery_state = ?3 AND packet_type IN (?4, ?5)",
        rusqlite::params![
            DeliveryState::Failed as i64,
            Direction::Outgoing as i64,
            DeliveryState::Pending as i64,
            PacketType::FileMetadata.to_u8() as i64,
            PacketType::AudioChunk.to_u8() as i64,
        ],
    )
    .map_err(|_| Error::Store)
}

/// Como [`fail_pending_transfers`], restrita a um contato.
pub fn fail_pending_transfers_for_contact(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
) -> Result<usize> {
    conn.execute(
        "UPDATE messages SET delivery_state = ?1
         WHERE contact_device_id = ?2 AND direction = ?3 AND delivery_state = ?4
           AND packet_type IN (?5, ?6)",
        rusqlite::params![
            DeliveryState::Failed as i64,
            contact_device_id.as_slice(),
            Direction::Outgoing as i64,
            DeliveryState::Pending as i64,
            PacketType::FileMetadata.to_u8() as i64,
            PacketType::AudioChunk.to_u8() as i64,
        ],
    )
    .map_err(|_| Error::Store)
}

/// Liga a mensagem de saída de um arquivo ao `file_id` da transferência, para
/// que a recusa do par (`FILE_REJECT`) ache a linha sem depender da UI.
pub fn set_file_id(conn: &rusqlite::Connection, message_id: i64, file_id: &[u8; 16]) -> Result<()> {
    conn.execute(
        "UPDATE messages SET file_id = ?1 WHERE id = ?2",
        rusqlite::params![file_id.as_slice(), message_id],
    )
    .map_err(|_| Error::Store)?;
    Ok(())
}

/// Marca como recusada a mensagem de saída ligada a `file_id`, só se ela for
/// deste contato e ainda não tiver terminado: `Delivered` e `Failed` não
/// voltam atrás. Devolve se alguma linha mudou.
pub fn mark_rejected_by_file_id(
    conn: &rusqlite::Connection,
    file_id: &[u8; 16],
    contact_device_id: &[u8; 16],
) -> Result<bool> {
    mark_unfinished_by_file_id(conn, DeliveryState::Rejected, file_id, contact_device_id)
}

/// Como [`mark_rejected_by_file_id`], para o envio cuja oferta ninguém
/// respondeu a tempo.
pub fn mark_expired_by_file_id(
    conn: &rusqlite::Connection,
    file_id: &[u8; 16],
    contact_device_id: &[u8; 16],
) -> Result<bool> {
    mark_unfinished_by_file_id(conn, DeliveryState::Expired, file_id, contact_device_id)
}

/// Como [`mark_rejected_by_file_id`], para o envio cancelado localmente (reset
/// de sessão): falha local, não recusa nem prazo vencido. Como as demais,
/// só move `Pending`, `Sending` e `Sent`.
pub fn mark_failed_by_file_id(
    conn: &rusqlite::Connection,
    file_id: &[u8; 16],
    contact_device_id: &[u8; 16],
) -> Result<bool> {
    mark_unfinished_by_file_id(conn, DeliveryState::Failed, file_id, contact_device_id)
}

fn mark_unfinished_by_file_id(
    conn: &rusqlite::Connection,
    state: DeliveryState,
    file_id: &[u8; 16],
    contact_device_id: &[u8; 16],
) -> Result<bool> {
    let changed = conn
        .execute(
            "UPDATE messages SET delivery_state = ?1
             WHERE file_id = ?2 AND contact_device_id = ?3 AND direction = ?4
               AND delivery_state IN (?5, ?6, ?7)",
            rusqlite::params![
                state as i64,
                file_id.as_slice(),
                contact_device_id.as_slice(),
                Direction::Outgoing as i64,
                DeliveryState::Pending as i64,
                DeliveryState::Sending as i64,
                DeliveryState::Sent as i64,
            ],
        )
        .map_err(|_| Error::Store)?;
    Ok(changed > 0)
}

/// Marca uma mensagem de saída como confirmada/entregue ao destinatário (via MSG_RECEIPT).
pub fn mark_delivered(conn: &rusqlite::Connection, message_id: i64) -> Result<()> {
    conn.execute(
        "UPDATE messages SET delivery_state = ?1 WHERE id = ?2",
        rusqlite::params![DeliveryState::Delivered as i64, message_id],
    )
    .map_err(|_| Error::Store)?;
    Ok(())
}

/// Atualiza o ratchet_counter associado a uma mensagem enviada.
pub fn update_ratchet_counter(
    conn: &rusqlite::Connection,
    message_id: i64,
    counter: i64,
) -> Result<()> {
    conn.execute(
        "UPDATE messages SET ratchet_counter = ?1 WHERE id = ?2 AND ratchet_counter IS NULL",
        rusqlite::params![counter, message_id],
    )
    .map_err(|_| Error::Store)?;
    Ok(())
}

/// Consulta o identificador global (UUID) de uma mensagem pelo seu rowid local.
pub fn get_message_global_id(
    conn: &rusqlite::Connection,
    message_id: i64,
) -> Result<Option<String>> {
    conn.query_row(
        "SELECT global_id FROM messages WHERE id = ?1",
        [message_id],
        |row| row.get(0),
    )
    .optional()
    .map_err(|_| Error::Store)
}

/// Marca uma mensagem como entregue buscando por identificador global, id numérico ou ratchet_counter.
pub fn mark_delivered_by_target(
    conn: &rusqlite::Connection,
    target_id_str: &str,
    contact_device_id: &[u8; 16],
) -> Result<Option<i64>> {
    let found_id: Option<i64> = conn
        .query_row(
            "SELECT id FROM messages WHERE global_id = ?1 AND contact_device_id = ?2",
            rusqlite::params![target_id_str, contact_device_id.as_slice()],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| Error::Store)?;

    let target_rowid = match found_id {
        Some(id) => Some(id),
        None => {
            if let Ok(num) = target_id_str.parse::<i64>() {
                let by_id: Option<i64> = conn
                    .query_row(
                        "SELECT id FROM messages WHERE id = ?1 AND contact_device_id = ?2",
                        rusqlite::params![num, contact_device_id.as_slice()],
                        |row| row.get(0),
                    )
                    .optional()
                    .map_err(|_| Error::Store)?;

                if by_id.is_some() {
                    by_id
                } else {
                    conn.query_row(
                        "SELECT id FROM messages WHERE ratchet_counter = ?1 AND contact_device_id = ?2 AND direction = 0",
                        rusqlite::params![num, contact_device_id.as_slice()],
                        |row| row.get(0),
                    )
                    .optional()
                    .map_err(|_| Error::Store)?
                }
            } else {
                None
            }
        }
    };

    if let Some(msg_id) = target_rowid {
        conn.execute(
            "UPDATE messages SET delivery_state = ?1 WHERE id = ?2",
            rusqlite::params![DeliveryState::Delivered as i64, msg_id],
        )
        .map_err(|_| Error::Store)?;
        Ok(Some(msg_id))
    } else {
        Ok(None)
    }
}

/// Extrai o identificador da mensagem de destino a partir do corpo de um pacote MSG_RECEIPT.
///
/// Aceita JSON estruturado (`{"targetId": "..."}`, `{"id": "..."}`) ou o ID diretamente em texto UTF-8.
pub fn parse_receipt_target_id(body: &[u8]) -> Option<String> {
    if let Ok(text) = std::str::from_utf8(body) {
        let text = text.trim();
        if text.starts_with('{') {
            if let Ok(serde_json::Value::Object(map)) = serde_json::from_str::<serde_json::Value>(text) {
                if let Some(target) = map.get("targetId").or_else(|| map.get("id")) {
                    match target {
                        serde_json::Value::String(s) => return Some(s.clone()),
                        serde_json::Value::Number(n) => return Some(n.to_string()),
                        _ => {}
                    }
                }
            }
        }
        if !text.is_empty() {
            return Some(text.to_string());
        }
    }
    None
}

/// Todas as mensagens de um contato com paginação opcional (`since_id`, `limit`).
pub fn list_for_contact_paginated(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
    since_id: Option<i64>,
    limit: Option<usize>,
) -> Result<Vec<StoredMessage>> {
    let limit_param = limit.map(|l| l as i64).unwrap_or(-1);
    let mut statement = conn
        .prepare(
            "SELECT m.id, m.direction, m.packet_type, m.body, m.delivery_state, 
                    m.created_at_unix_secs, m.is_ephemeral, m.reply_to_id, m.view_once, m.global_id,
                    m.body_cipher_version,
                    ek.key,
                    rx.reactions
             FROM messages m
             LEFT JOIN ephemeral_message_keys ek ON (m.is_ephemeral = 1 AND ek.message_id = m.id)
             LEFT JOIN (
                 SELECT message_id, GROUP_CONCAT(emoji, CHAR(31)) AS reactions
                 FROM message_reactions
                 GROUP BY message_id
             ) rx ON rx.message_id = m.id
             WHERE m.contact_device_id = ?1
               AND (?2 IS NULL OR m.id > ?2)
             ORDER BY m.created_at_unix_secs ASC, m.id ASC
             LIMIT ?3",
        )
        .map_err(|_| Error::Store)?;

    let mut rows = statement
        .query(rusqlite::params![
            contact_device_id.as_slice(),
            since_id,
            limit_param,
        ])
        .map_err(|_| Error::Store)?;

    let mut messages = Vec::with_capacity(limit.unwrap_or(64));
    while let Some(row) = rows.next().map_err(|_| Error::Store)? {
        let raw_body: String = row.get(3).map_err(|_| Error::Store)?;
        if parse_reaction_metadata(&raw_body).is_some() {
            continue;
        }

        let id: i64 = row.get(0).map_err(|_| Error::Store)?;
        let direction_raw: i64 = row.get(1).map_err(|_| Error::Store)?;
        let packet_type_raw: i64 = row.get(2).map_err(|_| Error::Store)?;
        let delivery_state_raw: i64 = row.get(4).map_err(|_| Error::Store)?;
        let created_at_unix_secs: i64 = row.get(5).map_err(|_| Error::Store)?;
        let is_ephemeral: i64 = row.get(6).map_err(|_| Error::Store)?;
        let reply_to_id: Option<i64> = row.get(7).map_err(|_| Error::Store)?;
        let view_once: i64 = row.get(8).unwrap_or(0);
        let global_id: Option<String> = row.get(9).unwrap_or(None);
        let body_cipher_version: i64 = row.get(10).map_err(|_| Error::Store)?;
        let ek_key: Option<Vec<u8>> = row.get(11).map_err(|_| Error::Store)?;
        let reactions_concat: Option<String> = row.get(12).map_err(|_| Error::Store)?;

        let direction = match direction_raw {
            0 => Direction::Outgoing,
            1 => Direction::Incoming,
            _ => return Err(Error::Store),
        };
        let packet_type =
            PacketType::from_u8(packet_type_raw as u8).map_err(|_| Error::Store)?;
        let delivery_state =
            DeliveryState::from_i64(delivery_state_raw)?;
        let is_ephemeral = is_ephemeral != 0;

        let body = decode_ephemeral_body(raw_body, is_ephemeral, body_cipher_version, ek_key.as_deref())?;
        let reactions = match reactions_concat {
            Some(s) if !s.is_empty() => s.split('\u{001f}').map(|e| e.to_string()).collect(),
            _ => Vec::new(),
        };

        messages.push(StoredMessage {
            id,
            global_id,
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

/// Todas as mensagens de um contato, mais antigas primeiro.
pub fn list_for_contact(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
) -> Result<Vec<StoredMessage>> {
    list_for_contact_paginated(conn, contact_device_id, None, None)
}

/// Mensagens de texto de saída ainda não entregues, mais antigas primeiro.
///
/// Só `MsgText`: a linha de um arquivo ou nota de voz fica `Pending` durante
/// toda a transferência, e cifrá-la aqui mandaria o nome do arquivo ao par
/// como se fosse texto.
pub fn list_pending(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
) -> Result<Vec<StoredMessage>> {
    let mut statement = conn
        .prepare(
            "SELECT m.id, m.direction, m.packet_type, m.body, m.delivery_state, 
                    m.created_at_unix_secs, m.is_ephemeral, m.reply_to_id, m.view_once, m.global_id,
                    m.body_cipher_version,
                    ek.key
             FROM messages m
             LEFT JOIN ephemeral_message_keys ek ON ek.message_id = m.id
             WHERE m.contact_device_id = ?1 AND m.direction = ?2 AND m.delivery_state = ?3
               AND m.packet_type = ?4
             ORDER BY m.created_at_unix_secs ASC, m.id ASC",
        )
        .map_err(|_| Error::Store)?;

    let rows = statement
        .query_map(
            rusqlite::params![
                contact_device_id.as_slice(),
                Direction::Outgoing as i64,
                DeliveryState::Pending as i64,
                PacketType::MsgText.to_u8() as i64,
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
                let global_id: Option<String> = row.get(9).unwrap_or(None);
                let body_cipher_version: i64 = row.get(10)?;
                let ek_key: Option<Vec<u8>> = row.get(11)?;
                Ok((
                    id,
                    direction,
                    packet_type,
                    raw_body,
                    delivery_state,
                    created_at_unix_secs,
                    is_ephemeral,
                    reply_to_id,
                    view_once,
                    global_id,
                    body_cipher_version,
                    ek_key,
                ))
            },
        )
        .map_err(|_| Error::Store)?;

    let mut messages = Vec::new();
    for row in rows {
        let (
            id,
            direction,
            packet_type,
            raw_body,
            delivery_state,
            created_at_unix_secs,
            is_ephemeral,
            reply_to_id,
            view_once,
            global_id,
            body_cipher_version,
            ek_key,
        ) = row.map_err(|_| Error::Store)?;

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

        let body = decode_ephemeral_body(raw_body, is_ephemeral, body_cipher_version, ek_key.as_deref())?;

        messages.push(StoredMessage {
            id,
            global_id,
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

/// Adiciona uma reação buscando a mensagem alvo pelo seu identificador global ou rowid local.
pub fn add_reaction_by_target(
    conn: &rusqlite::Connection,
    target_id_str: &str,
    contact_device_id: &[u8; 16],
    emoji: &str,
    created_at_unix_secs: i64,
) -> Result<Option<i64>> {
    let rowid: Option<i64> = conn
        .query_row(
            "SELECT id FROM messages WHERE global_id = ?1",
            [target_id_str],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| Error::Store)?;

    let final_id = match rowid {
        Some(id) => Some(id),
        None => {
            if let Ok(numeric_id) = target_id_str.parse::<i64>() {
                conn.query_row(
                    "SELECT id FROM messages WHERE id = ?1",
                    [numeric_id],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|_| Error::Store)?
            } else {
                None
            }
        }
    };

    if let Some(msg_id) = final_id {
        add_reaction(conn, msg_id, contact_device_id, emoji, created_at_unix_secs)?;
        Ok(Some(msg_id))
    } else {
        Ok(None)
    }
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

fn decode_ephemeral_body(
    raw_body: String,
    is_ephemeral: bool,
    body_cipher_version: i64,
    key_opt: Option<&[u8]>,
) -> Result<String> {
    if !is_ephemeral {
        return Ok(raw_body);
    }

    let version_u8 = u8::try_from(body_cipher_version).unwrap_or(255);
    if crate::crypto::Suite::is_retired(version_u8) {
        return Err(Error::SuiteRetired(version_u8));
    }
    if body_cipher_version != 1 {
        return Err(Error::UnsupportedVersion(version_u8));
    }

    match key_opt {
        Some(key_bytes) if key_bytes.len() == 32 => {
            let mut key_arr = [0u8; 32];
            key_arr.copy_from_slice(key_bytes);
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
    fn rejected_by_file_id_needs_matching_contact_and_an_unfinished_state() {
        let contact = [12u8; 16];
        let conn = conn_with_contact(contact);
        let file_id = [7u8; 16];
        let id = insert_pending(&conn, &contact, PacketType::FileMetadata, "a.bin", 1).unwrap();
        set_file_id(&conn, id, &file_id).unwrap();

        assert!(!mark_rejected_by_file_id(&conn, &file_id, &[13u8; 16]).unwrap());
        assert!(!mark_rejected_by_file_id(&conn, &[8u8; 16], &contact).unwrap());
        assert_eq!(list_for_contact(&conn, &contact).unwrap()[0].delivery_state, DeliveryState::Pending);

        mark_sent(&conn, id).unwrap();
        assert!(mark_rejected_by_file_id(&conn, &file_id, &contact).unwrap());
        assert_eq!(list_for_contact(&conn, &contact).unwrap()[0].delivery_state, DeliveryState::Rejected);

        // Recusa repetida ou envio já recusado não muda de novo.
        assert!(!mark_rejected_by_file_id(&conn, &file_id, &contact).unwrap());
    }

    #[test]
    fn failed_by_file_id_reaches_sent_but_not_finished_or_foreign_rows() {
        let contact = [15u8; 16];
        let conn = conn_with_contact(contact);
        let file_id = [6u8; 16];
        let id = insert_pending(&conn, &contact, PacketType::FileMetadata, "a.bin", 1).unwrap();
        set_file_id(&conn, id, &file_id).unwrap();
        mark_sent(&conn, id).unwrap();

        assert!(!mark_failed_by_file_id(&conn, &file_id, &[16u8; 16]).unwrap());
        assert!(mark_failed_by_file_id(&conn, &file_id, &contact).unwrap());
        assert_eq!(list_for_contact(&conn, &contact).unwrap()[0].delivery_state, DeliveryState::Failed);
        // Repetir (reset refeito depois de uma falha no meio) não muda nada.
        assert!(!mark_failed_by_file_id(&conn, &file_id, &contact).unwrap());

        // `Pending` e `Sending` também são envios ainda não terminados.
        for (n, advance) in [(1u8, mark_sending as fn(&_, i64) -> _), (2, |_, _| Ok(()))] {
            let fid = [30 + n; 16];
            let m = insert_pending(&conn, &contact, PacketType::AudioChunk, "v.opus", 2).unwrap();
            set_file_id(&conn, m, &fid).unwrap();
            advance(&conn, m).unwrap();
            assert!(mark_failed_by_file_id(&conn, &fid, &contact).unwrap());
        }

        let delivered = [41u8; 16];
        let m = insert_pending(&conn, &contact, PacketType::FileMetadata, "b.bin", 2).unwrap();
        set_file_id(&conn, m, &delivered).unwrap();
        mark_delivered(&conn, m).unwrap();
        assert!(!mark_failed_by_file_id(&conn, &delivered, &contact).unwrap());

        let rejected = [42u8; 16];
        let m = insert_pending(&conn, &contact, PacketType::FileMetadata, "c.bin", 3).unwrap();
        set_file_id(&conn, m, &rejected).unwrap();
        assert!(mark_rejected_by_file_id(&conn, &rejected, &contact).unwrap());
        assert!(!mark_failed_by_file_id(&conn, &rejected, &contact).unwrap());

        let expired = [43u8; 16];
        let m = insert_pending(&conn, &contact, PacketType::FileMetadata, "d.bin", 4).unwrap();
        set_file_id(&conn, m, &expired).unwrap();
        assert!(mark_expired_by_file_id(&conn, &expired, &contact).unwrap());
        assert!(!mark_failed_by_file_id(&conn, &expired, &contact).unwrap());
    }

    #[test]
    fn expired_by_file_id_only_touches_unfinished_messages_of_that_contact() {
        let contact = [15u8; 16];
        let conn = conn_with_contact(contact);
        let file_id = [6u8; 16];
        let id = insert_pending(&conn, &contact, PacketType::FileMetadata, "a.bin", 1).unwrap();
        set_file_id(&conn, id, &file_id).unwrap();

        assert!(!mark_expired_by_file_id(&conn, &file_id, &[16u8; 16]).unwrap());
        mark_sent(&conn, id).unwrap();
        assert!(mark_expired_by_file_id(&conn, &file_id, &contact).unwrap());
        assert_eq!(list_for_contact(&conn, &contact).unwrap()[0].delivery_state, DeliveryState::Expired);
        // Uma recusa tardia não reescreve o estado final.
        assert!(!mark_rejected_by_file_id(&conn, &file_id, &contact).unwrap());

        let other = insert_pending(&conn, &contact, PacketType::FileMetadata, "b.bin", 2).unwrap();
        set_file_id(&conn, other, &[5u8; 16]).unwrap();
        mark_delivered(&conn, other).unwrap();
        assert!(!mark_expired_by_file_id(&conn, &[5u8; 16], &contact).unwrap());
    }

    #[test]
    fn rejected_by_file_id_does_not_downgrade_a_delivered_message() {
        let contact = [14u8; 16];
        let conn = conn_with_contact(contact);
        let file_id = [9u8; 16];
        let id = insert_pending(&conn, &contact, PacketType::FileMetadata, "a.bin", 1).unwrap();
        set_file_id(&conn, id, &file_id).unwrap();
        mark_delivered(&conn, id).unwrap();

        assert!(!mark_rejected_by_file_id(&conn, &file_id, &contact).unwrap());
    }

    #[test]
    fn sending_leaves_the_pending_list_and_requeue_brings_it_back() {
        let contact = [10u8; 16];
        let conn = conn_with_contact(contact);
        let id = insert_pending(&conn, &contact, PacketType::MsgText, "oi", 1000).unwrap();

        mark_sending(&conn, id).unwrap();
        assert!(list_pending(&conn, &contact).unwrap().is_empty());

        requeue(&conn, id).unwrap();
        assert_eq!(list_pending(&conn, &contact).unwrap().len(), 1);
    }

    #[test]
    fn mark_sending_unknown_for_contact_touches_only_that_contact() {
        let contact = [11u8; 16];
        let other = [12u8; 16];
        let conn = conn_with_contact(contact);
        conn.execute(
            "INSERT INTO contacts (device_id, signing_pubkey, dh_pubkey, paired_at, nickname)
             VALUES (?1, ?2, ?3, 1700000000, NULL)",
            rusqlite::params![other.as_slice(), [3u8; 32], [4u8; 32]],
        )
        .unwrap();
        let mine = insert_pending(&conn, &contact, PacketType::MsgText, "a", 1).unwrap();
        let theirs = insert_pending(&conn, &other, PacketType::MsgText, "b", 2).unwrap();
        mark_sending(&conn, mine).unwrap();
        mark_sending(&conn, theirs).unwrap();

        assert_eq!(mark_sending_unknown_for_contact(&conn, &contact).unwrap(), 1);
        let state = |id: &[u8; 16], row| {
            list_for_contact(&conn, id)
                .unwrap()
                .into_iter()
                .find(|m| m.id == row)
                .unwrap()
                .delivery_state
        };
        assert_eq!(state(&contact, mine), DeliveryState::Unknown);
        assert_eq!(state(&other, theirs), DeliveryState::Sending);
    }

    #[test]
    fn mark_all_sending_unknown_leaves_sent_incoming_and_file_rows_alone() {
        let contact = [11u8; 16];
        let conn = conn_with_contact(contact);
        let sending = insert_pending(&conn, &contact, PacketType::MsgText, "a", 1).unwrap();
        let sent = insert_pending(&conn, &contact, PacketType::MsgText, "b", 2).unwrap();
        let incoming = insert_incoming(&conn, &contact, PacketType::MsgText, "c", 3).unwrap();
        let file = insert_pending(&conn, &contact, PacketType::FileMetadata, "f.bin", 4).unwrap();
        mark_sending(&conn, sending).unwrap();
        mark_sent(&conn, sent).unwrap();
        mark_sending(&conn, file).unwrap();

        let marked = mark_all_sending_unknown(&conn).unwrap();

        assert_eq!(marked, 1);
        let states: Vec<_> = list_for_contact(&conn, &contact)
            .unwrap()
            .into_iter()
            .map(|m| (m.id, m.delivery_state))
            .collect();
        assert!(states.contains(&(sending, DeliveryState::Unknown)));
        assert!(states.contains(&(sent, DeliveryState::Sent)));
        assert!(states.contains(&(incoming, DeliveryState::Delivered)));
        assert!(states.contains(&(file, DeliveryState::Sending)));
    }

    #[test]
    fn unknown_row_is_not_listed_as_pending_until_resent() {
        let contact = [15u8; 16];
        let conn = conn_with_contact(contact);
        let id = insert_pending(&conn, &contact, PacketType::MsgText, "oi", 1).unwrap();
        mark_sending(&conn, id).unwrap();
        mark_all_sending_unknown(&conn).unwrap();

        assert!(list_pending(&conn, &contact).unwrap().is_empty());

        resend_unknown(&conn, id).unwrap();
        let pending = list_pending(&conn, &contact).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].id, id);
    }

    #[test]
    fn resend_unknown_keeps_the_global_id() {
        let contact = [16u8; 16];
        let conn = conn_with_contact(contact);
        let body = r#"{"id":"gid-1","text":"oi"}"#;
        let id = insert_pending(&conn, &contact, PacketType::MsgText, body, 1).unwrap();
        let before = get_message_global_id(&conn, id).unwrap();
        mark_sending(&conn, id).unwrap();
        mark_all_sending_unknown(&conn).unwrap();

        resend_unknown(&conn, id).unwrap();

        assert_eq!(get_message_global_id(&conn, id).unwrap(), before);
    }

    #[test]
    fn resend_unknown_does_not_touch_other_states() {
        let contact = [17u8; 16];
        let conn = conn_with_contact(contact);
        let sent = insert_pending(&conn, &contact, PacketType::MsgText, "a", 1).unwrap();
        let failed = insert_pending(&conn, &contact, PacketType::MsgText, "b", 2).unwrap();
        mark_sent(&conn, sent).unwrap();
        mark_failed(&conn, failed).unwrap();

        resend_unknown(&conn, sent).unwrap();
        resend_unknown(&conn, failed).unwrap();

        let listed = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed[0].delivery_state, DeliveryState::Sent);
        assert_eq!(listed[1].delivery_state, DeliveryState::Failed);
    }

    #[test]
    fn late_send_confirmation_promotes_unknown_to_sent() {
        let contact = [18u8; 16];
        let conn = conn_with_contact(contact);
        let id = insert_pending(&conn, &contact, PacketType::MsgText, "oi", 1).unwrap();
        mark_sending(&conn, id).unwrap();
        mark_all_sending_unknown(&conn).unwrap();

        mark_sent(&conn, id).unwrap();

        assert_eq!(list_for_contact(&conn, &contact).unwrap()[0].delivery_state, DeliveryState::Sent);
    }

    #[test]
    fn mark_failed_reaches_a_sending_row_but_not_a_sent_one() {
        let contact = [13u8; 16];
        let conn = conn_with_contact(contact);
        let in_flight = insert_pending(&conn, &contact, PacketType::MsgText, "a", 1).unwrap();
        let delivered = insert_pending(&conn, &contact, PacketType::MsgText, "b", 2).unwrap();
        mark_sending(&conn, in_flight).unwrap();
        mark_sent(&conn, delivered).unwrap();

        mark_failed(&conn, in_flight).unwrap();
        mark_failed(&conn, delivered).unwrap();

        let states: Vec<_> = list_for_contact(&conn, &contact)
            .unwrap()
            .into_iter()
            .map(|m| (m.id, m.delivery_state))
            .collect();
        assert!(states.contains(&(in_flight, DeliveryState::Failed)));
        assert!(states.contains(&(delivered, DeliveryState::Sent)));
    }

    #[test]
    fn list_pending_ignores_file_and_voice_note_rows() {
        let contact = [14u8; 16];
        let conn = conn_with_contact(contact);
        let text = insert_pending(&conn, &contact, PacketType::MsgText, "oi", 1).unwrap();
        insert_pending(&conn, &contact, PacketType::FileMetadata, "a.bin", 2).unwrap();
        insert_pending(&conn, &contact, PacketType::AudioChunk, "ab", 3).unwrap();

        let pending = list_pending(&conn, &contact).unwrap();

        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].id, text);
    }

    #[test]
    fn contact_scoped_requeue_and_fail_leave_other_contacts_alone() {
        let a = [31u8; 16];
        let b = [32u8; 16];
        let conn = conn_with_contact(a);
        conn.execute(
            "INSERT INTO contacts (device_id, signing_pubkey, dh_pubkey, paired_at, nickname)
             VALUES (?1, ?2, ?3, 1700000000, NULL)",
            rusqlite::params![b.as_slice(), [1u8; 32], [2u8; 32]],
        )
        .unwrap();
        let text_a = insert_pending(&conn, &a, PacketType::MsgText, "a", 1).unwrap();
        let text_b = insert_pending(&conn, &b, PacketType::MsgText, "b", 2).unwrap();
        let file_a = insert_pending(&conn, &a, PacketType::FileMetadata, "a.bin", 3).unwrap();
        let file_b = insert_pending(&conn, &b, PacketType::FileMetadata, "b.bin", 4).unwrap();
        mark_sending(&conn, text_a).unwrap();
        mark_sending(&conn, text_b).unwrap();

        assert_eq!(requeue_sending_for_contact(&conn, &a).unwrap(), 1);
        assert_eq!(fail_pending_transfers_for_contact(&conn, &a).unwrap(), 1);

        let state = |id: i64| -> i64 {
            conn.query_row("SELECT delivery_state FROM messages WHERE id = ?1", [id], |r| r.get(0))
                .unwrap()
        };
        assert_eq!(state(text_a), DeliveryState::Pending as i64);
        assert_eq!(state(file_a), DeliveryState::Failed as i64);
        assert_eq!(state(text_b), DeliveryState::Sending as i64);
        assert_eq!(state(file_b), DeliveryState::Pending as i64);
    }

    #[test]
    fn mark_sending_does_not_touch_a_sent_row() {
        let contact = [12u8; 16];
        let conn = conn_with_contact(contact);
        let id = insert_pending(&conn, &contact, PacketType::MsgText, "x", 1).unwrap();
        mark_sent(&conn, id).unwrap();

        mark_sending(&conn, id).unwrap();

        assert_eq!(list_for_contact(&conn, &contact).unwrap()[0].delivery_state, DeliveryState::Sent);
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
    fn mark_failed_only_moves_pending_messages() {
        let contact = [40u8; 16];
        let conn = conn_with_contact(contact);
        let pendente = insert_pending(&conn, &contact, PacketType::MsgText, "a", 0).unwrap();
        let enviada = insert_pending(&conn, &contact, PacketType::MsgText, "b", 1).unwrap();
        mark_sent(&conn, enviada).unwrap();

        mark_failed(&conn, pendente).unwrap();
        mark_failed(&conn, enviada).unwrap();

        let listed = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed[0].delivery_state, DeliveryState::Failed);
        assert_eq!(listed[1].delivery_state, DeliveryState::Sent);
        assert!(list_pending(&conn, &contact).unwrap().is_empty());
    }

    #[test]
    fn fail_pending_transfers_spares_text_and_finished_sends() {
        let contact = [41u8; 16];
        let conn = conn_with_contact(contact);
        let texto = insert_pending(&conn, &contact, PacketType::MsgText, "oi", 0).unwrap();
        let arquivo = insert_pending(&conn, &contact, PacketType::FileMetadata, "a.bin", 1).unwrap();
        let audio = insert_pending(&conn, &contact, PacketType::AudioChunk, "ab", 2).unwrap();
        let concluido = insert_pending(&conn, &contact, PacketType::FileMetadata, "b.bin", 3).unwrap();
        mark_sent(&conn, concluido).unwrap();
        insert_incoming(&conn, &contact, PacketType::FileMetadata, "c.bin", 4).unwrap();

        assert_eq!(fail_pending_transfers(&conn).unwrap(), 2);

        let by_id = |id: i64| {
            list_for_contact(&conn, &contact)
                .unwrap()
                .into_iter()
                .find(|m| m.id == id)
                .unwrap()
                .delivery_state
        };
        assert_eq!(by_id(texto), DeliveryState::Pending);
        assert_eq!(by_id(arquivo), DeliveryState::Failed);
        assert_eq!(by_id(audio), DeliveryState::Failed);
        assert_eq!(by_id(concluido), DeliveryState::Sent);
        let pendentes = list_pending(&conn, &contact).unwrap();
        assert_eq!(pendentes.len(), 1);
        assert_eq!(pendentes[0].id, texto);
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

    #[test]
    fn view_once_message_destroyed_on_mark_message_read() {
        let contact = [18u8; 16];
        let conn = conn_with_contact(contact);

        let json_body = r#"{"v":1,"type":"text","text":"segredo descartavel","viewOnce":true}"#;
        let id = insert_incoming(&conn, &contact, PacketType::MsgText, json_body, 1000).unwrap();

        let listed = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed.len(), 1);
        assert!(listed[0].view_once);
        assert!(listed[0].is_ephemeral);
        assert_eq!(listed[0].body, json_body);

        // Marca mensagem como lida
        mark_message_read(&conn, id, 1010).unwrap();

        // Chave efêmera K_msg foi destruída imediatamente
        let listed_after = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed_after[0].body, EXPIRED_BODY_PLACEHOLDER);
        assert!(listed_after[0].view_once);
    }

    fn json_with_id(id: &str, text: &str) -> String {
        format!(r#"{{"v":1,"type":"text","id":"{id}","text":"{text}"}}"#)
    }

    fn count_rows(conn: &rusqlite::Connection) -> i64 {
        conn.query_row("SELECT COUNT(*) FROM messages", [], |r| r.get(0)).unwrap()
    }

    #[test]
    fn ignores_duplicate_incoming_global_id() {
        let contact = [30u8; 16];
        let conn = conn_with_contact(contact);
        let body = json_with_id("dup-1", "oi");

        let first = insert_incoming(&conn, &contact, PacketType::MsgText, &body, 1000).unwrap();
        let second = insert_incoming(&conn, &contact, PacketType::MsgText, &body, 1005).unwrap();

        assert_eq!(first, second);
        assert_eq!(count_rows(&conn), 1);
    }

    #[test]
    fn duplicate_ephemeral_incoming_keeps_single_key() {
        let contact = [31u8; 16];
        let conn = conn_with_contact(contact);
        let body = r#"{"v":1,"type":"text","id":"dup-eph","text":"x","viewOnce":true}"#;

        let first = insert_incoming(&conn, &contact, PacketType::MsgText, body, 1000).unwrap();
        let second = insert_incoming(&conn, &contact, PacketType::MsgText, body, 1005).unwrap();

        assert_eq!(first, second);
        let keys: i64 = conn
            .query_row("SELECT COUNT(*) FROM ephemeral_message_keys", [], |r| r.get(0))
            .unwrap();
        assert_eq!(keys, 1);
    }

    #[test]
    fn same_global_id_from_different_contacts_is_kept() {
        let a = [32u8; 16];
        let b = [33u8; 16];
        let conn = conn_with_contact(a);
        conn.execute(
            "INSERT INTO contacts (device_id, signing_pubkey, dh_pubkey, paired_at, nickname)
             VALUES (?1, ?2, ?3, 1700000000, NULL)",
            rusqlite::params![b.as_slice(), [3u8; 32], [4u8; 32]],
        )
        .unwrap();
        let body = json_with_id("shared", "oi");

        let ia = insert_incoming(&conn, &a, PacketType::MsgText, &body, 1).unwrap();
        let ib = insert_incoming(&conn, &b, PacketType::MsgText, &body, 2).unwrap();

        assert_ne!(ia, ib);
        assert_eq!(count_rows(&conn), 2);
    }

    #[test]
    fn outgoing_global_id_does_not_block_incoming() {
        let contact = [34u8; 16];
        let conn = conn_with_contact(contact);
        let body = json_with_id("same-id", "oi");

        let out = insert_pending(&conn, &contact, PacketType::MsgText, &body, 1).unwrap();
        let inc = insert_incoming(&conn, &contact, PacketType::MsgText, &body, 2).unwrap();

        assert_ne!(out, inc);
        assert_eq!(count_rows(&conn), 2);
    }

    #[test]
    fn missing_global_id_never_dedups() {
        let contact = [35u8; 16];
        let conn = conn_with_contact(contact);

        let a = insert_incoming(&conn, &contact, PacketType::MsgText, "igual", 1).unwrap();
        let b = insert_incoming(&conn, &contact, PacketType::MsgText, "igual", 2).unwrap();

        assert_ne!(a, b);
        assert_eq!(count_rows(&conn), 2);
    }

    #[test]
    fn duplicate_keeps_original_ratchet_counter() {
        let contact = [36u8; 16];
        let conn = conn_with_contact(contact);
        let body = json_with_id("dup-ctr", "oi");

        let id = insert_incoming(&conn, &contact, PacketType::MsgText, &body, 1).unwrap();
        update_ratchet_counter(&conn, id, 7).unwrap();
        let again = insert_incoming(&conn, &contact, PacketType::MsgText, &body, 2).unwrap();
        update_ratchet_counter(&conn, again, 9).unwrap();

        let counter: i64 = conn
            .query_row("SELECT ratchet_counter FROM messages WHERE id = ?1", [id], |r| r.get(0))
            .unwrap();
        assert_eq!(counter, 7);
    }

    #[test]
    fn add_reaction_by_target_with_global_id() {
        let contact = [19u8; 16];
        let conn = conn_with_contact(contact);

        let json_body = r#"{"v":1,"type":"text","id":"uuid-abc-123","text":"mensagem original"}"#;
        let id = insert_incoming(&conn, &contact, PacketType::MsgText, json_body, 1000).unwrap();

        // Adiciona reação apontando para o identificador global
        let matched = add_reaction_by_target(&conn, "uuid-abc-123", &contact, "👏", 1005).unwrap();
        assert_eq!(matched, Some(id));

        let reactions = get_reactions_for_message(&conn, id).unwrap();
        assert_eq!(reactions, vec!["👏"]);

        let listed = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(listed[0].global_id.as_deref(), Some("uuid-abc-123"));
        assert_eq!(listed[0].reactions, vec!["👏"]);
    }

    #[test]
    fn mark_delivered_changes_state_and_matches_targets() {
        let contact = [20u8; 16];
        let conn = conn_with_contact(contact);

        let json_body = r#"{"v":1,"type":"text","id":"uuid-deliv-123","text":"mensagem para recibo"}"#;
        let id = insert_pending(&conn, &contact, PacketType::MsgText, json_body, 1000).unwrap();
        update_ratchet_counter(&conn, id, 42).unwrap();

        let msgs = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(msgs[0].delivery_state, DeliveryState::Pending);

        // Marca como sent
        mark_sent(&conn, id).unwrap();
        let msgs = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(msgs[0].delivery_state, DeliveryState::Sent);

        // Marca como delivered por global_id
        let matched = mark_delivered_by_target(&conn, "uuid-deliv-123", &contact).unwrap();
        assert_eq!(matched, Some(id));
        let msgs = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(msgs[0].delivery_state, DeliveryState::Delivered);

        // Testa busca por ratchet_counter em outra mensagem
        let id2 = insert_pending(&conn, &contact, PacketType::MsgText, "segunda", 1002).unwrap();
        update_ratchet_counter(&conn, id2, 99).unwrap();
        let matched2 = mark_delivered_by_target(&conn, "99", &contact).unwrap();
        assert_eq!(matched2, Some(id2));
        let msgs = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(msgs[1].delivery_state, DeliveryState::Delivered);
    }

    #[test]
    fn parse_receipt_target_id_handles_json_and_plain_text() {
        let json_payload = br#"{"v":1,"type":"receipt","targetId":"uuid-target-777"}"#;
        assert_eq!(parse_receipt_target_id(json_payload), Some("uuid-target-777".to_string()));

        let json_num = br#"{"targetId":88}"#;
        assert_eq!(parse_receipt_target_id(json_num), Some("88".to_string()));

        let plain = b"direct-id-999";
        assert_eq!(parse_receipt_target_id(plain), Some("direct-id-999".to_string()));
    }

    #[test]
    fn ephemeral_message_recorded_before_migration_opens_with_same_text() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        // Aplica migrations até a versão 9 (antes da migração de body_cipher_version)
        for migration in &crate::store::schema::MIGRATIONS[..9] {
            conn.execute_batch(migration).unwrap();
        }
        conn.pragma_update(None, "user_version", 9).unwrap();

        let contact = [25u8; 16];
        conn.execute(
            "INSERT INTO contacts (device_id, signing_pubkey, dh_pubkey, paired_at, nickname, suite_id)
             VALUES (?1, ?2, ?3, 1000, 'Legacy', 1)",
            rusqlite::params![contact.as_slice(), [1u8; 32].as_slice(), [2u8; 32].as_slice()],
        ).unwrap();

        // Insere mensagem efêmera no esquema antigo (sem coluna body_cipher_version explícita)
        let k_msg = crate::crypto::kdf::Key::from_bytes([0x77u8; 32]);
        let mut cipher_buf = b"mensagem secreta efemera".to_vec();
        crate::crypto::aead::seal_xchacha(&k_msg, EPHEMERAL_AAD, &mut cipher_buf).unwrap();
        let hex_body = hex::encode(&cipher_buf);

        conn.execute(
            "INSERT INTO messages
                (contact_device_id, direction, packet_type, body, delivery_state, created_at_unix_secs, is_ephemeral, global_id)
             VALUES (?1, 1, 16, ?2, 2, 2000, 1, 'legacy-ephemeral-gid')",
            rusqlite::params![contact.as_slice(), hex_body],
        ).unwrap();
        let msg_id = conn.last_insert_rowid();

        conn.execute(
            "INSERT INTO ephemeral_message_keys (message_id, key, read_at, expires_at)
             VALUES (?1, ?2, NULL, 5000)",
            rusqlite::params![msg_id, k_msg.as_bytes().as_slice()],
        ).unwrap();

        // Executa a migration 10 (que adiciona body_cipher_version DEFAULT 1)
        crate::store::schema::migrate(&conn).unwrap();

        // Lê a mensagem após a migration
        let msgs = list_for_contact(&conn, &contact).unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].body, "mensagem secreta efemera");
        assert!(msgs[0].is_ephemeral);
    }

    #[test]
    fn ephemeral_message_with_body_cipher_version_9_returns_error_not_corrupted_text() {
        let contact = [26u8; 16];
        let conn = conn_with_contact(contact);

        // Insere mensagem efêmera com body_cipher_version = 9
        let k_msg = crate::crypto::kdf::Key::from_bytes([0x88u8; 32]);
        let mut cipher_buf = b"texto nunca decifrado".to_vec();
        crate::crypto::aead::seal_xchacha(&k_msg, EPHEMERAL_AAD, &mut cipher_buf).unwrap();
        let hex_body = hex::encode(&cipher_buf);

        conn.execute(
            "INSERT INTO messages
                (contact_device_id, direction, packet_type, body, delivery_state, created_at_unix_secs, is_ephemeral, global_id, body_cipher_version)
             VALUES (?1, 1, 16, ?2, 2, 2000, 1, 'v9-ephemeral-gid', 9)",
            rusqlite::params![contact.as_slice(), hex_body],
        ).unwrap();
        let msg_id = conn.last_insert_rowid();

        conn.execute(
            "INSERT INTO ephemeral_message_keys (message_id, key, read_at, expires_at)
             VALUES (?1, ?2, NULL, 5000)",
            rusqlite::params![msg_id, k_msg.as_bytes().as_slice()],
        ).unwrap();

        // Tentar listar deve retornar erro explícito UnsupportedVersion(9), nunca texto corrompido
        let res = list_for_contact(&conn, &contact);
        assert!(matches!(res, Err(Error::UnsupportedVersion(9))));
    }

    #[test]
    fn ephemeral_message_with_retired_body_cipher_version_returns_suite_retired_error() {
        use crate::crypto::suite::set_suite_retired;

        let contact = [27u8; 16];
        let conn = conn_with_contact(contact);

        let k_msg = crate::crypto::kdf::Key::from_bytes([0x77u8; 32]);
        let mut cipher_buf = b"texto aposentado".to_vec();
        crate::crypto::aead::seal_xchacha(&k_msg, EPHEMERAL_AAD, &mut cipher_buf).unwrap();
        let hex_body = hex::encode(&cipher_buf);

        conn.execute(
            "INSERT INTO messages
                (contact_device_id, direction, packet_type, body, delivery_state, created_at_unix_secs, is_ephemeral, global_id, body_cipher_version)
             VALUES (?1, 1, 16, ?2, 2, 2000, 1, 'v1-retired-gid', 1)",
            rusqlite::params![contact.as_slice(), hex_body],
        ).unwrap();
        let msg_id = conn.last_insert_rowid();

        conn.execute(
            "INSERT INTO ephemeral_message_keys (message_id, key, read_at, expires_at)
             VALUES (?1, ?2, NULL, 5000)",
            rusqlite::params![msg_id, k_msg.as_bytes().as_slice()],
        ).unwrap();

        set_suite_retired(1, true);

        let res = list_for_contact(&conn, &contact);
        assert!(matches!(res, Err(Error::SuiteRetired(1))));

        set_suite_retired(1, false);
    }
}

