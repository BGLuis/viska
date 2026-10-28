//! Tabela de contatos pareados.
//!
//! Tudo aqui é dado público — exatamente o que atravessou o QR Code e foi
//! verificado em `crypto::pairing::decode_qr`. Cifrar em repouso protege
//! contra quem tem acesso ao arquivo do banco, não porque as chaves em si
//! sejam segredo.

use crate::crypto::dh::DhPublic;
use crate::crypto::identity::{PublicIdentity, DEVICE_ID_LEN, SIGNING_KEY_LEN};
use crate::crypto::Suite;
use crate::{Error, Result};
use rusqlite::OptionalExtension;

#[allow(dead_code)]
pub fn insert(
    conn: &rusqlite::Connection,
    contact: &PublicIdentity,
    paired_at_unix_secs: i64,
    nickname: Option<&str>,
) -> Result<()> {
    insert_with_suite(conn, contact, paired_at_unix_secs, nickname, 1)
}

pub fn insert_with_suite(
    conn: &rusqlite::Connection,
    contact: &PublicIdentity,
    paired_at_unix_secs: i64,
    nickname: Option<&str>,
    suite_id: u8,
) -> Result<()> {
    if Suite::is_retired(suite_id) {
        return Err(Error::SuiteRetired(suite_id));
    }

    if let Some((existing_id, _, _, _)) = find_by_device_id(conn, &contact.device_id)? {
        // Se o device_id já existe mas as chaves diferem, recusa a substituição para
        // evitar que um atacante troque silenciosamente a identidade do contato (S-13).
        if existing_id.signing != contact.signing || existing_id.dh != contact.dh {
            return Err(Error::ContactKeyMismatch);
        }
        // Se as chaves são as mesmas, preserva o contato e atualiza o apelido se fornecido.
        if let Some(nick) = nickname {
            conn.execute(
                "UPDATE contacts SET nickname = ?1 WHERE device_id = ?2",
                rusqlite::params![nick, contact.device_id.as_slice()],
            )
            .map_err(|_| Error::Store)?;
        }
        return Ok(());
    }

    conn.execute(
        "INSERT INTO contacts (device_id, signing_pubkey, dh_pubkey, paired_at, nickname, suite_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        rusqlite::params![
            contact.device_id.as_slice(),
            contact.signing.as_slice(),
            contact.dh.as_bytes().as_slice(),
            paired_at_unix_secs,
            nickname,
            suite_id as i64,
        ],
    )
    .map_err(|_| Error::Store)?;

    Ok(())
}

/// Atualiza explicitamente as chaves criptográficas de um contato existente após
/// consentimento do usuário durante re-pareamento presencial.
///
/// Só aceita suíte estritamente maior que a atualmente gravada no banco (§10, D24).
/// Preserva histórico de mensagens e apelido, e reseta a verificação (`is_verified = 0`).
pub fn update_keys(
    conn: &rusqlite::Connection,
    contact: &PublicIdentity,
    new_suite: u8,
) -> Result<()> {
    if Suite::is_retired(new_suite) {
        return Err(Error::SuiteRetired(new_suite));
    }
    let recorded_suite = get_suite_id(conn, &contact.device_id)?;
    if new_suite <= recorded_suite {
        return Err(Error::UnsupportedVersion(new_suite));
    }

    let count = conn.execute(
        "UPDATE contacts SET
            signing_pubkey = ?1,
            dh_pubkey = ?2,
            suite_id = ?3,
            is_verified = 0
         WHERE device_id = ?4",
        rusqlite::params![
            contact.signing.as_slice(),
            contact.dh.as_bytes().as_slice(),
            new_suite as i64,
            contact.device_id.as_slice(),
        ],
    )
    .map_err(|_| Error::Store)?;

    if count == 0 {
        return Err(Error::ContactNotFound);
    }
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

/// Consulta a suite_id gravada para o contato.
pub fn get_suite_id(
    conn: &rusqlite::Connection,
    device_id: &[u8; DEVICE_ID_LEN],
) -> Result<u8> {
    let suite_id: i64 = conn
        .query_row(
            "SELECT suite_id FROM contacts WHERE device_id = ?1",
            [device_id.as_slice()],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| Error::Store)?
        .ok_or(Error::ContactNotFound)?;
    u8::try_from(suite_id).map_err(|_| Error::Store)
}

/// Atualiza a suite_id gravada para o contato (após conclusão de handshake em suíte nova).
pub fn update_suite_id(
    conn: &rusqlite::Connection,
    device_id: &[u8; DEVICE_ID_LEN],
    suite_id: u8,
) -> Result<()> {
    let count = conn
        .execute(
            "UPDATE contacts SET suite_id = ?1 WHERE device_id = ?2",
            rusqlite::params![suite_id as i64, device_id.as_slice()],
        )
        .map_err(|_| Error::Store)?;
    if count == 0 {
        return Err(Error::ContactNotFound);
    }
    Ok(())
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
    fn insert_rejects_new_keys_for_existing_device_id() {
        let conn = setup_test_db();
        let id1 = LocalIdentity::generate().unwrap().public();
        let id2 = LocalIdentity::generate().unwrap().public();
        // Mesma identidade de contato (mesmo device_id), mas com chaves diferentes
        let updated_contact = PublicIdentity {
            device_id: id1.device_id,
            signing: id2.signing,
            dh: id2.dh,
        };

        insert(&conn, &id1, 1000, Some("Amigo Original")).unwrap();

        // Tentar inserir com chaves diferentes deve falhar com ContactKeyMismatch
        let err = insert(&conn, &updated_contact, 2000, None).unwrap_err();
        assert!(matches!(err, Error::ContactKeyMismatch));

        // Dados originais devem permanecer inalterados
        let found = find_by_device_id(&conn, &id1.device_id).unwrap().unwrap();
        assert_eq!(found.0.signing, id1.signing);
        assert_eq!(found.0.dh, id1.dh);
        assert_eq!(found.1, 1000);
        assert_eq!(found.2.as_deref(), Some("Amigo Original"));

        // Re-inserir com as MESMAS chaves e novo apelido deve ter sucesso
        insert(&conn, &id1, 1500, Some("Amigo Renomeado")).unwrap();
        let found2 = find_by_device_id(&conn, &id1.device_id).unwrap().unwrap();
        assert_eq!(found2.0.signing, id1.signing);
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

        // Se chaves forem atualizadas explicitamente via update_keys, is_verified deve ser resetado para false
        let id2 = LocalIdentity::generate().unwrap().public();
        let updated_contact = PublicIdentity {
            device_id: id1.device_id,
            signing: id2.signing,
            dh: id2.dh,
        };
        update_keys(&conn, &updated_contact, 2).unwrap();
        let (verified_after, sn_after) = get_verified_status(&conn, &id1.device_id).unwrap();
        assert!(!verified_after);
        // O Safety Number anterior permanece preservado para alertar sobre mudança de chave!
        assert_eq!(sn_after.as_deref(), Some("12345 67890"));
    }

    #[test]
    fn repair_contact_from_suite_1_to_suite_2_preserves_messages_and_nickname_and_clears_verified() {
        let conn = setup_test_db();
        let id1 = LocalIdentity::generate().unwrap().public();
        insert(&conn, &id1, 1000, Some("Amigo Bob")).unwrap();
        set_verified(&conn, &id1.device_id, true).unwrap();
        assert!(find_by_device_id(&conn, &id1.device_id).unwrap().unwrap().3);

        // Insere mensagem para Bob
        conn.execute(
            "INSERT INTO messages (contact_device_id, direction, packet_type, body, delivery_state, created_at_unix_secs)
             VALUES (?1, 0, 0x10, 'historico preservado', 0, 1000)",
            rusqlite::params![id1.device_id.as_slice()],
        ).unwrap();

        // Bob gera novas chaves para suíte 2
        let id2 = LocalIdentity::generate().unwrap().public();
        let bob_v2 = PublicIdentity {
            device_id: id1.device_id,
            signing: id2.signing,
            dh: id2.dh,
        };

        // Re-pareamento na suíte 2
        update_keys(&conn, &bob_v2, 2).unwrap();

        // Contato atualizado: suíte é 2, chaves novas, apelido preservado, is_verified zerado
        let contact = find_by_device_id(&conn, &id1.device_id).unwrap().unwrap();
        assert_eq!(contact.0.signing, id2.signing);
        assert_eq!(contact.0.dh, id2.dh);
        assert_eq!(contact.2.as_deref(), Some("Amigo Bob"));
        assert_eq!(contact.3, false, "is_verified deve ser zerado no re-pareamento");
        assert_eq!(get_suite_id(&conn, &id1.device_id).unwrap(), 2);

        // Mensagens anteriores preservadas
        let msg_count: i64 = conn.query_row(
            "SELECT count(*) FROM messages WHERE contact_device_id = ?1",
            rusqlite::params![id1.device_id.as_slice()],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(msg_count, 1);
    }

    #[test]
    fn repair_attempting_to_downgrade_or_keep_suite_is_rejected_and_contact_intact() {
        let conn = setup_test_db();
        let id1 = LocalIdentity::generate().unwrap().public();
        insert(&conn, &id1, 1000, Some("Amigo")).unwrap();
        update_suite_id(&conn, &id1.device_id, 2).unwrap();
        assert_eq!(get_suite_id(&conn, &id1.device_id).unwrap(), 2);

        let id2 = LocalIdentity::generate().unwrap().public();
        let bob_downgrade = PublicIdentity {
            device_id: id1.device_id,
            signing: id2.signing,
            dh: id2.dh,
        };

        // Tenta re-parear para suíte 1 (menor que 2): recusado
        let err1 = update_keys(&conn, &bob_downgrade, 1).unwrap_err();
        assert!(matches!(err1, Error::UnsupportedVersion(1)));

        // Tenta re-parear para mesma suíte 2 (não é maior): recusado
        let err2 = update_keys(&conn, &bob_downgrade, 2).unwrap_err();
        assert!(matches!(err2, Error::UnsupportedVersion(2)));

        // Contato continua intacto na suíte 2 com as chaves originais
        let contact = find_by_device_id(&conn, &id1.device_id).unwrap().unwrap();
        assert_eq!(contact.0.signing, id1.signing);
        assert_eq!(contact.0.dh, id1.dh);
        assert_eq!(get_suite_id(&conn, &id1.device_id).unwrap(), 2);
    }

    #[test]
    fn insert_with_suite_and_update_keys_reject_retired_suite() {
        use crate::crypto::suite::set_suite_retired;

        let conn = setup_test_db();
        let id1 = LocalIdentity::generate().unwrap().public();

        set_suite_retired(1, true);

        // Tentar inserir com suíte aposentada retorna SuiteRetired(1)
        let res = insert_with_suite(&conn, &id1, 1000, Some("RetiredPeer"), 1);
        assert!(matches!(res, Err(Error::SuiteRetired(1))));

        set_suite_retired(1, false);

        // Insere com sucesso na suíte 1
        insert_with_suite(&conn, &id1, 1000, Some("Peer"), 1).unwrap();
        assert_eq!(get_suite_id(&conn, &id1.device_id).unwrap(), 1);

        // Aposenta a suíte 2
        set_suite_retired(2, true);
        let id2 = LocalIdentity::generate().unwrap().public();
        let updated = PublicIdentity {
            device_id: id1.device_id,
            signing: id2.signing,
            dh: id2.dh,
        };

        // Re-pareamento para a suíte 2 desativada deve ser recusado
        let res_update = update_keys(&conn, &updated, 2);
        assert!(matches!(res_update, Err(Error::SuiteRetired(2))));

        set_suite_retired(2, false);
    }
}
