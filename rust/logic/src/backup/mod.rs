//! Exportação e restauração de backup cifrado com mnemônico BIP-39.
//!
//! O backup empacota os dados em um contêiner autenticado com XChaCha20-Poly1305,
//! identificado pelo cabeçalho `b"VISKASAFE1"`. A chave de cifragem é derivada
//! via `BLAKE3::derive_key("viska-backup-v1", &entropy_bytes)` a partir de
//! 256 bits de entropia CSPRNG (`crate::util::rng`), codificados em uma frase
//! semente canônica de 24 palavras (BIP-39).

use std::fs;
use std::path::Path;
use sha2::{Digest, Sha256};
use zeroize::Zeroize;

use crate::crypto::aead;
use crate::crypto::kdf::Key;
use crate::{Error, Result};

/// Cabeçalho mágico identificador do arquivo de backup do Viska.
pub const BACKUP_HEADER_MAGIC: &[u8; 10] = b"VISKASAFE1";

/// Contexto KDF BLAKE3 para derivação da chave de backup.
pub const BACKUP_KDF_CONTEXT: &str = "viska-backup-v1";

/// Quantidade de palavras no mnemônico BIP-39 (256 bits de entropia + 8 bits de checksum).
pub const MNEMONIC_WORD_COUNT: usize = 24;

const WORDLIST_PT_BR_STR: &str = include_str!("../crypto/wordlist_pt_br.txt");
const WORDLIST_EN_STR: &str = include_str!("wordlist_en.txt");

fn wordlist_pt_br() -> Vec<&'static str> {
    WORDLIST_PT_BR_STR.lines().collect()
}

fn wordlist_en() -> Vec<&'static str> {
    WORDLIST_EN_STR.lines().collect()
}

/// Converte 32 bytes de entropia em uma frase mnemônica de 24 palavras BIP-39 (PT-BR).
pub fn entropy_to_mnemonic(entropy: &[u8; 32]) -> String {
    let words = wordlist_pt_br();
    debug_assert_eq!(words.len(), 2048);

    let checksum = Sha256::digest(entropy)[0];
    let mut data = [0u8; 33];
    data[..32].copy_from_slice(entropy);
    data[32] = checksum;

    let mut result = Vec::with_capacity(MNEMONIC_WORD_COUNT);
    for i in 0..MNEMONIC_WORD_COUNT {
        let bit_offset = i * 11;
        let byte_offset = bit_offset / 8;
        let bit_in_byte = bit_offset % 8;
        let b0 = data[byte_offset] as u32;
        let b1 = data[byte_offset + 1] as u32;
        let b2 = if byte_offset + 2 < 33 {
            data[byte_offset + 2] as u32
        } else {
            0
        };
        let chunk = (b0 << 16) | (b1 << 8) | b2;
        let shift = 24 - 11 - bit_in_byte;
        let word_idx = ((chunk >> shift) & 0x7FF) as usize;
        result.push(words[word_idx]);
    }
    result.join(" ")
}

/// Valida e converte uma frase mnemônica de 24 palavras (PT-BR ou EN) de volta em 32 bytes de entropia.
pub fn mnemonic_to_entropy(mnemonic: &str) -> Result<[u8; 32]> {
    let word_list: Vec<&str> = mnemonic.split_whitespace().collect();
    if word_list.len() != MNEMONIC_WORD_COUNT {
        return Err(Error::Malformed("mnemônico deve ter exatamente 24 palavras"));
    }

    let pt = wordlist_pt_br();
    let is_pt = word_list.iter().all(|w| pt.iter().any(|p| p == w));

    let indices = if is_pt {
        let mut idxs = [0u16; MNEMONIC_WORD_COUNT];
        for (i, &w) in word_list.iter().enumerate() {
            idxs[i] = pt.iter().position(|&p| p == w).unwrap() as u16;
        }
        idxs
    } else {
        let en = wordlist_en();
        let is_en = word_list.iter().all(|w| en.iter().any(|e| e == w));
        if is_en {
            let mut idxs = [0u16; MNEMONIC_WORD_COUNT];
            for (i, &w) in word_list.iter().enumerate() {
                idxs[i] = en.iter().position(|&e| e == w).unwrap() as u16;
            }
            idxs
        } else {
            return Err(Error::Malformed(
                "palavras do mnemônico não pertencem a uma lista canônica BIP-39 suportada",
            ));
        }
    };

    let mut data = [0u8; 33];
    for (i, &idx) in indices.iter().enumerate() {
        let bit_offset = i * 11;
        for bit in 0..11 {
            let bit_val = ((idx >> (10 - bit)) & 1) as u8;
            let target_bit = bit_offset + bit;
            data[target_bit / 8] |= bit_val << (7 - (target_bit % 8));
        }
    }

    let mut entropy = [0u8; 32];
    entropy.copy_from_slice(&data[..32]);
    let expected_checksum = Sha256::digest(entropy)[0];
    if data[32] != expected_checksum {
        entropy.zeroize();
        return Err(Error::Malformed("checksum do mnemônico inválido"));
    }

    Ok(entropy)
}

/// Deriva uma chave simétrica de 32 bytes para o backup a partir dos bytes de entropia.
pub fn derive_backup_key(entropy: &[u8; 32]) -> Key {
    let key_bytes = blake3::derive_key(BACKUP_KDF_CONTEXT, entropy);
    Key::from_bytes(key_bytes)
}

/// Gera uma nova frase mnemônica e retorna a entropia e o mnemônico.
pub fn generate_mnemonic() -> Result<String> {
    let mut entropy = crate::util::rng::array::<32>()?;
    let mnemonic = entropy_to_mnemonic(&entropy);
    entropy.zeroize();
    Ok(mnemonic)
}

/// Cria um pacote de backup cifrado contendo `sqlite_bytes`.
///
/// Retorna a frase mnemônica gerada e os bytes finais contendo:
/// `b"VISKASAFE1" ‖ nonce (24 bytes) ‖ ciphertext ‖ tag (16 bytes)`.
pub fn create_encrypted_backup(sqlite_bytes: &[u8]) -> Result<(String, Vec<u8>)> {
    let mut entropy = crate::util::rng::array::<32>()?;
    let mnemonic = entropy_to_mnemonic(&entropy);
    let key = derive_backup_key(&entropy);
    entropy.zeroize();

    let mut payload = sqlite_bytes.to_vec();
    aead::seal_xchacha(&key, BACKUP_HEADER_MAGIC, &mut payload)?;

    let mut backup_bytes = Vec::with_capacity(BACKUP_HEADER_MAGIC.len() + payload.len());
    backup_bytes.extend_from_slice(BACKUP_HEADER_MAGIC);
    backup_bytes.extend_from_slice(&payload);

    Ok((mnemonic, backup_bytes))
}

/// Restaura e decifra o pacote de backup a partir de `backup_bytes` e do `mnemonic`.
pub fn restore_encrypted_backup(backup_bytes: &[u8], mnemonic: &str) -> Result<Vec<u8>> {
    const MIN_LEN: usize = BACKUP_HEADER_MAGIC.len() + 24 + 16;
    if backup_bytes.len() < MIN_LEN {
        return Err(Error::Malformed("arquivo de backup curto demais"));
    }

    if &backup_bytes[..BACKUP_HEADER_MAGIC.len()] != BACKUP_HEADER_MAGIC {
        return Err(Error::Malformed(
            "cabeçalho identificador de backup inválido",
        ));
    }

    let mut entropy = mnemonic_to_entropy(mnemonic)?;
    let key = derive_backup_key(&entropy);
    entropy.zeroize();

    let mut payload = backup_bytes[BACKUP_HEADER_MAGIC.len()..].to_vec();
    aead::open_xchacha(&key, BACKUP_HEADER_MAGIC, &mut payload)?;

    Ok(payload)
}

/// Exporta os bytes de banco fornecidos para um arquivo cifrado em `dest_path`.
pub fn export_backup_to_file(sqlite_bytes: &[u8], dest_path: &Path) -> Result<String> {
    let (mnemonic, encrypted) = create_encrypted_backup(sqlite_bytes)?;
    fs::write(dest_path, &encrypted).map_err(|_| Error::Store)?;
    Ok(mnemonic)
}

/// Lê o arquivo de backup em `src_path` e decifra usando o `mnemonic`.
pub fn restore_backup_from_file(src_path: &Path, mnemonic: &str) -> Result<Vec<u8>> {
    let encrypted = fs::read(src_path).map_err(|_| Error::Store)?;
    restore_encrypted_backup(&encrypted, mnemonic)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mnemonic_roundtrip_pt_br() {
        let mut entropy = [0x55u8; 32];
        let mnemonic = entropy_to_mnemonic(&entropy);
        let words: Vec<&str> = mnemonic.split_whitespace().collect();
        assert_eq!(words.len(), 24);

        let recovered = mnemonic_to_entropy(&mnemonic).unwrap();
        assert_eq!(recovered, entropy);
        entropy.zeroize();
    }

    #[test]
    fn mnemonic_rejects_invalid_checksum() {
        let entropy = [0xAAu8; 32];
        let mnemonic = entropy_to_mnemonic(&entropy);
        let mut words: Vec<&str> = mnemonic.split_whitespace().collect();
        // Altera a última palavra para corromper o checksum
        let pt = wordlist_pt_br();
        let last_idx = pt.iter().position(|&p| p == words[23]).unwrap();
        let new_last = pt[(last_idx + 1) % 2048];
        words[23] = new_last;
        let tampered_mnemonic = words.join(" ");

        assert!(matches!(
            mnemonic_to_entropy(&tampered_mnemonic),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn mnemonic_rejects_wrong_word_count() {
        let err = mnemonic_to_entropy("abacate abaixo abalar");
        assert!(matches!(err, Err(Error::Malformed(_))));
    }

    #[test]
    fn backup_encryption_and_restoration_roundtrip() {
        let test_db_content = b"SQLite format 3\0test-database-content-fase9";
        let (mnemonic, encrypted) = create_encrypted_backup(test_db_content).unwrap();

        // Cabeçalho deve ser VISKASAFE1
        assert_eq!(&encrypted[..10], BACKUP_HEADER_MAGIC);

        // Restaura com sucesso
        let restored = restore_encrypted_backup(&encrypted, &mnemonic).unwrap();
        assert_eq!(restored, test_db_content);
    }

    #[test]
    fn backup_rejects_tampered_header() {
        let test_db = b"database payload";
        let (mnemonic, mut encrypted) = create_encrypted_backup(test_db).unwrap();
        encrypted[0] ^= 0xFF; // Adultera cabeçalho mágico

        let res = restore_encrypted_backup(&encrypted, &mnemonic);
        assert!(matches!(res, Err(Error::Malformed(_))));
    }

    #[test]
    fn backup_rejects_tampered_ciphertext() {
        let test_db = b"database payload";
        let (mnemonic, mut encrypted) = create_encrypted_backup(test_db).unwrap();
        let last = encrypted.len() - 1;
        encrypted[last] ^= 0x01; // Adultera tag Poly1305

        let res = restore_encrypted_backup(&encrypted, &mnemonic);
        assert!(matches!(res, Err(Error::AeadFailure)));
    }

    #[test]
    fn backup_rejects_wrong_mnemonic() {
        let test_db = b"database payload";
        let (_, encrypted) = create_encrypted_backup(test_db).unwrap();
        let wrong_mnemonic = generate_mnemonic().unwrap();

        let res = restore_encrypted_backup(&encrypted, &wrong_mnemonic);
        assert!(matches!(res, Err(Error::AeadFailure)));
    }
}
