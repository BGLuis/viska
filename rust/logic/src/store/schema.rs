//! Migrations do banco cifrado.
//!
//! Runner artesanal em vez de uma crate de migrations: `PRAGMA user_version`
//! mais um array de instruções cobre o caso sem trazer uma dependência cuja
//! superfície (rollback, migrations nomeadas, CLI) o projeto não usa.

/// Cada posição do array é a migração que leva da versão `i` para `i + 1`.
const MIGRATIONS: &[&str] = &[
    "\
    CREATE TABLE local_identity (
        id            INTEGER PRIMARY KEY CHECK (id = 0),
        device_id     BLOB NOT NULL,
        signing_seed  BLOB NOT NULL,
        dh_secret     BLOB NOT NULL,
        created_at    INTEGER NOT NULL
    );

    CREATE TABLE contacts (
        device_id       BLOB PRIMARY KEY,
        signing_pubkey  BLOB NOT NULL,
        dh_pubkey       BLOB NOT NULL,
        paired_at       INTEGER NOT NULL,
        nickname        TEXT
    );",
    "\
    CREATE TABLE messages (
        id                    INTEGER PRIMARY KEY AUTOINCREMENT,
        contact_device_id     BLOB NOT NULL REFERENCES contacts(device_id),
        direction             INTEGER NOT NULL,
        packet_type           INTEGER NOT NULL,
        body                  TEXT NOT NULL,
        delivery_state        INTEGER NOT NULL,
        ratchet_counter       INTEGER,
        created_at_unix_secs  INTEGER NOT NULL
    );
    CREATE INDEX idx_messages_contact ON messages (contact_device_id, created_at_unix_secs);",
    "\
    CREATE TABLE file_transfers (
        file_id               BLOB PRIMARY KEY,
        direction             INTEGER NOT NULL,
        contact_device_id     BLOB NOT NULL REFERENCES contacts(device_id),
        manifest_cbor         BLOB NOT NULL,
        transfer_secret       BLOB NOT NULL,
        created_at_unix_secs  INTEGER NOT NULL
    );",
];

/// Aplica as migrations pendentes, a partir de `PRAGMA user_version`.
pub fn migrate(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
    let current: i64 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    let current = current as usize;

    for (index, migration) in MIGRATIONS.iter().enumerate().skip(current) {
        conn.execute_batch(migration)?;
        conn.pragma_update(None, "user_version", (index + 1) as i64)?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrar_duas_vezes_e_idempotente() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        migrate(&conn).unwrap();
        migrate(&conn).unwrap();

        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, MIGRATIONS.len() as i64);
    }

    #[test]
    fn cria_as_tabelas_esperadas() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        migrate(&conn).unwrap();

        for table in ["local_identity", "contacts", "messages", "file_transfers"] {
            let exists: bool = conn
                .query_row(
                    "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    [table],
                    |row| row.get(0),
                )
                .unwrap();
            assert!(exists, "tabela {table} não foi criada");
        }
    }

    #[test]
    fn banco_so_com_a_primeira_migracao_ganha_messages_sem_perder_dado_existente() {
        // Simula um banco criado antes desta migração: só a primeira
        // instrução do array, `user_version = 1`. A migração de `messages`
        // precisa rodar sem tocar `local_identity`/`contacts` já existentes.
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.execute_batch(MIGRATIONS[0]).unwrap();
        conn.pragma_update(None, "user_version", 1i64).unwrap();
        conn.execute(
            "INSERT INTO contacts (device_id, signing_pubkey, dh_pubkey, paired_at, nickname)
             VALUES (?1, ?2, ?3, 1700000000, NULL)",
            rusqlite::params![[1u8; 16], [2u8; 32], [3u8; 32]],
        )
        .unwrap();

        migrate(&conn).unwrap();

        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, MIGRATIONS.len() as i64);

        let contacts: i64 = conn
            .query_row("SELECT COUNT(*) FROM contacts", [], |row| row.get(0))
            .unwrap();
        assert_eq!(contacts, 1, "contato existente não deveria sumir");

        let exists: bool = conn
            .query_row(
                "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type = 'table' AND name = 'messages'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(exists);
    }
}
