//! Tabela de contatos pareados.
//!
//! Tudo aqui é dado público — exatamente o que atravessou o QR Code e foi
//! verificado em `crypto::pairing::decode_qr`. Cifrar em repouso protege
//! contra quem tem acesso ao arquivo do banco, não porque as chaves em si
//! sejam segredo.

use crate::crypto::dh::DhPublic;
use crate::crypto::identity::{PublicIdentity, DEVICE_ID_LEN, SIGNING_KEY_LEN};
use crate::{Error, Result};
use rusqlite::OptionalExtension;

pub fn insert(
    conn: &rusqlite::Connection,
    contact: &PublicIdentity,
    paired_at_unix_secs: i64,
) -> Result<()> {
    conn.execute(
        "INSERT INTO contacts (device_id, signing_pubkey, dh_pubkey, paired_at, nickname)
         VALUES (?1, ?2, ?3, ?4, NULL)
         ON CONFLICT (device_id) DO UPDATE SET
            signing_pubkey = excluded.signing_pubkey,
            dh_pubkey = excluded.dh_pubkey,
            paired_at = excluded.paired_at",
        rusqlite::params![
            contact.device_id.as_slice(),
            contact.signing.as_slice(),
            contact.dh.as_bytes().as_slice(),
            paired_at_unix_secs,
        ],
    )
    .map_err(|_| Error::Store)?;

    Ok(())
}

pub fn list(conn: &rusqlite::Connection) -> Result<Vec<(PublicIdentity, i64)>> {
    let mut statement = conn
        .prepare("SELECT device_id, signing_pubkey, dh_pubkey, paired_at FROM contacts")
        .map_err(|_| Error::Store)?;

    let rows = statement
        .query_map([], row_to_contact)
        .map_err(|_| Error::Store)?;

    let mut contacts = Vec::new();
    for row in rows {
        contacts.push(row.map_err(|_| Error::Store)?);
    }
    Ok(contacts)
}

pub fn find_by_device_id(
    conn: &rusqlite::Connection,
    device_id: &[u8; DEVICE_ID_LEN],
) -> Result<Option<(PublicIdentity, i64)>> {
    conn.query_row(
        "SELECT device_id, signing_pubkey, dh_pubkey, paired_at FROM contacts WHERE device_id = ?1",
        [device_id.as_slice()],
        row_to_contact,
    )
    .optional()
    .map_err(|_| Error::Store)
}

/// Define o TTL (em segundos) das mensagens efêmeras trocadas com este contato.
/// `0` significa mensagens permanentes (desligado).
pub fn set_ephemeral_ttl(
    conn: &rusqlite::Connection,
    device_id: &[u8; DEVICE_ID_LEN],
    ttl_secs: i64,
) -> Result<()> {
    conn.execute(
        "UPDATE contacts SET ephemeral_ttl = ?1 WHERE device_id = ?2",
        rusqlite::params![ttl_secs, device_id.as_slice()],
    )
    .map_err(|_| Error::Store)?;
    Ok(())
}

/// Consulta o TTL configurado para o contato.
pub fn get_ephemeral_ttl(
    conn: &rusqlite::Connection,
    device_id: &[u8; DEVICE_ID_LEN],
) -> Result<i64> {
    conn.query_row(
        "SELECT ephemeral_ttl FROM contacts WHERE device_id = ?1",
        [device_id.as_slice()],
        |row| row.get(0),
    )
    .optional()
    .map_err(|_| Error::Store)?
    .ok_or(Error::ContactNotFound)
}

fn row_to_contact(row: &rusqlite::Row<'_>) -> rusqlite::Result<(PublicIdentity, i64)> {
    let device_id: Vec<u8> = row.get(0)?;
    let signing: Vec<u8> = row.get(1)?;
    let dh: Vec<u8> = row.get(2)?;
    let paired_at: i64 = row.get(3)?;

    let device_id: [u8; DEVICE_ID_LEN] = device_id
        .try_into()
        .map_err(|_| rusqlite::Error::InvalidQuery)?;
    let signing: [u8; SIGNING_KEY_LEN] = signing
        .try_into()
        .map_err(|_| rusqlite::Error::InvalidQuery)?;
    let dh = DhPublic::from_slice(&dh).map_err(|_| rusqlite::Error::InvalidQuery)?;

    Ok((
        PublicIdentity {
            device_id,
            signing,
            dh,
        },
        paired_at,
    ))
}
