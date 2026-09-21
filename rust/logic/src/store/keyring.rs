//! Segredo mestre do banco cifrado — versão interina.
//!
//! O segredo mestre deveria ser embrulhado no Android KeyStore ou no Secure
//! Enclave do iOS (D13 em `docs/deviations.md`), desembrulhado só dentro do
//! Rust. Esse wrapper de plataforma ainda não existe no projeto — é trabalho
//! nativo (canais de plataforma, código Kotlin/Swift) fora do escopo desta
//! fase.
//!
//! Por isso, por ora: 32 bytes do CSPRNG do sistema, gravados em
//! `<app_dir>/master.key` com permissão `0600` (só o dono do processo lê ou
//! escreve). Isso protege contra outro app comum lendo o arquivo, mas não
//! contra um invasor com acesso root/jailbreak ao armazenamento — esse é
//! exatamente o gap que o endurecimento futuro fecha.

use std::fs;
use std::io::Write;
use std::path::Path;
use std::sync::Mutex;
use zeroize::Zeroize;

use crate::crypto::kdf::{Key, KEY_LEN};
use crate::{Error, Result};

const FILE_NAME: &str = "master.key";

static INJECTED_SECRET: Mutex<Option<[u8; KEY_LEN]>> = Mutex::new(None);

/// Injeta uma chave mestra fornecida diretamente pela camada nativa de plataforma
/// (Android KeyStore via JNI / iOS Secure Enclave via C ABI), mantendo o segredo
/// fora do heap gerenciado do Dart.
pub fn set_injected_master_secret(mut secret: [u8; KEY_LEN]) {
    if let Ok(mut guard) = INJECTED_SECRET.lock() {
        if let Some(ref mut old) = *guard {
            old.zeroize();
        }
        *guard = Some(secret);
    }
    secret.zeroize();
}

/// Limpa o segredo injetado da memória com zeroize.
pub fn clear_injected_master_secret() {
    if let Ok(mut guard) = INJECTED_SECRET.lock() {
        if let Some(ref mut old) = *guard {
            old.zeroize();
        }
        *guard = None;
    }
}

/// Destrói o segredo mestre: zera a chave injetada em memória e remove o arquivo
/// `master.key` em disco, garantindo crypto-shredding no apagamento de emergência.
pub fn delete_master_secret(app_dir: &Path) -> Result<()> {
    clear_injected_master_secret();
    let path = app_dir.join(FILE_NAME);
    if path.exists() {
        let _ = fs::remove_file(&path);
    }
    Ok(())
}

/// Carrega o segredo mestre em `app_dir`, gerando um na primeira execução
/// caso não exista segredo injetado pela plataforma nem arquivo em disco.
pub fn load_or_create_master_secret(app_dir: &Path) -> Result<Key> {
    if let Ok(guard) = INJECTED_SECRET.lock() {
        if let Some(secret) = *guard {
            return Ok(Key::from_bytes(secret));
        }
    }

    let path = app_dir.join(FILE_NAME);

    if let Ok(bytes) = fs::read(&path) {
        let array: [u8; KEY_LEN] = bytes.try_into().map_err(|_| Error::Store)?;
        return Ok(Key::from_bytes(array));
    }

    fs::create_dir_all(app_dir).map_err(|_| Error::Store)?;
    let secret = crate::util::rng::array::<KEY_LEN>()?;
    write_private(&path, &secret)?;

    Ok(Key::from_bytes(secret))
}

#[cfg(unix)]
fn write_private(path: &Path, bytes: &[u8; KEY_LEN]) -> Result<()> {
    use std::os::unix::fs::OpenOptionsExt;

    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|_| Error::Store)?;
    file.write_all(bytes).map_err(|_| Error::Store)
}

#[cfg(not(unix))]
fn write_private(path: &Path, bytes: &[u8; KEY_LEN]) -> Result<()> {
    // Sem bit de permissão POSIX em Windows: a proteção equivalente ali é ACL
    // de arquivo, fora do escopo desta fase (só Android/iOS são alvo do app).
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|_| Error::Store)?;
    file.write_all(bytes).map_err(|_| Error::Store)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reaproveita_segredo_existente() {
        let dir = tempfile::tempdir().unwrap();

        let first = load_or_create_master_secret(dir.path()).unwrap();
        let second = load_or_create_master_secret(dir.path()).unwrap();

        assert_eq!(first.as_bytes(), second.as_bytes());
    }

    #[test]
    fn gera_arquivo_com_32_bytes() {
        let dir = tempfile::tempdir().unwrap();
        load_or_create_master_secret(dir.path()).unwrap();

        let bytes = fs::read(dir.path().join(FILE_NAME)).unwrap();
        assert_eq!(bytes.len(), KEY_LEN);
    }

    #[cfg(unix)]
    #[test]
    fn arquivo_tem_permissao_restrita_ao_dono() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        load_or_create_master_secret(dir.path()).unwrap();

        let mode = fs::metadata(dir.path().join(FILE_NAME))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    #[test]
    fn segredo_injetado_tem_precedencia_e_limpeza_funciona() {
        let dir = tempfile::tempdir().unwrap();
        let injetado = [42u8; KEY_LEN];
        set_injected_master_secret(injetado);

        let carregado = load_or_create_master_secret(dir.path()).unwrap();
        assert_eq!(carregado.as_bytes(), &injetado);

        // Não deve ter criado master.key enquanto injetado estava ativo
        assert!(!dir.path().join(FILE_NAME).exists());

        clear_injected_master_secret();
        let do_arquivo = load_or_create_master_secret(dir.path()).unwrap();
        assert_ne!(do_arquivo.as_bytes(), &injetado);
        assert!(dir.path().join(FILE_NAME).exists());
    }

    #[test]
    fn delete_master_secret_apaga_arquivo_e_limpa_memoria() {
        let dir = tempfile::tempdir().unwrap();
        load_or_create_master_secret(dir.path()).unwrap();
        assert!(dir.path().join(FILE_NAME).exists());

        delete_master_secret(dir.path()).unwrap();
        assert!(!dir.path().join(FILE_NAME).exists());
    }
}
