//! Migrations do banco cifrado.
//!
//! Runner artesanal em vez de uma crate de migrations: com uma única migração
//! hoje, `PRAGMA user_version` mais um array de instruções cobre o caso sem
//! trazer uma dependência cuja superfície (rollback, migrations nomeadas,
//! CLI) o projeto não usa.

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

        for table in ["local_identity", "contacts"] {
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
}
