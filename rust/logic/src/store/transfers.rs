//! Tabela de transferências de arquivo — Fase 4, D15.
//!
//! Guarda só o que uma transferência precisa para sobreviver a uma queda de
//! conexão dentro da mesma execução do app: `transfer_secret` (D15 — a raiz
//! de todas as chaves da transferência, `file::keys`) e o manifesto já
//! codificado em CBOR, para reconstruir `Manifest::decode` sem precisar
//! renegociar nada com o par. Cifrado em repouso pelo banco inteiro (D7) —
//! não há cifra adicional aqui, mesma political de `store::messages`.
//!
//! Sobreviver a um **reinício do app** exigiria também persistir o
//! progresso (quais blocos já foram recebidos/confirmados) — não
//! implementado: hoje, reabrir o app com uma transferência pendente exige
//! recomeçá-la do zero. Registrado como lacuna conhecida, não decidida em
//! silêncio.

use rusqlite::OptionalExtension;

use crate::file::transfer::TransferKind;
use crate::{Error, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Sending = 0,
    Receiving = 1,
}

impl Direction {
    fn from_i64(value: i64) -> Result<Self> {
        match value {
            0 => Ok(Self::Sending),
            1 => Ok(Self::Receiving),
            _ => Err(Error::Store),
        }
    }
}

/// Uma transferência de arquivo persistida.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredTransfer {
    pub file_id: [u8; 16],
    pub direction: Direction,
    pub contact_device_id: [u8; 16],
    pub manifest_cbor: Vec<u8>,
    pub transfer_secret: Vec<u8>,
    pub created_at_unix_secs: i64,
    /// Arquivo comum ou nota de voz (Fase 5, D16) — persistido para uma
    /// transferência retomada saber qual chave rederivar (`K_symbol` vs.
    /// `K_audio_chunk`) sem precisar do `FILE_METADATA` de novo.
    pub kind: TransferKind,
}

#[allow(clippy::too_many_arguments)]
pub fn insert(
    conn: &rusqlite::Connection,
    file_id: &[u8; 16],
    direction: Direction,
    contact_device_id: &[u8; 16],
    manifest_cbor: &[u8],
    transfer_secret: &[u8],
    created_at_unix_secs: i64,
    kind: TransferKind,
) -> Result<()> {
    conn.execute(
        "INSERT INTO file_transfers
            (file_id, direction, contact_device_id, manifest_cbor, transfer_secret, created_at_unix_secs, kind)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![
            file_id.as_slice(),
            direction as i64,
            contact_device_id.as_slice(),
            manifest_cbor,
            transfer_secret,
            created_at_unix_secs,
            kind as i64,
        ],
    )
    .map_err(|_| Error::Store)?;
    Ok(())
}

pub fn find(conn: &rusqlite::Connection, file_id: &[u8; 16]) -> Result<Option<StoredTransfer>> {
    conn.query_row(
        "SELECT file_id, direction, contact_device_id, manifest_cbor, transfer_secret, created_at_unix_secs, kind
         FROM file_transfers WHERE file_id = ?1",
        [file_id.as_slice()],
        row_to_transfer,
    )
    .optional()
    .map_err(|_| Error::Store)
}

/// Transferências persistidas de/para um contato, numa direção — usado para
/// listar ofertas de recebimento pendentes (`Direction::Receiving`) sem
/// expor as de outros contatos.
pub fn list_for_contact(
    conn: &rusqlite::Connection,
    contact_device_id: &[u8; 16],
    direction: Direction,
) -> Result<Vec<StoredTransfer>> {
    let mut statement = conn
        .prepare(
            "SELECT file_id, direction, contact_device_id, manifest_cbor, transfer_secret, created_at_unix_secs, kind
             FROM file_transfers
             WHERE contact_device_id = ?1 AND direction = ?2
             ORDER BY created_at_unix_secs ASC",
        )
        .map_err(|_| Error::Store)?;

    let rows = statement
        .query_map(
            rusqlite::params![contact_device_id.as_slice(), direction as i64],
            row_to_transfer,
        )
        .map_err(|_| Error::Store)?;

    let mut transfers = Vec::new();
    for row in rows {
        transfers.push(row.map_err(|_| Error::Store)?);
    }
    Ok(transfers)
}

/// Todos os `file_id` persistidos — usado por
/// `file::staging::sweep_orphaned` para nunca apagar o `.staging` de uma
/// transferência que o banco ainda considera ativa.
pub fn list_active_file_ids(conn: &rusqlite::Connection) -> Result<Vec<[u8; 16]>> {
    let mut statement = conn
        .prepare("SELECT file_id FROM file_transfers")
        .map_err(|_| Error::Store)?;
    let rows = statement
        .query_map([], |row| row.get::<_, Vec<u8>>(0))
        .map_err(|_| Error::Store)?;

    let mut ids = Vec::new();
    for row in rows {
        let bytes = row.map_err(|_| Error::Store)?;
        let id: [u8; 16] = bytes.try_into().map_err(|_| Error::Store)?;
        ids.push(id);
    }
    Ok(ids)
}

/// Remove o registro — chamado ao completar ou abortar (D15: é isso que
/// torna `K_staging` irrecuperável, já que `transfer_secret` só existe
/// aqui e na RAM do processo em andamento).
pub fn delete(conn: &rusqlite::Connection, file_id: &[u8; 16]) -> Result<()> {
    conn.execute(
        "DELETE FROM file_transfers WHERE file_id = ?1",
        [file_id.as_slice()],
    )
    .map_err(|_| Error::Store)?;
    Ok(())
}

fn row_to_transfer(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredTransfer> {
    let file_id: Vec<u8> = row.get(0)?;
    let direction: i64 = row.get(1)?;
    let contact_device_id: Vec<u8> = row.get(2)?;
    let manifest_cbor: Vec<u8> = row.get(3)?;
    let transfer_secret: Vec<u8> = row.get(4)?;
    let created_at_unix_secs: i64 = row.get(5)?;
    let kind: i64 = row.get(6)?;

    Ok(StoredTransfer {
        file_id: file_id.try_into().map_err(|_| rusqlite::Error::InvalidQuery)?,
        direction: Direction::from_i64(direction).map_err(|_| rusqlite::Error::InvalidQuery)?,
        contact_device_id: contact_device_id
            .try_into()
            .map_err(|_| rusqlite::Error::InvalidQuery)?,
        manifest_cbor,
        transfer_secret,
        created_at_unix_secs,
        kind: TransferKind::from_u8(kind as u8).map_err(|_| rusqlite::Error::InvalidQuery)?,
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
    fn inserts_and_finds_transfer() {
        let contact = [1u8; 16];
        let conn = conn_with_contact(contact);
        let file_id = [9u8; 16];

        insert(
            &conn,
            &file_id,
            Direction::Sending,
            &contact,
            b"manifesto-cbor",
            b"segredo-de-32-bytes-ou-nao",
            1000,
            TransferKind::Audio,
        )
        .unwrap();

        let found = find(&conn, &file_id).unwrap().unwrap();
        assert_eq!(found.file_id, file_id);
        assert_eq!(found.direction, Direction::Sending);
        assert_eq!(found.contact_device_id, contact);
        assert_eq!(found.manifest_cbor, b"manifesto-cbor");
        assert_eq!(found.transfer_secret, b"segredo-de-32-bytes-ou-nao");
        assert_eq!(found.created_at_unix_secs, 1000);
        assert_eq!(found.kind, TransferKind::Audio);
    }

    #[test]
    fn nonexistent_transfer_returns_none() {
        let conn = conn_with_contact([2u8; 16]);
        assert!(find(&conn, &[0u8; 16]).unwrap().is_none());
    }

    #[test]
    fn delete_removes_and_is_idempotent() {
        let contact = [3u8; 16];
        let conn = conn_with_contact(contact);
        let file_id = [8u8; 16];
        insert(
            &conn,
            &file_id,
            Direction::Receiving,
            &contact,
            b"m",
            b"s",
            0,
            TransferKind::File,
        )
        .unwrap();

        delete(&conn, &file_id).unwrap();
        assert!(find(&conn, &file_id).unwrap().is_none());
        delete(&conn, &file_id).unwrap(); // segunda chamada não deveria errar.
    }

    #[test]
    fn list_for_contact_filters_by_direction_and_contact() {
        let contact_a = [5u8; 16];
        let contact_b = [6u8; 16];
        let conn = conn_with_contact(contact_a);
        conn.execute(
            "INSERT INTO contacts (device_id, signing_pubkey, dh_pubkey, paired_at, nickname)
             VALUES (?1, ?2, ?3, 1700000000, NULL)",
            rusqlite::params![contact_b.as_slice(), [9u8; 32], [8u8; 32]],
        )
        .unwrap();

        let recebendo_de_a = [1u8; 16];
        let enviando_para_a = [2u8; 16];
        let recebendo_de_b = [3u8; 16];
        insert(&conn, &recebendo_de_a, Direction::Receiving, &contact_a, b"m", b"s", 0, TransferKind::File).unwrap();
        insert(&conn, &enviando_para_a, Direction::Sending, &contact_a, b"m", b"s", 1, TransferKind::File).unwrap();
        insert(&conn, &recebendo_de_b, Direction::Receiving, &contact_b, b"m", b"s", 2, TransferKind::File).unwrap();

        let ofertas_de_a = list_for_contact(&conn, &contact_a, Direction::Receiving).unwrap();
        assert_eq!(ofertas_de_a.len(), 1);
        assert_eq!(ofertas_de_a[0].file_id, recebendo_de_a);
    }

    #[test]
    fn list_active_file_ids_returns_all() {
        let contact = [4u8; 16];
        let conn = conn_with_contact(contact);
        let a = [1u8; 16];
        let b = [2u8; 16];
        insert(&conn, &a, Direction::Sending, &contact, b"m", b"s", 0, TransferKind::File).unwrap();
        insert(&conn, &b, Direction::Receiving, &contact, b"m", b"s", 0, TransferKind::Audio).unwrap();

        let mut ids = list_active_file_ids(&conn).unwrap();
        ids.sort();
        let mut expected = vec![a, b];
        expected.sort();
        assert_eq!(ids, expected);
    }
}
