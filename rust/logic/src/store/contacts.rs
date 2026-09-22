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
    nickname: Option<&str>,
) -> Result<()> {
    conn.execute(
        "INSERT INTO contacts (device_id, signing_pubkey, dh_pubkey, paired_at, nickname)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT (device_id) DO UPDATE SET
            is_verified = CASE
                WHEN contacts.signing_pubkey != excluded.signing_pubkey OR contacts.dh_pubkey != excluded.dh_pubkey THEN 0
                ELSE contacts.is_verified
            END,
            signing_pubkey = excluded.signing_pubkey,
            dh_pubkey = excluded.dh_pubkey,
            paired_at = excluded.paired_at,
            nickname = COALESCE(excluded.nickname, contacts.nickname)",
        rusqlite::params![
            contact.device_id.as_slice(),
            contact.signing.as_slice(),
            contact.dh.as_bytes().as_slice(),
            paired_at_unix_secs,
            nickname,
        ],
    )
    .map_err(|_| Error::Store)?;

    Ok(())
}

pub fn update_nickname(
    conn: &rusqlite::Connection,
    device_id: &[u8; DEVICE_ID_LEN],
    nickname: &str,
) -> Result<()> {
    let count = conn.execute(
        "UPDATE contacts SET nickname = ?1 WHERE device_id = ?2",
        rusqlite::params![nickname, device_id.as_slice()],
    )
    .map_err(|_| Error::Store)?;

    if count == 0 {
        return Err(Error::ContactNotFound);
    }
    Ok(())
}

/// Registro de contato retornado pelo banco (identidade, timestamp de pareamento, apelido, verificado).
pub type StoredContact = (PublicIdentity, i64, Option<String>, bool);

pub fn list(conn: &rusqlite::Connection) -> Result<Vec<StoredContact>> {
    let mut statement = conn
        .prepare("SELECT device_id, signing_pubkey, dh_pubkey, paired_at, nickname, is_verified FROM contacts")
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
) -> Result<Option<StoredContact>> {
    conn.query_row(
        "SELECT device_id, signing_pubkey, dh_pubkey, paired_at, nickname, is_verified FROM contacts WHERE device_id = ?1",
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

/// Remove todos os contatos (usado para restauração limpa de backup).
pub fn clear(conn: &rusqlite::Connection) -> Result<()> {
    conn.execute("DELETE FROM contacts", []).map_err(|_| Error::Store)?;
    Ok(())
}

/// Define se o contato foi verificado.
pub fn set_verified(
    conn: &rusqlite::Connection,
    device_id: &[u8; DEVICE_ID_LEN],
    verified: bool,
) -> Result<()> {
    let count = conn.execute(
        "UPDATE contacts SET is_verified = ?1 WHERE device_id = ?2",
        rusqlite::params![
            if verified { 1 } else { 0 },
            device_id.as_slice()
        ],
    )
    .map_err(|_| Error::Store)?;

    if count == 0 {
        return Err(Error::ContactNotFound);
    }
    Ok(())
}

/// Define se o contato foi verificado e salva o Safety Number verificado.
pub fn set_verified_with_sn(
    conn: &rusqlite::Connection,
    device_id: &[u8; DEVICE_ID_LEN],
    is_verified: bool,
    verified_safety_number: Option<&str>,
) -> Result<()> {
    let count = conn.execute(
        "UPDATE contacts SET is_verified = ?1, verified_safety_number = ?2 WHERE device_id = ?3",
        rusqlite::params![
            if is_verified { 1 } else { 0 },
            verified_safety_number,
            device_id.as_slice()
        ],
    )
    .map_err(|_| Error::Store)?;

    if count == 0 {
        return Err(Error::ContactNotFound);
    }
    Ok(())
}

/// Consulta se o contato está verificado e o Safety Number salvo na verificação.
pub fn get_verified_status(
    conn: &rusqlite::Connection,
    device_id: &[u8; DEVICE_ID_LEN],
) -> Result<(bool, Option<String>)> {
    conn.query_row(
        "SELECT is_verified, verified_safety_number FROM contacts WHERE device_id = ?1",
        [device_id.as_slice()],
        |row| {
            let is_verified: i64 = row.get(0)?;
            let sn: Option<String> = row.get(1)?;
            Ok((is_verified != 0, sn))
        },
    )
    .optional()
    .map_err(|_| Error::Store)?
    .ok_or(Error::ContactNotFound)
}


fn row_to_contact(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredContact> {
    let device_id: Vec<u8> = row.get(0)?;
    let signing: Vec<u8> = row.get(1)?;
    let dh: Vec<u8> = row.get(2)?;
    let paired_at: i64 = row.get(3)?;
    let nickname: Option<String> = row.get(4)?;
    let is_verified: i64 = row.get(5).unwrap_or(0);

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
        nickname,
        is_verified != 0,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::identity::LocalIdentity;

    fn setup_test_db() -> rusqlite::Connection {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::store::schema::migrate(&conn).unwrap();
        conn
    }

    #[test]
    fn update_nickname_on_unknown_contact_fails() {
        let conn = setup_test_db();
        let unknown_id = [0x99; DEVICE_ID_LEN];
        let err = update_nickname(&conn, &unknown_id, "Novo Nome");
        assert!(matches!(err, Err(Error::ContactNotFound)));
    }

    #[test]
    fn get_ephemeral_ttl_on_unknown_contact_fails() {
        let conn = setup_test_db();
        let unknown_id = [0x99; DEVICE_ID_LEN];
        let err = get_ephemeral_ttl(&conn, &unknown_id);
        assert!(matches!(err, Err(Error::ContactNotFound)));
    }

    #[test]
    fn insert_conflict_updates_keys_and_preserves_existing_nickname() {
        let conn = setup_test_db();
        let id1 = LocalIdentity::generate().unwrap().public();
        let id2 = LocalIdentity::generate().unwrap().public();
        // Mesma identidade de contato (mesmo device_id), mas com chaves atualizadas
        let updated_contact = PublicIdentity {
            device_id: id1.device_id,
            signing: id2.signing,
            dh: id2.dh,
        };

        insert(&conn, &id1, 1000, Some("Amigo Original")).unwrap();
        // Re-insere com nickname None: COALESCE deve manter "Amigo Original"
        insert(&conn, &updated_contact, 2000, None).unwrap();

        let found = find_by_device_id(&conn, &id1.device_id).unwrap().unwrap();
        assert_eq!(found.0.signing, id2.signing);
        assert_eq!(found.0.dh, id2.dh);
        assert_eq!(found.1, 2000);
        assert_eq!(found.2.as_deref(), Some("Amigo Original"));

        // Re-insere com novo nickname: deve sobrescrever
        insert(&conn, &updated_contact, 3000, Some("Amigo Renomeado")).unwrap();
        let found2 = find_by_device_id(&conn, &id1.device_id).unwrap().unwrap();
        assert_eq!(found2.1, 3000);
        assert_eq!(found2.2.as_deref(), Some("Amigo Renomeado"));
    }

    #[test]
    fn set_verified_and_get_status() {
        let conn = setup_test_db();
        let id1 = LocalIdentity::generate().unwrap().public();
        insert(&conn, &id1, 1000, Some("Contato Confiavel")).unwrap();

        let (verified, sn) = get_verified_status(&conn, &id1.device_id).unwrap();
        assert!(!verified);
        assert!(sn.is_none());

        set_verified(&conn, &id1.device_id, true).unwrap();
        let found = find_by_device_id(&conn, &id1.device_id).unwrap().unwrap();
        assert!(found.3);

        set_verified_with_sn(&conn, &id1.device_id, true, Some("12345 67890")).unwrap();
        let (verified, sn) = get_verified_status(&conn, &id1.device_id).unwrap();
        assert!(verified);
        assert_eq!(sn.as_deref(), Some("12345 67890"));

        // Se chaves mudarem no re-pareamento, is_verified deve ser resetado para false
        let id2 = LocalIdentity::generate().unwrap().public();
        let updated_contact = PublicIdentity {
            device_id: id1.device_id,
            signing: id2.signing,
            dh: id2.dh,
        };
        insert(&conn, &updated_contact, 2000, None).unwrap();
        let (verified_after, sn_after) = get_verified_status(&conn, &id1.device_id).unwrap();
        assert!(!verified_after);
        // O Safety Number anterior permanece preservado para alertar sobre mudança de chave!
        assert_eq!(sn_after.as_deref(), Some("12345 67890"));
    }
}
