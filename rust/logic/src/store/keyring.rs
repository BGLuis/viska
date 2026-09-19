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

use crate::crypto::kdf::{Key, KEY_LEN};
use crate::{Error, Result};

const FILE_NAME: &str = "master.key";

/// Carrega o segredo mestre em `app_dir`, gerando um na primeira execução.
pub fn load_or_create_master_secret(app_dir: &Path) -> Result<Key> {
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
}
