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
    "\
    ALTER TABLE file_transfers ADD COLUMN kind INTEGER NOT NULL DEFAULT 0;",
    "\
    ALTER TABLE contacts ADD COLUMN ephemeral_ttl INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE messages ADD COLUMN is_ephemeral INTEGER NOT NULL DEFAULT 0;
    CREATE TABLE ephemeral_message_keys (
        message_id           INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
        key                  BLOB NOT NULL,
        read_at              INTEGER,
        expires_at           INTEGER NOT NULL
    );
    CREATE INDEX idx_ephemeral_keys_expiry ON ephemeral_message_keys (expires_at);",
    "\
    CREATE TABLE app_config (
        key    TEXT PRIMARY KEY,
        value  TEXT NOT NULL
    );",
    "\
    ALTER TABLE contacts ADD COLUMN is_verified INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE contacts ADD COLUMN verified_safety_number TEXT;
    ALTER TABLE messages ADD COLUMN reply_to_id INTEGER;
    ALTER TABLE messages ADD COLUMN view_once INTEGER NOT NULL DEFAULT 0;
    CREATE TABLE message_reactions (
        message_id           INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        contact_device_id    BLOB NOT NULL REFERENCES contacts(device_id),
        emoji                TEXT NOT NULL,
        created_at_unix_secs INTEGER NOT NULL,
        PRIMARY KEY (message_id, contact_device_id)
    );
    CREATE TABLE decoy_vault_config (
        id            INTEGER PRIMARY KEY CHECK (id = 0),
        is_enabled    INTEGER NOT NULL DEFAULT 0,
        duress_pin    TEXT,
        action_mode   INTEGER NOT NULL DEFAULT 0
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
    fn migrating_twice_is_idempotent() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        migrate(&conn).unwrap();
        migrate(&conn).unwrap();

        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, MIGRATIONS.len() as i64);
    }

    #[test]
    fn creates_expected_tables() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        migrate(&conn).unwrap();

        for table in [
            "local_identity",
            "contacts",
            "messages",
            "file_transfers",
            "ephemeral_message_keys",
            "app_config",
            "message_reactions",
            "decoy_vault_config",
        ] {
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
    fn db_with_only_first_migration_adds_messages_without_losing_existing_data() {
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

    #[test]
    fn db_up_to_file_transfers_adds_kind_column_with_default_without_losing_existing_data() {
        // Simula um banco criado antes da Fase 5: as três primeiras
        // migrações, sem a coluna `kind` — uma transferência de arquivo já
        // persistida (Fase 4) precisa sobreviver com `kind = 0` (File).
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        for migration in &MIGRATIONS[..3] {
            conn.execute_batch(migration).unwrap();
        }
        conn.pragma_update(None, "user_version", 3i64).unwrap();
        conn.execute(
            "INSERT INTO contacts (device_id, signing_pubkey, dh_pubkey, paired_at, nickname)
             VALUES (?1, ?2, ?3, 1700000000, NULL)",
            rusqlite::params![[9u8; 16], [1u8; 32], [2u8; 32]],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO file_transfers
                (file_id, direction, contact_device_id, manifest_cbor, transfer_secret, created_at_unix_secs)
             VALUES (?1, 0, ?2, ?3, ?4, 1000)",
            rusqlite::params![[7u8; 16], [9u8; 16], b"manifesto".as_slice(), b"segredo".as_slice()],
        )
        .unwrap();

        migrate(&conn).unwrap();

        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, MIGRATIONS.len() as i64);

        let kind: i64 = conn
            .query_row(
                "SELECT kind FROM file_transfers WHERE file_id = ?1",
                [[7u8; 16].as_slice()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(kind, 0, "transferência pré-Fase-5 deveria ganhar kind=File por default");
    }

    #[test]
    fn db_up_to_app_config_adds_verified_columns_without_losing_existing_contacts() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        for migration in &MIGRATIONS[..6] {
            conn.execute_batch(migration).unwrap();
        }
        conn.pragma_update(None, "user_version", 6i64).unwrap();
        conn.execute(
            "INSERT INTO contacts (device_id, signing_pubkey, dh_pubkey, paired_at, nickname)
             VALUES (?1, ?2, ?3, 1700000000, 'Amigo')",
            rusqlite::params![[9u8; 16], [1u8; 32], [2u8; 32]],
        )
        .unwrap();

        migrate(&conn).unwrap();

        let (is_verified, verified_sn): (i64, Option<String>) = conn
            .query_row(
                "SELECT is_verified, verified_safety_number FROM contacts WHERE device_id = ?1",
                [[9u8; 16].as_slice()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(is_verified, 0);
        assert!(verified_sn.is_none());

        // Valida que messages agora possui reply_to_id e view_once
        conn.execute(
            "INSERT INTO messages
                (contact_device_id, direction, packet_type, body, delivery_state, created_at_unix_secs, is_ephemeral, reply_to_id, view_once)
             VALUES (?1, 0, 0x10, 'teste', 0, 1000, 0, NULL, 0)",
            [[9u8; 16].as_slice()],
        )
        .unwrap();

        let msg_id = conn.last_insert_rowid();

        // Valida message_reactions
        conn.execute(
            "INSERT INTO message_reactions (message_id, contact_device_id, emoji, created_at_unix_secs)
             VALUES (?1, ?2, '👍', 1001)",
            rusqlite::params![msg_id, [9u8; 16].as_slice()],
        )
        .unwrap();

        // Valida decoy_vault_config
        conn.execute(
            "INSERT INTO decoy_vault_config (id, is_enabled, duress_pin, action_mode)
             VALUES (0, 1, '1234', 1)",
            [],
        )
        .unwrap();
    }
}
