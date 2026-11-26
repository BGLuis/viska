//! Tabela de transferências de arquivo — Fase 4, D15.
//!
//! Guarda o que uma transferência precisa para sobreviver a bloqueio do cofre e
//! a reinício do app (§7.5): `transfer_secret` (D15 — a raiz de todas as chaves
//! da transferência, `file::keys`), o manifesto já codificado em CBOR, para
//! reconstruir `Manifest::decode` sem renegociar nada com o par, e se a oferta
//! já foi respondida (`answered`), que decide a re-oferta e o prazo de §7.7.
//! Cifrado em repouso pelo banco inteiro (D7) — não há cifra adicional aqui,
//! mesma política de `store::messages`.
//!
//! O progresso não é persistido: o emissor o reaprende do bitmap do primeiro
//! `FILE_FEEDBACK`, e o receptor o recompõe do próprio `.staging`.

use rusqlite::OptionalExtension;
use zeroize::Zeroizing;

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
#[derive(Clone, PartialEq, Eq)]
pub struct StoredTransfer {
    pub file_id: [u8; 16],
    pub direction: Direction,
    pub contact_device_id: [u8; 16],
    pub manifest_cbor: Vec<u8>,
    pub transfer_secret: Zeroizing<Vec<u8>>,
    pub created_at_unix_secs: i64,
    /// Arquivo comum ou nota de voz (Fase 5, D16) — persistido para uma
    /// transferência retomada saber qual chave rederivar (`K_symbol` vs.
    /// `K_audio_chunk`) sem precisar do `FILE_METADATA` de novo.
    pub kind: TransferKind,
    pub staging_cipher_version: u8,
    /// O destinatário já respondeu a oferta com um `FILE_FEEDBACK` (§7.7 item
    /// 5). Só faz sentido no envio.
    pub answered: bool,
    /// A oferta (`FILE_METADATA`) já foi selada para envio — falso enquanto o
    /// item só está na fila offline (D30).
    pub offered: bool,
}

impl core::fmt::Debug for StoredTransfer {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("StoredTransfer")
            .field("file_id", &hex::encode(self.file_id))
            .field("direction", &self.direction)
            .field("transfer_secret", &"<redigido>")
            .field("kind", &self.kind)
            .field("answered", &self.answered)
            .field("offered", &self.offered)
            .finish_non_exhaustive()
    }
}

const COLUMNS: &str = "file_id, direction, contact_device_id, manifest_cbor, transfer_secret, \
    created_at_unix_secs, kind, staging_cipher_version, answered, offered";

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
    offered: bool,
) -> Result<()> {
    conn.execute(
        "INSERT INTO file_transfers
            (file_id, direction, contact_device_id, manifest_cbor, transfer_secret, created_at_unix_secs, kind, staging_cipher_version, offered)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1, ?8)",
        rusqlite::params![
            file_id.as_slice(),
            direction as i64,
            contact_device_id.as_slice(),
            manifest_cbor,
            transfer_secret,
            created_at_unix_secs,
            kind as i64,
            i64::from(offered),
        ],
    )
    .map_err(|_| Error::Store)?;
    Ok(())
}

pub fn find(conn: &rusqlite::Connection, file_id: &[u8; 16]) -> Result<Option<StoredTransfer>> {
    conn.query_row(
        &format!("SELECT {COLUMNS} FROM file_transfers WHERE file_id = ?1"),
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
        .prepare(&format!(
            "SELECT {COLUMNS} FROM file_transfers
             WHERE contact_device_id = ?1 AND direction = ?2
             ORDER BY created_at_unix_secs ASC"
        ))
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

/// Uma transferência que passou de um prazo — só o necessário para encerrá-la,
/// sem `transfer_secret`: a varredura roda a cada feedback e leitura da
/// timeline, e não precisa tirar segredo do banco para isso.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DueTransfer {
    pub file_id: [u8; 16],
    pub contact_device_id: [u8; 16],
    pub direction: Direction,
    /// `true` quando venceu só o prazo da oferta sem resposta, não o teto de
    /// retenção.
    pub offer_expired: bool,
}

/// Transferências criadas até `retention_cutoff` (qualquer uma) ou envios,
/// de arquivo ou de voz, sem resposta criados até `offer_cutoff` (§7.5, §7.7
/// item 5). A voz entra porque a nota enfileirada sem sessão precisa da mesma
/// validade de 24 h do arquivo (D30); numa nota já oferecida, o primeiro
/// `FILE_FEEDBACK` do receptor, que aceita sozinho, encerra o prazo igual.
pub fn list_due(
    conn: &rusqlite::Connection,
    retention_cutoff: i64,
    offer_cutoff: i64,
) -> Result<Vec<DueTransfer>> {
    let mut statement = conn
        .prepare(
            "SELECT file_id, contact_device_id, direction, created_at_unix_secs > ?1
             FROM file_transfers
             WHERE created_at_unix_secs <= ?1
                OR (direction = ?3 AND answered = 0 AND created_at_unix_secs <= ?2)",
        )
        .map_err(|_| Error::Store)?;
    let rows = statement
        .query_map(
            rusqlite::params![retention_cutoff, offer_cutoff, Direction::Sending as i64],
            |row| {
                let file_id: Vec<u8> = row.get(0)?;
                let contact: Vec<u8> = row.get(1)?;
                let direction: i64 = row.get(2)?;
                let offer_expired: bool = row.get(3)?;
                Ok(DueTransfer {
                    file_id: file_id.try_into().map_err(|_| rusqlite::Error::InvalidQuery)?,
                    contact_device_id: contact.try_into().map_err(|_| rusqlite::Error::InvalidQuery)?,
                    direction: Direction::from_i64(direction).map_err(|_| rusqlite::Error::InvalidQuery)?,
                    offer_expired,
                })
            },
        )
        .map_err(|_| Error::Store)?;
    let mut due = Vec::new();
    for row in rows {
        due.push(row.map_err(|_| Error::Store)?);
    }
    Ok(due)
}

/// Envios ainda sem resposta do contato: o que ocupa a fila offline (D30),
/// sem tirar segredo do banco.
pub fn count_unanswered_sending(conn: &rusqlite::Connection, contact_device_id: &[u8; 16]) -> Result<usize> {
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM file_transfers
             WHERE contact_device_id = ?1 AND direction = ?2 AND answered = 0",
            rusqlite::params![contact_device_id.as_slice(), Direction::Sending as i64],
            |row| row.get(0),
        )
        .map_err(|_| Error::Store)?;
    usize::try_from(count).map_err(|_| Error::Store)
}

/// A transferência ainda tem linha — sem tirar o segredo do banco.
pub fn exists(conn: &rusqlite::Connection, file_id: &[u8; 16]) -> Result<bool> {
    conn.query_row(
        "SELECT 1 FROM file_transfers WHERE file_id = ?1",
        [file_id.as_slice()],
        |_| Ok(()),
    )
    .optional()
    .map(|row| row.is_some())
    .map_err(|_| Error::Store)
}

/// Registra que a oferta foi respondida: encerra o prazo de §7.7 item 5 e a
/// re-oferta na retomada. Idempotente.
pub fn mark_answered(conn: &rusqlite::Connection, file_id: &[u8; 16]) -> Result<()> {
    conn.execute(
        "UPDATE file_transfers SET answered = 1 WHERE file_id = ?1",
        [file_id.as_slice()],
    )
    .map_err(|_| Error::Store)?;
    Ok(())
}

/// Registra que a oferta (`FILE_METADATA`) já foi selada para envio. Idempotente;
/// devolve o `contact_device_id` só quando mudou de `0` para `1`.
pub fn mark_offered(conn: &rusqlite::Connection, file_id: &[u8; 16]) -> Result<Option<[u8; 16]>> {
    let contact: Option<Vec<u8>> = conn
        .query_row(
            "UPDATE file_transfers SET offered = 1 WHERE file_id = ?1 AND offered = 0 RETURNING contact_device_id",
            [file_id.as_slice()],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| Error::Store)?;
    contact
        .map(|raw| <[u8; 16]>::try_from(raw.as_slice()).map_err(|_| Error::Store))
        .transpose()
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

/// O aviso que o lado que encerrou uma transferência sozinho repete ao par
/// enquanto o par ainda age sobre ela (`docs/protocol.md` §7.8).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndNotice {
    /// O receptor concluiu: `FILE_COMPLETE`.
    Complete = 0,
    /// O receptor desistiu: `FILE_REJECT`.
    Reject = 1,
    /// O emissor desistiu: `FILE_CANCEL`.
    Cancel = 2,
}

impl EndNotice {
    fn from_i64(value: i64) -> Result<Self> {
        match value {
            0 => Ok(Self::Complete),
            1 => Ok(Self::Reject),
            2 => Ok(Self::Cancel),
            _ => Err(Error::Store),
        }
    }
}

/// Lápide de uma transferência encerrada só deste lado.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Tombstone {
    pub contact_device_id: [u8; 16],
    pub notice: EndNotice,
}

/// Apaga a linha e deixa a lápide no lugar, numa transação só: sem a linha não
/// se sabe mais o contato nem a criação, e uma lápide sem linha apagada faria
/// o par receber um aviso de uma transferência que continua. A lápide vence
/// quando a linha venceria (`created_at + retention_secs`, §7.5): depois disso
/// o par já desistiu sozinho pelo mesmo teto. Sem linha, não faz nada.
pub fn retire(
    conn: &rusqlite::Connection,
    file_id: &[u8; 16],
    notice: EndNotice,
    retention_secs: i64,
) -> Result<()> {
    let tx = conn.unchecked_transaction().map_err(|_| Error::Store)?;
    tx.execute(
        "INSERT OR REPLACE INTO ended_transfers (file_id, contact_device_id, notice, expires_at_unix_secs)
         SELECT file_id, contact_device_id, ?2, created_at_unix_secs + ?3
         FROM file_transfers WHERE file_id = ?1",
        rusqlite::params![file_id.as_slice(), notice as i64, retention_secs],
    )
    .map_err(|_| Error::Store)?;
    tx.execute("DELETE FROM file_transfers WHERE file_id = ?1", [file_id.as_slice()])
        .map_err(|_| Error::Store)?;
    tx.commit().map_err(|_| Error::Store)
}

/// A lápide de `file_id`, se ainda não venceu em `now`.
pub fn find_tombstone(conn: &rusqlite::Connection, file_id: &[u8; 16], now: i64) -> Result<Option<Tombstone>> {
    let row = conn
        .query_row(
            "SELECT contact_device_id, notice FROM ended_transfers
             WHERE file_id = ?1 AND expires_at_unix_secs > ?2",
            rusqlite::params![file_id.as_slice(), now],
            |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()
        .map_err(|_| Error::Store)?;
    let Some((contact, notice)) = row else {
        return Ok(None);
    };
    Ok(Some(Tombstone {
        contact_device_id: contact.try_into().map_err(|_| Error::Store)?,
        notice: EndNotice::from_i64(notice)?,
    }))
}

/// Apaga as lápides vencidas em `now`.
pub fn delete_expired_tombstones(conn: &rusqlite::Connection, now: i64) -> Result<()> {
    conn.execute("DELETE FROM ended_transfers WHERE expires_at_unix_secs <= ?1", [now])
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
    let staging_cipher_version: i64 = row.get(7)?;
    let answered: i64 = row.get(8)?;
    let offered: i64 = row.get(9)?;

    Ok(StoredTransfer {
        file_id: file_id.try_into().map_err(|_| rusqlite::Error::InvalidQuery)?,
        direction: Direction::from_i64(direction).map_err(|_| rusqlite::Error::InvalidQuery)?,
        contact_device_id: contact_device_id
            .try_into()
            .map_err(|_| rusqlite::Error::InvalidQuery)?,
        manifest_cbor,
        transfer_secret: Zeroizing::new(transfer_secret),
        created_at_unix_secs,
        kind: TransferKind::from_u8(kind as u8).map_err(|_| rusqlite::Error::InvalidQuery)?,
        staging_cipher_version: staging_cipher_version as u8,
        answered: answered != 0,
        offered: offered != 0,
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
            true,
        )
        .unwrap();

        let found = find(&conn, &file_id).unwrap().unwrap();
        assert_eq!(found.file_id, file_id);
        assert_eq!(found.direction, Direction::Sending);
        assert_eq!(found.contact_device_id, contact);
        assert_eq!(found.manifest_cbor, b"manifesto-cbor");
        assert_eq!(found.transfer_secret.as_slice(), b"segredo-de-32-bytes-ou-nao");
        assert!(!found.answered);
        assert!(found.offered);
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
            false,
        )
        .unwrap();

        assert!(exists(&conn, &file_id).unwrap());
        delete(&conn, &file_id).unwrap();
        assert!(find(&conn, &file_id).unwrap().is_none());
        assert!(!exists(&conn, &file_id).unwrap());
        delete(&conn, &file_id).unwrap(); // segunda chamada não deveria errar.
    }

    #[test]
    fn list_due_selects_by_ceiling_and_by_unanswered_offer() {
        let contact = [4u8; 16];
        let conn = conn_with_contact(contact);
        let rows = [
            ([1u8; 16], Direction::Sending, TransferKind::File, 100), // oferta vencida
            ([2u8; 16], Direction::Sending, TransferKind::File, 100), // respondida: não vence
            ([3u8; 16], Direction::Sending, TransferKind::Audio, 100), // voz sem resposta: vence igual
            ([4u8; 16], Direction::Receiving, TransferKind::File, 100), // recebimento: sem prazo de oferta
            ([5u8; 16], Direction::Receiving, TransferKind::File, 10), // passou do teto
            ([6u8; 16], Direction::Sending, TransferKind::File, 500), // ainda no prazo
        ];
        for (id, direction, kind, at) in rows {
            insert(&conn, &id, direction, &contact, b"m", b"s", at, kind, true).unwrap();
        }
        mark_answered(&conn, &[2u8; 16]).unwrap();
        mark_answered(&conn, &[2u8; 16]).unwrap();

        let due = list_due(&conn, 10, 100).unwrap();

        let ids: Vec<_> = due.iter().map(|d| d.file_id[0]).collect();
        assert_eq!(ids.len(), 3, "{ids:?}");
        let voice = due.iter().find(|d| d.file_id == [3u8; 16]).unwrap();
        assert!(voice.offer_expired);
        let offer = due.iter().find(|d| d.file_id == [1u8; 16]).unwrap();
        assert!(offer.offer_expired);
        assert_eq!(offer.direction, Direction::Sending);
        let ceiling = due.iter().find(|d| d.file_id == [5u8; 16]).unwrap();
        assert!(!ceiling.offer_expired);
        assert_eq!(ceiling.contact_device_id, contact);
    }

    #[test]
    fn counts_only_unanswered_sends_of_the_contact() {
        let contact = [8u8; 16];
        let conn = conn_with_contact(contact);
        insert(&conn, &[1u8; 16], Direction::Sending, &contact, b"m", b"s", 1, TransferKind::File, false).unwrap();
        insert(&conn, &[2u8; 16], Direction::Sending, &contact, b"m", b"s", 1, TransferKind::Audio, false).unwrap();
        insert(&conn, &[3u8; 16], Direction::Sending, &contact, b"m", b"s", 1, TransferKind::File, true).unwrap();
        insert(&conn, &[4u8; 16], Direction::Receiving, &contact, b"m", b"s", 1, TransferKind::File, false).unwrap();
        mark_answered(&conn, &[3u8; 16]).unwrap();

        assert_eq!(count_unanswered_sending(&conn, &contact).unwrap(), 2);
        assert_eq!(count_unanswered_sending(&conn, &[9u8; 16]).unwrap(), 0);
    }

    #[test]
    fn debug_never_prints_the_transfer_secret() {
        let contact = [7u8; 16];
        let conn = conn_with_contact(contact);
        insert(&conn, &[3u8; 16], Direction::Sending, &contact, b"m", b"segredo-visivel", 0, TransferKind::File, false)
            .unwrap();
        let shown = format!("{:?}", find(&conn, &[3u8; 16]).unwrap().unwrap());
        assert!(!shown.contains("segredo-visivel"));
        assert!(!shown.contains(&format!("{:?}", b"segredo-visivel".to_vec())));
        assert!(shown.contains("<redigido>"));
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
        insert(&conn, &recebendo_de_a, Direction::Receiving, &contact_a, b"m", b"s", 0, TransferKind::File, false).unwrap();
        insert(&conn, &enviando_para_a, Direction::Sending, &contact_a, b"m", b"s", 1, TransferKind::File, true).unwrap();
        insert(&conn, &recebendo_de_b, Direction::Receiving, &contact_b, b"m", b"s", 2, TransferKind::File, false).unwrap();

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
        insert(&conn, &a, Direction::Sending, &contact, b"m", b"s", 0, TransferKind::File, false).unwrap();
        insert(&conn, &b, Direction::Receiving, &contact, b"m", b"s", 0, TransferKind::Audio, false).unwrap();

        let mut ids = list_active_file_ids(&conn).unwrap();
        ids.sort();
        let mut expected = vec![a, b];
        expected.sort();
        assert_eq!(ids, expected);
    }


    #[test]
    fn retire_swaps_the_row_for_a_tombstone_that_expires_with_the_row() {
        let contact = [1u8; 16];
        let conn = conn_with_contact(contact);
        let file_id = [9u8; 16];
        insert(&conn, &file_id, Direction::Receiving, &contact, b"m", b"s", 1000, TransferKind::File, true).unwrap();

        retire(&conn, &file_id, EndNotice::Complete, 500).unwrap();

        assert!(find(&conn, &file_id).unwrap().is_none());
        let tombstone = find_tombstone(&conn, &file_id, 1499).unwrap().unwrap();
        assert_eq!(tombstone, Tombstone { contact_device_id: contact, notice: EndNotice::Complete });
        assert!(find_tombstone(&conn, &file_id, 1500).unwrap().is_none(), "vence com a linha");
        delete_expired_tombstones(&conn, 1499).unwrap();
        assert!(find_tombstone(&conn, &file_id, 0).unwrap().is_some());
        delete_expired_tombstones(&conn, 1500).unwrap();
        assert!(find_tombstone(&conn, &file_id, 0).unwrap().is_none());
    }

    #[test]
    fn retire_without_a_row_leaves_no_tombstone() {
        let conn = conn_with_contact([1u8; 16]);

        retire(&conn, &[9u8; 16], EndNotice::Cancel, 500).unwrap();

        assert!(find_tombstone(&conn, &[9u8; 16], 0).unwrap().is_none());
    }
}
