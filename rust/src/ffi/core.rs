//! Struct opaca exposta ao Dart: um dispositivo aberto, com identidade e
//! banco já carregados.
//!
//! `LocalIdentity` e `Store` são campos privados — o codegen do
//! `flutter_rust_bridge` detecta que não são codificáveis e trata `Core`
//! como tipo opaco automaticamente: o Dart recebe um handle e chama métodos
//! nele, nunca lê os campos diretamente.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

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
    pub(super) identity: LocalIdentity,
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
            identity,
            store,
            sessions: Mutex::new(HashMap::new()),
            transfers: Mutex::new(HashMap::new()),
            staging_dir,
        })
    }

    /// Os 145 bytes do QR Code desta identidade.
    pub fn my_qr_payload(&self) -> Vec<u8> {
        pairing::encode_qr(&self.identity).to_vec()
    }

    /// Valida o payload lido pela câmera e persiste o contato.
    pub fn pair_from_qr(&self, payload: Vec<u8>) -> Result<ContactDto, FfiError> {
        let candidate = pairing::decode_qr(&payload, &self.identity.public())?;
        let paired_at = viska_proto::util::time::unix_seconds() as i64;
        self.store.insert_contact(&candidate, paired_at)?;

        Ok(ContactDto::from_identity(&candidate, paired_at, None))
    }

    /// Todos os contatos já pareados.
    pub fn list_contacts(&self) -> Result<Vec<ContactDto>, FfiError> {
        let contacts = self.store.list_contacts()?;
        Ok(contacts
            .into_iter()
            .map(|(identity, paired_at)| ContactDto::from_identity(&identity, paired_at, None))
            .collect())
    }

    /// Safety number entre esta identidade e um contato já pareado.
    pub fn safety_number(&self, contact_device_id: Vec<u8>) -> Result<SafetyNumberDto, FfiError> {
        let device_id: [u8; 16] = contact_device_id
            .try_into()
            .map_err(|_| FfiError::Internal)?;
        let (contact, _) = self
            .store
            .find_contact(&device_id)?
            .ok_or(FfiError::ContactNotFound)?;

        let number = SafetyNumber::compute(&self.identity.public(), &contact);
        Ok(SafetyNumberDto {
            digits: number.to_display_string(),
            words: number.to_words_display_string(),
        })
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
        Core::open(dir.path().to_str().unwrap().to_owned()).unwrap()
    }

    #[test]
    fn abrir_core_gera_identidade_na_primeira_execucao() {
        let dir = tempfile::tempdir().unwrap();

        let first = open_core(&dir).my_qr_payload();
        let second = open_core(&dir).my_qr_payload();

        assert_eq!(first, second);
    }

    #[test]
    fn pareamento_completo_entre_duas_cores() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let core_a = open_core(&dir_a);
        let core_b = open_core(&dir_b);

        let contact_of_a_seen_by_b = core_b.pair_from_qr(core_a.my_qr_payload()).unwrap();
        let contact_of_b_seen_by_a = core_a.pair_from_qr(core_b.my_qr_payload()).unwrap();

        assert_eq!(
            contact_of_a_seen_by_b.signing_pubkey,
            core_a.identity.public().signing
        );
        assert_eq!(
            contact_of_b_seen_by_a.signing_pubkey,
            core_b.identity.public().signing
        );
    }

    #[test]
    fn self_pairing_mapeia_para_variante_propria() {
        let dir = tempfile::tempdir().unwrap();
        let core = open_core(&dir);

        assert_eq!(
            core.pair_from_qr(core.my_qr_payload()),
            Err(FfiError::SelfPairing)
        );
    }

    #[test]
    fn qr_de_tamanho_errado_mapeia_para_qr_malformed() {
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

        assert_eq!(core_b.pair_from_qr(payload), Err(FfiError::QrMalformed));
    }

    #[test]
    fn contato_pareado_produz_o_mesmo_safety_number_dos_dois_lados() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let core_a = open_core(&dir_a);
        let core_b = open_core(&dir_b);

        core_b.pair_from_qr(core_a.my_qr_payload()).unwrap();
        core_a.pair_from_qr(core_b.my_qr_payload()).unwrap();

        let sn_a = core_a
            .safety_number(core_b.identity.public().device_id.to_vec())
            .unwrap();
        let sn_b = core_b
            .safety_number(core_a.identity.public().device_id.to_vec())
            .unwrap();

        assert_eq!(sn_a, sn_b);
    }
}
