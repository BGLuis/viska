//! Persistência cifrada — banco SQLCipher dentro do núcleo Rust (D7).
//!
//! O banco nunca é aberto pelo lado Dart: `Store` guarda a `rusqlite::Connection`
//! e só devolve tipos já decodificados. A chave de cifragem em repouso deriva de
//! [`kdf::context::DATABASE`] a partir do segredo mestre entregue por
//! [`keyring`] — nunca de uma senha de usuário nem de nada que atravesse o FFI.

mod contacts;
mod identity;
pub mod keyring;
pub mod messages;
mod schema;
pub mod transfers;

use std::path::Path;
use std::sync::Mutex;

use crate::crypto::identity::{LocalIdentity, PublicIdentity};
use crate::crypto::kdf;
use crate::wire::packet_type::PacketType;
use crate::{Error, Result};

/// Banco de dados cifrado de um dispositivo: identidade local e contatos.
///
/// A conexão fica atrás de um `Mutex`: `rusqlite::Connection` usa mutação
/// interna sem sincronização própria (`!Sync`), e `Store` precisa ser
/// `Send + Sync` para virar tipo opaco do FFI, cujos métodos são despachados
/// de forma assíncrona e podem correr em threads diferentes do pool do
/// `flutter_rust_bridge`. Acesso concorrente a uma única conexão SQLite sem
/// essa serialização já seria incorreto com ou sem FFI.
pub struct Store {
    conn: Mutex<rusqlite::Connection>,
}

impl Store {
    /// Abre (criando se necessário) o banco em `path`, cifrado com a chave
    /// derivada de `master_secret`.
    ///
    /// Erros de chave errada, arquivo corrompido ou falha de I/O colapsam todos
    /// em [`Error::Store`] — mesma filosofia de [`Error::AeadFailure`]: a causa
    /// exata de uma falha de abertura de banco cifrado não deveria ser
    /// diferenciável por quem só tem a chave errada.
    pub fn open(path: &Path, master_secret: &kdf::Key) -> Result<Self> {
        let conn = rusqlite::Connection::open(path).map_err(|_| Error::Store)?;

        let db_key = kdf::derive(kdf::context::DATABASE, master_secret.as_bytes());
        apply_key(&conn, &db_key)?;

        // `PRAGMA key` só falha de fato na primeira operação subsequente: até
        // aqui, uma chave errada ainda não foi rejeitada.
        schema::migrate(&conn).map_err(|_| Error::Store)?;

        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    /// Carrega a identidade local, criando uma na primeira execução.
    pub fn load_or_create_identity(&self) -> Result<LocalIdentity> {
        let conn = self.lock()?;
        identity::load_or_create(&conn)
    }

    /// Persiste um contato recém-pareado.
    pub fn insert_contact(&self, contact: &PublicIdentity, paired_at_unix_secs: i64) -> Result<()> {
        let conn = self.lock()?;
        contacts::insert(&conn, contact, paired_at_unix_secs)
    }

    /// Lista todos os contatos pareados.
    pub fn list_contacts(&self) -> Result<Vec<(PublicIdentity, i64)>> {
        let conn = self.lock()?;
        contacts::list(&conn)
    }

    /// Busca um contato pelo `device_id`.
    pub fn find_contact(&self, device_id: &[u8; 16]) -> Result<Option<(PublicIdentity, i64)>> {
        let conn = self.lock()?;
        contacts::find_by_device_id(&conn, device_id)
    }

    /// Persiste uma mensagem de saída como `Pending`, antes de qualquer
    /// tentativa de envio.
    pub fn insert_pending_message(
        &self,
        contact_device_id: &[u8; 16],
        packet_type: PacketType,
        body: &str,
        created_at_unix_secs: i64,
    ) -> Result<i64> {
        let conn = self.lock()?;
        messages::insert_pending(&conn, contact_device_id, packet_type, body, created_at_unix_secs)
    }

    /// Persiste uma mensagem recebida e já decifrada.
    pub fn insert_incoming_message(
        &self,
        contact_device_id: &[u8; 16],
        packet_type: PacketType,
        body: &str,
        received_at_unix_secs: i64,
    ) -> Result<i64> {
        let conn = self.lock()?;
        messages::insert_incoming(&conn, contact_device_id, packet_type, body, received_at_unix_secs)
    }

    /// Marca uma mensagem de saída como entregue ao transporte.
    pub fn mark_message_sent(&self, message_id: i64) -> Result<()> {
        let conn = self.lock()?;
        messages::mark_sent(&conn, message_id)
    }

    /// Todas as mensagens de um contato, mais antigas primeiro.
    pub fn list_messages(&self, contact_device_id: &[u8; 16]) -> Result<Vec<messages::StoredMessage>> {
        let conn = self.lock()?;
        messages::list_for_contact(&conn, contact_device_id)
    }

    /// Mensagens de saída ainda não entregues.
    pub fn list_pending_messages(
        &self,
        contact_device_id: &[u8; 16],
    ) -> Result<Vec<messages::StoredMessage>> {
        let conn = self.lock()?;
        messages::list_pending(&conn, contact_device_id)
    }

    /// Persiste `transfer_secret` (D15) e o manifesto de uma transferência
    /// nova — o suficiente para reabrir a mesma `Manifest`/`K_staging` se a
    /// conexão cair no meio (dentro da mesma execução do app; ver lacuna
    /// registrada em `store::transfers`).
    #[allow(clippy::too_many_arguments)]
    pub fn insert_file_transfer(
        &self,
        file_id: &[u8; 16],
        direction: transfers::Direction,
        contact_device_id: &[u8; 16],
        manifest_cbor: &[u8],
        transfer_secret: &[u8],
        created_at_unix_secs: i64,
        kind: crate::file::transfer::TransferKind,
    ) -> Result<()> {
        let conn = self.lock()?;
        transfers::insert(
            &conn,
            file_id,
            direction,
            contact_device_id,
            manifest_cbor,
            transfer_secret,
            created_at_unix_secs,
            kind,
        )
    }

    /// Busca uma transferência persistida pelo `file_id`.
    pub fn find_file_transfer(
        &self,
        file_id: &[u8; 16],
    ) -> Result<Option<transfers::StoredTransfer>> {
        let conn = self.lock()?;
        transfers::find(&conn, file_id)
    }

    /// Transferências de um contato numa direção — usado para listar
    /// ofertas de recebimento pendentes.
    pub fn list_file_transfers_for_contact(
        &self,
        contact_device_id: &[u8; 16],
        direction: transfers::Direction,
    ) -> Result<Vec<transfers::StoredTransfer>> {
        let conn = self.lock()?;
        transfers::list_for_contact(&conn, contact_device_id, direction)
    }

    /// Todo `file_id` com transferência persistida — usado para varrer
    /// `.staging` órfão sem apagar o de uma transferência ainda ativa.
    pub fn list_active_file_transfer_ids(&self) -> Result<Vec<[u8; 16]>> {
        let conn = self.lock()?;
        transfers::list_active_file_ids(&conn)
    }

    /// Remove o registro ao completar ou abortar — é isso que torna
    /// `K_staging` irrecuperável (D15).
    pub fn delete_file_transfer(&self, file_id: &[u8; 16]) -> Result<()> {
        let conn = self.lock()?;
        transfers::delete(&conn, file_id)
    }

    /// Trava a conexão. Um mutex envenenado (por pânico em outra chamada)
    /// vira `Error::Store` em vez de propagar o pânico — o banco continua
    /// utilizável, só essa operação falha.
    fn lock(&self) -> Result<std::sync::MutexGuard<'_, rusqlite::Connection>> {
        self.conn.lock().map_err(|_| Error::Store)
    }
}

impl core::fmt::Debug for Store {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("Store(<opaco>)")
    }
}

/// Aplica `PRAGMA key` na conexão. Isolado em função própria porque a chave
/// precisa ser formatada como blob hexadecimal (`x'...'`) para o SQLCipher não
/// tentar interpretar bytes arbitrários como texto.
fn apply_key(conn: &rusqlite::Connection, key: &kdf::Key) -> Result<()> {
    let hex: String = key.as_bytes().iter().map(|b| format!("{b:02x}")).collect();
    conn.pragma_update(None, "key", format!("x'{hex}'"))
        .map_err(|_| Error::Store)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::identity::LocalIdentity;

    fn temp_db_path(dir: &tempfile::TempDir) -> std::path::PathBuf {
        dir.path().join("viska.sqlite3")
    }

    fn key(seed: u8) -> kdf::Key {
        kdf::Key::from_bytes([seed; 32])
    }

    #[test]
    fn grava_e_rele_contato_devolve_bytes_identicos() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_db_path(&dir);
        let k = key(1);

        let contact = LocalIdentity::generate().unwrap().public();
        {
            let store = Store::open(&path, &k).unwrap();
            store.insert_contact(&contact, 1_700_000_000).unwrap();
        }

        let store = Store::open(&path, &k).unwrap();
        let (found, paired_at) = store.find_contact(&contact.device_id).unwrap().unwrap();
        assert_eq!(found, contact);
        assert_eq!(paired_at, 1_700_000_000);
    }

    #[test]
    fn abrir_com_chave_errada_falha() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_db_path(&dir);

        {
            let store = Store::open(&path, &key(1)).unwrap();
            store.load_or_create_identity().unwrap();
        }

        assert!(matches!(Store::open(&path, &key(2)), Err(Error::Store)));
    }

    #[test]
    fn identidade_sobrevive_a_reabertura() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_db_path(&dir);
        let k = key(3);

        let first = {
            let store = Store::open(&path, &k).unwrap();
            store.load_or_create_identity().unwrap()
        };

        let second = {
            let store = Store::open(&path, &k).unwrap();
            store.load_or_create_identity().unwrap()
        };

        assert_eq!(first.public(), second.public());
    }

    #[test]
    fn contato_inexistente_devolve_none() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_db_path(&dir);
        let store = Store::open(&path, &key(4)).unwrap();

        assert!(store.find_contact(&[0u8; 16]).unwrap().is_none());
    }

    #[test]
    fn lista_contatos_traz_todos_os_pareados() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_db_path(&dir);
        let store = Store::open(&path, &key(5)).unwrap();

        let a = LocalIdentity::generate().unwrap().public();
        let b = LocalIdentity::generate().unwrap().public();
        store.insert_contact(&a, 1).unwrap();
        store.insert_contact(&b, 2).unwrap();

        let listed = store.list_contacts().unwrap();
        assert_eq!(listed.len(), 2);
        assert!(listed.iter().any(|(c, _)| c == &a));
        assert!(listed.iter().any(|(c, _)| c == &b));
    }
}
