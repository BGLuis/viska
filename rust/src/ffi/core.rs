//! Struct opaca exposta ao Dart: um dispositivo aberto, com identidade e
//! banco já carregados.
//!
//! `LocalIdentity` e `Store` são campos privados — o codegen do
//! `flutter_rust_bridge` detecta que não são codificáveis e trata `Core`
//! como tipo opaco automaticamente: o Dart recebe um handle e chama métodos
//! nele, nunca lê os campos diretamente.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, RwLock};
use zeroize::Zeroize;

use crate::ffi::error::FfiError;
use crate::ffi::transfer::TransferHandle;
use crate::ffi::types::{ContactDto, SafetyNumberDto};
use viska_proto::crypto::identity::LocalIdentity;
use viska_proto::crypto::pairing;
use viska_proto::crypto::safety_number::SafetyNumber;
use viska_proto::session::Session;
use viska_proto::store::{keyring, Store};

const DB_FILE_NAME: &str = "viska.sqlite3";
const STAGING_DIR_NAME: &str = "staging";

pub struct Core {
    // `pub(super)`, não privado: `ffi::session` (mesmo módulo pai `ffi`)
    // implementa métodos novos sobre `Core` num arquivo separado e precisa
    // desses três campos. Continuam inacessíveis de fora de `ffi` — a regra
    // "nenhum segredo cruza para o Dart" não depende de os campos serem
    // privados ao arquivo, só de não serem `pub` ao ponto de o codegen do
    // `flutter_rust_bridge` tentar codificá-los (que ele não tenta, porque
    // nenhum dos três tipos é serializável pela ponte).
    pub(super) identity: RwLock<LocalIdentity>,
    pub(super) store: Store,
    /// Sessões de mensagens em memória, uma por contato — nunca persistidas:
    /// reabrir o app começa sem sessão nenhuma, exatamente como dois
    /// aparelhos que nunca trocaram um handshake (`ffi/session.rs`).
    ///
    /// `Mutex`, não `RefCell`: mesmo motivo de `Store::conn` — os métodos do
    /// FFI são despachados pelo `flutter_rust_bridge` em threads do próprio
    /// pool, potencialmente diferentes a cada chamada.
    pub(super) sessions: Mutex<HashMap<[u8; 16], Session>>,
    /// Transferências de arquivo em andamento, uma por `file_id` — nunca
    /// persistidas em si (`store::transfers` guarda só o necessário para
    /// retomar dentro da mesma execução, ver `file::transfer`).
    pub(super) transfers: Mutex<HashMap<[u8; 16], TransferHandle>>,
    /// `<app_dir>/staging` — onde `.staging` de arquivos em recebimento
    /// ficam (§7.5). Não é segredo, só um caminho de diretório.
    pub(super) staging_dir: PathBuf,
    /// Diretório de dados do app para reabertura de banco e apagamento.
    pub(super) app_dir: PathBuf,
}

impl Core {
    /// Abre (criando na primeira execução) a identidade e o banco cifrado em
    /// `app_dir` — o diretório de dados privados do app, não um segredo.
    pub fn open(app_dir: String) -> Result<Core, FfiError> {
        let dir = Path::new(&app_dir);
        let master_secret = keyring::load_or_create_master_secret(dir)?;
        let store = Store::open(&dir.join(DB_FILE_NAME), &master_secret)?;
        let identity = store.load_or_create_identity()?;

        let staging_dir = dir.join(STAGING_DIR_NAME);
        // Varre `.staging` órfão de uma execução anterior (crash, força
        // bruta do processo) — nunca apaga o de uma transferência que o
        // banco ainda considera ativa (armadilha da Fase 4: "`.staging`
        // sobrevive a crash e vaza espaço em disco").
        let active_ids: std::collections::HashSet<[u8; 16]> =
            store.list_active_file_transfer_ids()?.into_iter().collect();
        viska_proto::file::staging::sweep_orphaned(&staging_dir, &active_ids)?;

        Ok(Core {
            identity: RwLock::new(identity),
            store,
            sessions: Mutex::new(HashMap::new()),
            transfers: Mutex::new(HashMap::new()),
            staging_dir,
            app_dir: dir.to_path_buf(),
        })
    }

    /// Tranca a Core (D13 / F1): limpa e zera todas as sessões do ratchet em
    /// memória, aborta transferências ativas, fecha a conexão do SQLCipher e
    /// limpa a chave mestra nativa injetada.
    pub fn lock(&self) -> Result<(), FfiError> {
        self.sessions.lock().map_err(|_| FfiError::Internal)?.clear();
        self.transfers.lock().map_err(|_| FfiError::Internal)?.clear();
        self.store.close()?;
        keyring::clear_injected_master_secret();
        Ok(())
    }

    /// Destranca a Core após autenticação bem-sucedida: recarrega a chave
    /// mestre e reabre a conexão do SQLCipher.
    pub fn unlock(&self) -> Result<(), FfiError> {
        let master_secret = keyring::load_or_create_master_secret(&self.app_dir)?;
        self.store
            .reopen(&self.app_dir.join(DB_FILE_NAME), &master_secret)?;
        Ok(())
    }

    /// Informa se a Core está trancada.
    pub fn is_locked(&self) -> bool {
        self.store.is_closed().unwrap_or(true)
    }

    /// Valida que a Core não está trancada antes de operações de negócio.
    pub(super) fn ensure_not_locked(&self) -> Result<(), FfiError> {
        if self.is_locked() {
            return Err(FfiError::Locked);
        }
        Ok(())
    }

    /// Apagamento de emergência (D13 / F2): crypto-shredding da chave mestra,
    /// remoção física dos arquivos do banco SQLite e limpeza do diretório staging.
    pub fn emergency_erase(&self) -> Result<(), FfiError> {
        let _ = self.lock();
        keyring::delete_master_secret(&self.app_dir)?;
        let db_path = self.app_dir.join(DB_FILE_NAME);
        let _ = std::fs::remove_file(&db_path);
        let _ = std::fs::remove_file(self.app_dir.join("viska.sqlite3-wal"));
        let _ = std::fs::remove_file(self.app_dir.join("viska.sqlite3-shm"));
        let _ = std::fs::remove_dir_all(&self.staging_dir);
        let _ = std::fs::create_dir_all(&self.staging_dir);
        Ok(())
    }

    /// Define o tempo de expiração (TTL em segundos) para mensagens efêmeras com o contato.
    pub fn set_ephemeral_ttl(
        &self,
        contact_device_id: Vec<u8>,
        ttl_secs: i64,
    ) -> Result<(), FfiError> {
        self.ensure_not_locked()?;
        let device_id: [u8; 16] = contact_device_id
            .try_into()
            .map_err(|_| FfiError::Internal)?;
        self.store.set_ephemeral_ttl(&device_id, ttl_secs)?;
        Ok(())
    }

    /// Consulta o TTL efêmero configurado para o contato.
    pub fn get_ephemeral_ttl(&self, contact_device_id: Vec<u8>) -> Result<i64, FfiError> {
        self.ensure_not_locked()?;
        let device_id: [u8; 16] = contact_device_id
            .try_into()
            .map_err(|_| FfiError::Internal)?;
        Ok(self.store.get_ephemeral_ttl(&device_id)?)
    }

    /// Marca uma mensagem como lida, disparando o temporizador de expiração.
    pub fn mark_message_read(&self, message_id: i64) -> Result<(), FfiError> {
        self.ensure_not_locked()?;
        let now = viska_proto::util::time::unix_seconds() as i64;
        self.store.mark_message_read(message_id, now)?;
        Ok(())
    }

    /// Varre e destrói chaves de mensagens efêmeras expiradas.
    pub fn sweep_expired_messages(&self) -> Result<u32, FfiError> {
        self.ensure_not_locked()?;
        let now = viska_proto::util::time::unix_seconds() as i64;
        let count = self.store.sweep_expired_ephemeral_messages(now)?;
        Ok(count as u32)
    }

    /// Os 145 bytes do QR Code desta identidade.
    pub fn my_qr_payload(&self) -> Vec<u8> {
        let id = self.identity.read().unwrap();
        pairing::encode_qr(&id).to_vec()
    }

    /// Valida o payload lido pela câmera ou recebido por proximidade e persiste o contato.
    pub fn pair_from_qr(&self, payload: Vec<u8>, nickname: Option<String>) -> Result<ContactDto, FfiError> {
        self.ensure_not_locked()?;
        let id = self.identity.read().map_err(|_| FfiError::Internal)?;
        let candidate = pairing::decode_qr(&payload, &id.public())?;
        let paired_at = viska_proto::util::time::unix_seconds() as i64;
        self.store.insert_contact(&candidate, paired_at, nickname.as_deref())?;

        Ok(ContactDto::from_identity(&candidate, paired_at, nickname, false))
    }

    /// Todos os contatos já pareados.
    pub fn list_contacts(&self) -> Result<Vec<ContactDto>, FfiError> {
        self.ensure_not_locked()?;
        let contacts = self.store.list_contacts()?;
        Ok(contacts
            .into_iter()
            .map(|(identity, paired_at, nickname, is_verified)| ContactDto::from_identity(&identity, paired_at, nickname, is_verified))
            .collect())
    }

    /// Safety number entre esta identidade e um contato já pareado.
    pub fn safety_number(&self, contact_device_id: Vec<u8>) -> Result<SafetyNumberDto, FfiError> {
        self.ensure_not_locked()?;
        let device_id: [u8; 16] = contact_device_id
            .try_into()
            .map_err(|_| FfiError::Internal)?;
        let (contact, _, _, _) = self
            .store
            .find_contact(&device_id)?
            .ok_or(FfiError::ContactNotFound)?;

        let id = self.identity.read().map_err(|_| FfiError::Internal)?;
        let number = SafetyNumber::compute(&id.public(), &contact);
        Ok(SafetyNumberDto {
            digits: number.to_display_string(),
            words: number.to_words_display_string(),
        })
    }

    /// Define se o contato foi verificado (true/false) após conferência do Safety Number.
    pub fn verify_contact(&self, contact_device_id: Vec<u8>, verified: bool) -> Result<(), FfiError> {
        self.ensure_not_locked()?;
        let device_id: [u8; 16] = contact_device_id
            .try_into()
            .map_err(|_| FfiError::Internal)?;
        let current_sn = if verified {
            let sn = self.safety_number(device_id.to_vec())?;
            Some(sn.digits)
        } else {
            None
        };

        self.store.set_contact_verified(&device_id, verified, current_sn.as_deref())?;
        Ok(())
    }

    /// Retorna se o contato está com status verificado.
    pub fn is_contact_verified(&self, contact_device_id: Vec<u8>) -> Result<bool, FfiError> {
        self.ensure_not_locked()?;
        let device_id: [u8; 16] = contact_device_id
            .try_into()
            .map_err(|_| FfiError::Internal)?;

        let (verified, _) = self.store.get_contact_verified_status(&device_id)?;
        Ok(verified)
    }

    /// Verifica se as chaves criptográficas do contato mudaram desde a última verificação.
    pub fn is_key_changed(&self, contact_device_id: Vec<u8>) -> Result<bool, FfiError> {
        self.ensure_not_locked()?;
        let device_id: [u8; 16] = contact_device_id
            .try_into()
            .map_err(|_| FfiError::Internal)?;

        let (_, saved_sn) = self.store.get_contact_verified_status(&device_id)?;
        if let Some(saved) = saved_sn {
            let current_sn = self.safety_number(device_id.to_vec())?;
            let current_digits_norm = current_sn.digits.replace(' ', "");
            let saved_digits_norm = saved.replace(' ', "");
            if current_digits_norm != saved_digits_norm {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// Apelido desta identidade local, se configurado.
    pub fn my_nickname(&self) -> Result<Option<String>, FfiError> {
        self.ensure_not_locked()?;
        Ok(self.store.get_config("my_nickname")?)
    }

    /// Define ou altera o apelido desta identidade local.
    pub fn set_my_nickname(&self, nickname: String) -> Result<(), FfiError> {
        self.ensure_not_locked()?;
        self.store.set_config("my_nickname", &nickname)?;
        Ok(())
    }

    /// Consulta chave de configuração arbitrária.
    pub fn get_config(&self, key: String) -> Result<Option<String>, FfiError> {
        self.ensure_not_locked()?;
        Ok(self.store.get_config(&key)?)
    }

    /// Define chave de configuração arbitrária.
    pub fn set_config(&self, key: String, value: String) -> Result<(), FfiError> {
        self.ensure_not_locked()?;
        self.store.set_config(&key, &value)?;
        Ok(())
    }

    /// Altera o apelido local de um contato já pareado.
    pub fn set_contact_nickname(&self, contact_device_id: Vec<u8>, nickname: String) -> Result<(), FfiError> {
        self.ensure_not_locked()?;
        let device_id: [u8; 16] = contact_device_id
            .try_into()
            .map_err(|_| FfiError::Internal)?;
        self.store.update_contact_nickname(&device_id, &nickname)?;
        Ok(())
    }

    /// Código numérico de 6 dígitos (SAS) para confirmação presencial de segurança
    /// entre aparelhos próximos em pareamento.
    pub fn compute_sas_code(&self, peer_payload: Vec<u8>) -> Result<String, FfiError> {
        self.ensure_not_locked()?;
        let id = self.identity.read().map_err(|_| FfiError::Internal)?;
        let candidate = pairing::decode_qr(&peer_payload, &id.public())?;
        let number = SafetyNumber::compute(&id.public(), &candidate);
        let digits_raw = number.to_display_string().replace(' ', "");
        let sas = if digits_raw.len() >= 6 {
            digits_raw[0..6].to_string()
        } else {
            format!("{:06}", 0)
        };
        Ok(sas)
    }

    /// Adiciona uma reação emoji a uma mensagem persistida (Fase 9).
    pub fn add_reaction(
        &self,
        contact_device_id: [u8; 16],
        target_msg_id: i64,
        emoji: String,
    ) -> Result<(), FfiError> {
        self.ensure_not_locked()?;
        let now = viska_proto::util::time::unix_seconds() as i64;
        self.store.add_reaction(target_msg_id, &contact_device_id, &emoji, now)?;
        Ok(())
    }

    /// Exporta backup cifrado com frase mnemônica de 24 palavras (BIP-39).
    pub fn export_encrypted_backup(&self, dest_path: String) -> Result<String, FfiError> {
        self.ensure_not_locked()?;
        let _ = self.store.checkpoint();
        let db_path = self.app_dir.join(DB_FILE_NAME);
        let db_bytes = std::fs::read(&db_path).map_err(|_| FfiError::Internal)?;
        let master_secret = keyring::load_or_create_master_secret(&self.app_dir)?;

        let mut bundle = Vec::with_capacity(32 + db_bytes.len());
        bundle.extend_from_slice(master_secret.as_bytes());
        bundle.extend_from_slice(&db_bytes);

        let mnemonic = viska_proto::backup::export_backup_to_file(&bundle, Path::new(&dest_path))
            .map_err(|_| FfiError::Internal)?;
        bundle.zeroize();
        Ok(mnemonic)
    }

    /// Restaura backup cifrado a partir de frase mnemônica de 24 palavras e arquivo .viskasafe.
    pub fn restore_encrypted_backup(&self, src_path: String, mnemonic: String) -> Result<(), FfiError> {
        self.ensure_not_locked()?;
        let mut bundle = viska_proto::backup::restore_backup_from_file(Path::new(&src_path), &mnemonic)
            .map_err(|_| FfiError::FileCorrupted)?;
        if bundle.len() < 32 {
            return Err(FfiError::FileCorrupted);
        }
        let mut restored_master_secret = [0u8; 32];
        restored_master_secret.copy_from_slice(&bundle[..32]);
        let db_bytes = &bundle[32..];

        let _ = self.lock();

        let master_key_path = self.app_dir.join("master.key");
        let _ = std::fs::remove_file(&master_key_path);
        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&master_key_path)
                .map_err(|_| FfiError::Internal)?;
            file.write_all(&restored_master_secret).map_err(|_| FfiError::Internal)?;
        }
        #[cfg(not(unix))]
        {
            std::fs::write(&master_key_path, &restored_master_secret).map_err(|_| FfiError::Internal)?;
        }
        restored_master_secret.zeroize();

        let db_path = self.app_dir.join(DB_FILE_NAME);
        let write_res = std::fs::write(&db_path, db_bytes);
        let _ = std::fs::remove_file(self.app_dir.join("viska.sqlite3-wal"));
        let _ = std::fs::remove_file(self.app_dir.join("viska.sqlite3-shm"));
        bundle.zeroize();
        write_res.map_err(|_| FfiError::Internal)?;

        self.unlock()?;
        if let Ok(new_id) = self.store.load_or_create_identity() {
            let mut id_guard = self.identity.write().map_err(|_| FfiError::Internal)?;
            *id_guard = new_id;
        }
        self.sessions.lock().map_err(|_| FfiError::Internal)?.clear();
        self.transfers.lock().map_err(|_| FfiError::Internal)?.clear();
        Ok(())
    }

    /// Configura PIN de coação e modo de ação para o cofre falso (Fase 9).
    pub fn configure_duress_pin(&self, duress_pin: String, action_mode: u8) -> Result<(), FfiError> {
        self.ensure_not_locked()?;
        self.store.configure_duress_pin(&duress_pin, action_mode)?;
        Ok(())
    }

}

impl std::fmt::Debug for Core {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Core(<opaco>)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open_core(dir: &tempfile::TempDir) -> Core {
        Core::open(dir.path().to_str().unwrap().to_string()).unwrap()
    }

    #[test]
    fn open_core_generates_identity_on_first_run() {
        let dir = tempfile::tempdir().unwrap();
        let core = open_core(&dir);
        let id = core.identity.read().unwrap().public();

        assert_eq!(id.device_id.len(), 16);
        assert_eq!(id.signing.len(), 32);
    }

    #[test]
    fn full_pairing_between_two_cores() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let core_a = open_core(&dir_a);
        let core_b = open_core(&dir_b);

        let contact_of_a_seen_by_b = core_b.pair_from_qr(core_a.my_qr_payload(), Some("Alice".to_string())).unwrap();
        let contact_of_b_seen_by_a = core_a.pair_from_qr(core_b.my_qr_payload(), Some("Bob".to_string())).unwrap();

        assert_eq!(
            contact_of_a_seen_by_b.signing_pubkey,
            core_a.identity.read().unwrap().public().signing
        );
        assert_eq!(contact_of_a_seen_by_b.nickname.as_deref(), Some("Alice"));
        assert_eq!(
            contact_of_b_seen_by_a.signing_pubkey,
            core_b.identity.read().unwrap().public().signing
        );
        assert_eq!(contact_of_b_seen_by_a.nickname.as_deref(), Some("Bob"));

        // Altera apelido de contato
        core_a.set_contact_nickname(core_b.my_device_id(), "Bob Amigo".to_string()).unwrap();
        let contacts_a = core_a.list_contacts().unwrap();
        assert_eq!(contacts_a[0].nickname.as_deref(), Some("Bob Amigo"));

        // Configuração de apelido próprio
        assert_eq!(core_a.my_nickname().unwrap(), None);
        core_a.set_my_nickname("Alice Santos".to_string()).unwrap();
        assert_eq!(core_a.my_nickname().unwrap().as_deref(), Some("Alice Santos"));

        // SAS de 6 dígitos calculado é idêntico em A e B
        let sas_a = core_a.compute_sas_code(core_b.my_qr_payload()).unwrap();
        let sas_b = core_b.compute_sas_code(core_a.my_qr_payload()).unwrap();
        assert_eq!(sas_a.len(), 6);
        assert_eq!(sas_a, sas_b);
    }

    #[test]
    fn self_pairing_maps_to_dedicated_variant() {
        let dir = tempfile::tempdir().unwrap();
        let core = open_core(&dir);

        assert_eq!(
            core.pair_from_qr(core.my_qr_payload(), None),
            Err(FfiError::SelfPairing)
        );
    }

    #[test]
    fn wrong_sized_qr_maps_to_qr_malformed() {
        // A construção de um QR forjado com assinatura válida (chave DH de
        // ordem baixa, resignada) exige `LocalIdentity::sign`, que é
        // `pub(crate)` dentro de `viska_proto` — de propósito, para que nada
        // fora daquele crate possa assinar (ver D1). Esse cenário específico
        // já está coberto, com a chave a mais, em
        // `viska_proto::crypto::pairing::tests::rejeita_chave_x25519_de_ordem_baixa`;
        // o que cabe testar aqui, na fronteira FFI, é só o mapeamento de erro
        // (`ffi::error::tests`) e a integração com o banco, não a criptografia.
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let core_a = open_core(&dir_a);
        let core_b = open_core(&dir_b);

        let mut payload = core_a.my_qr_payload();
        payload.pop();

        assert_eq!(core_b.pair_from_qr(payload, None), Err(FfiError::QrMalformed));
    }

    #[test]
    fn paired_contact_produces_same_safety_number_on_both_sides() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let core_a = open_core(&dir_a);
        let core_b = open_core(&dir_b);

        core_b.pair_from_qr(core_a.my_qr_payload(), None).unwrap();
        core_a.pair_from_qr(core_b.my_qr_payload(), None).unwrap();

        let sn_a = core_a
            .safety_number(core_b.identity.read().unwrap().public().device_id.to_vec())
            .unwrap();
        let sn_b = core_b
            .safety_number(core_a.identity.read().unwrap().public().device_id.to_vec())
            .unwrap();

        assert_eq!(sn_a, sn_b);
    }

    #[test]
    fn locking_and_unlocking_core_rejects_calls_while_locked() {
        let dir = tempfile::tempdir().unwrap();
        let core = open_core(&dir);

        assert!(!core.is_locked());
        core.lock().unwrap();
        assert!(core.is_locked());

        // Operações no cofre devem falhar imediatamente com FfiError::Locked
        assert_eq!(core.list_contacts(), Err(FfiError::Locked));
        assert_eq!(core.pair_from_qr(vec![0; 145], None), Err(FfiError::Locked));

        // Desbloqueio reabre a conexão do cofre
        core.unlock().unwrap();
        assert!(!core.is_locked());
        assert_eq!(core.list_contacts().unwrap(), vec![]);
    }

    #[test]
    fn configuration_and_query_of_ephemeral_ttl_per_contact() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let core_a = open_core(&dir_a);
        let core_b = open_core(&dir_b);

        let contact = core_a.pair_from_qr(core_b.my_qr_payload(), None).unwrap();

        // Inicialmente nenhum TTL configurado (0 = desativado)
        assert_eq!(
            core_a.get_ephemeral_ttl(contact.device_id.clone()).unwrap(),
            0
        );

        // Define 1 hora (3600 segundos)
        core_a
            .set_ephemeral_ttl(contact.device_id.clone(), 3600)
            .unwrap();
        assert_eq!(
            core_a.get_ephemeral_ttl(contact.device_id.clone()).unwrap(),
            3600
        );

        // Desativa TTL (0)
        core_a
            .set_ephemeral_ttl(contact.device_id.clone(), 0)
            .unwrap();
        assert_eq!(
            core_a.get_ephemeral_ttl(contact.device_id).unwrap(),
            0
        );
    }

    #[test]
    fn emergency_erase_destroys_database_and_locks_core() {
        let dir = tempfile::tempdir().unwrap();
        let core = open_core(&dir);

        let db_path = dir.path().join("viska.sqlite3");
        assert!(db_path.exists());

        core.emergency_erase().unwrap();

        assert!(core.is_locked());
        assert!(!db_path.exists());
        assert_eq!(core.list_contacts(), Err(FfiError::Locked));
    }

    #[test]
    fn backup_export_and_restore_roundtrip() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let core_a = open_core(&dir_a);
        let core_b = open_core(&dir_b);

        core_a.set_my_nickname("Alice".to_string()).unwrap();
        let contact = core_a.pair_from_qr(core_b.my_qr_payload(), Some("Bob".to_string())).unwrap();
        core_a.set_ephemeral_ttl(contact.device_id.clone(), 300).unwrap();

        // Exporta backup
        let backup_path = dir_a.path().join("backup.viskasafe");
        let mnemonic = core_a
            .export_encrypted_backup(backup_path.to_str().unwrap().to_string())
            .unwrap();
        let words: Vec<&str> = mnemonic.split_whitespace().collect();
        assert_eq!(words.len(), 24);
        assert!(backup_path.exists());

        // Restauração com mnemonic errado falha
        let dir_c = tempfile::tempdir().unwrap();
        let core_c = open_core(&dir_c);
        let mut wrong_words = words.clone();
        wrong_words[0] = if wrong_words[0] == "casa" { "mesa" } else { "casa" };
        assert_eq!(
            core_c.restore_encrypted_backup(
                backup_path.to_str().unwrap().to_string(),
                wrong_words.join(" "),
            ),
            Err(FfiError::FileCorrupted)
        );

        // Restauração com bytes adulterados falha
        let mut tampered_bytes = std::fs::read(&backup_path).unwrap();
        let last_idx = tampered_bytes.len() - 1;
        tampered_bytes[last_idx] ^= 0x55;
        let tampered_path = dir_a.path().join("tampered.viskasafe");
        std::fs::write(&tampered_path, &tampered_bytes).unwrap();
        assert_eq!(
            core_c.restore_encrypted_backup(
                tampered_path.to_str().unwrap().to_string(),
                mnemonic.clone(),
            ),
            Err(FfiError::FileCorrupted)
        );

        // Restauração correta em core_c
        core_c
            .restore_encrypted_backup(backup_path.to_str().unwrap().to_string(), mnemonic)
            .unwrap();

        assert_eq!(core_c.my_nickname().unwrap().as_deref(), Some("Alice"));
        assert_eq!(core_c.my_device_id(), core_a.my_device_id());
        let contacts_c = core_c.list_contacts().unwrap();
        assert_eq!(contacts_c.len(), 1);
        assert_eq!(contacts_c[0].nickname.as_deref(), Some("Bob"));
        assert_eq!(core_c.get_ephemeral_ttl(contacts_c[0].device_id.clone()).unwrap(), 300);
    }

    #[test]
    fn contact_verification_and_key_change_detection() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let core_a = open_core(&dir_a);
        let core_b = open_core(&dir_b);

        let contact = core_a.pair_from_qr(core_b.my_qr_payload(), Some("Bob".to_string())).unwrap();
        let dev_id: [u8; 16] = contact.device_id.clone().try_into().unwrap();
        assert!(!contact.is_verified);
        assert!(!core_a.is_contact_verified(contact.device_id.clone()).unwrap());
        assert!(!core_a.is_key_changed(contact.device_id.clone()).unwrap());

        // Verifica o contato
        core_a.verify_contact(dev_id.to_vec(), true).unwrap();
        assert!(core_a.is_contact_verified(contact.device_id.clone()).unwrap());
        assert!(!core_a.is_key_changed(contact.device_id.clone()).unwrap());

        let list = core_a.list_contacts().unwrap();
        assert!(list[0].is_verified);

        // Se Bob regenerar identidade e re-parear (simulando chave alterada / MITM)
        let dir_b_fake = tempfile::tempdir().unwrap();
        let core_b_fake = open_core(&dir_b_fake);
        let fake_public = core_b_fake.identity.read().unwrap().public();
        let fake_contact_with_same_id = viska_proto::crypto::identity::PublicIdentity {
            device_id: dev_id,
            signing: fake_public.signing,
            dh: fake_public.dh,
        };
        core_a.store.insert_contact(&fake_contact_with_same_id, 2000, Some("Bob")).unwrap();

        // Agora is_verified foi revogado para false e is_key_changed deve detectar true!
        assert!(!core_a.is_contact_verified(contact.device_id.clone()).unwrap());
        assert!(core_a.is_key_changed(contact.device_id.clone()).unwrap());

        // Re-verificando o contato atualiza o Safety Number gravado e limpa o alerta
        core_a.verify_contact(dev_id.to_vec(), true).unwrap();
        assert!(core_a.is_contact_verified(contact.device_id.clone()).unwrap());
        assert!(!core_a.is_key_changed(contact.device_id.clone()).unwrap());
    }

    #[test]
    fn reactions_and_duress_pin() {
        let dir = tempfile::tempdir().unwrap();
        let core = open_core(&dir);

        // Testa configuração de duress PIN
        core.configure_duress_pin("9999".to_string(), 1).unwrap();
        let (is_enabled, duress_pin, action_mode) = core.store.get_decoy_vault_config().unwrap().unwrap();
        assert!(is_enabled);
        assert_eq!(duress_pin.as_deref(), Some("9999"));
        assert_eq!(action_mode, 1);

        // Insere contato e mensagem para testar reação
        let dir_b = tempfile::tempdir().unwrap();
        let core_b = open_core(&dir_b);
        let contact = core.pair_from_qr(core_b.my_qr_payload(), Some("Bob".to_string())).unwrap();
        let dev_id: [u8; 16] = contact.device_id.try_into().unwrap();

        let msg_id = core.store.insert_pending_message(
            &dev_id,
            viska_proto::wire::packet_type::PacketType::MsgText,
            "Olá!",
            1000,
        ).unwrap();

        // Adiciona reação via Core
        core.add_reaction(dev_id, msg_id, "❤️".to_string()).unwrap();
        let reactions = core.store.get_reactions(msg_id).unwrap();
        assert_eq!(reactions, vec!["❤️".to_string()]);
    }
}
