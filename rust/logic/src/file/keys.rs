//! Derivação de chaves por transferência — `docs/protocol.md` §7.1/§7.5, D15.
//!
//! Tudo deriva de `K_file`, por sua vez derivado de `transfer_secret` (D15:
//! um segredo local aleatório por transferência, não uma chave do ratchet —
//! ver o registro completo do porquê em `docs/deviations.md`) e `file_id`.
//! Cada uso posterior tem seu próprio contexto de KDF, para permanecer
//! independente mesmo com a mesma entrada:
//!
//! ```text
//! K_file       = derive(FILE_KEY,    transfer_secret ‖ file_id)
//! K_staging    = derive(STAGING,     K_file)   — páginas do .staging (§7.5)
//! K_name       = derive(FILE_NAME,   K_file)   — name_encrypted do manifesto (§7.1)
//! K_symbol     = derive(FILE_SYMBOL, K_file)   — corpo de cada FILE_SYMBOL (§7.3, D11)
//! K_audio_chunk = derive(AUDIO_CHUNK, K_file)  — corpo de cada AUDIO_CHUNK (Fase 5, D16)
//! ```
//!
//! `K_symbol`/`K_audio_chunk` são a peça que faz `FILE_SYMBOL`/`AUDIO_CHUNK`
//! não precisarem de `session::Session` — mesmo padrão de `signaling::payload`
//! (chave própria, fora do ratchet), confirmado por não haver contador
//! confiável em símbolos de um canal não confiável, e por rodar milhares
//! deles pela cadeia sequencial do ratchet (compartilhada com o chat)
//! estressar o teto de chaves puladas (§5.5, 1000) para nada — nem um
//! símbolo de arquivo nem um pedaço de áudio precisam da autenticação
//! deniável da sessão, só de confidencialidade e integridade próprias.
//! `K_symbol` e `K_audio_chunk` nunca são a mesma chave, mesmo para o mesmo
//! `(transfer_secret, file_id)`: contextos de KDF diferentes (D16).

use crate::crypto::kdf::{self, Key};
use crate::file::manifest::FILE_ID_LEN;

/// `K_file` — raiz de todas as chaves desta transferência.
pub fn derive_file_key(transfer_secret: &[u8], file_id: &[u8; FILE_ID_LEN]) -> Key {
    let mut material = Vec::with_capacity(transfer_secret.len() + file_id.len());
    material.extend_from_slice(transfer_secret);
    material.extend_from_slice(file_id);
    kdf::derive(kdf::context::FILE_KEY, &material)
}

/// `K_staging` — cifra as páginas do `.staging` (§7.5).
pub fn derive_staging_key(transfer_secret: &[u8], file_id: &[u8; FILE_ID_LEN]) -> Key {
    let k_file = derive_file_key(transfer_secret, file_id);
    kdf::derive(kdf::context::STAGING, k_file.as_bytes())
}

/// `K_name` — cifra `name_encrypted` no manifesto (§7.1).
pub fn derive_name_key(transfer_secret: &[u8], file_id: &[u8; FILE_ID_LEN]) -> Key {
    let k_file = derive_file_key(transfer_secret, file_id);
    kdf::derive(kdf::context::FILE_NAME, k_file.as_bytes())
}

/// `K_symbol` — cifra cada `FILE_SYMBOL`, fora do ratchet (D11).
pub fn derive_symbol_key(transfer_secret: &[u8], file_id: &[u8; FILE_ID_LEN]) -> Key {
    let k_file = derive_file_key(transfer_secret, file_id);
    kdf::derive(kdf::context::FILE_SYMBOL, k_file.as_bytes())
}

/// `K_audio_chunk` — cifra cada `AUDIO_CHUNK` de uma nota de voz, fora do
/// ratchet, no mesmo espírito de `K_symbol` (Fase 5, D16). Contexto de KDF
/// próprio: nunca a mesma chave que `K_symbol`, mesmo para o mesmo
/// `(transfer_secret, file_id)`.
pub fn derive_audio_key(transfer_secret: &[u8], file_id: &[u8; FILE_ID_LEN]) -> Key {
    let k_file = derive_file_key(transfer_secret, file_id);
    kdf::derive(kdf::context::AUDIO_CHUNK, k_file.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_five_keys_are_mutually_distinct() {
        let secret = b"segredo-de-transferencia";
        let file_id = [5u8; FILE_ID_LEN];

        let k_file = derive_file_key(secret, &file_id);
        let k_staging = derive_staging_key(secret, &file_id);
        let k_name = derive_name_key(secret, &file_id);
        let k_symbol = derive_symbol_key(secret, &file_id);
        let k_audio = derive_audio_key(secret, &file_id);

        let all = [
            k_file.as_bytes(),
            k_staging.as_bytes(),
            k_name.as_bytes(),
            k_symbol.as_bytes(),
            k_audio.as_bytes(),
        ];
        for i in 0..all.len() {
            for j in (i + 1)..all.len() {
                assert_ne!(all[i], all[j], "chaves {i} e {j} deveriam ser diferentes");
            }
        }
    }

    #[test]
    fn k_audio_chunk_is_distinct_from_k_symbol_for_same_secret_file_id_pair() {
        let secret = b"mesmo-segredo-para-os-dois-usos";
        let file_id = [12u8; FILE_ID_LEN];
        assert_ne!(
            derive_symbol_key(secret, &file_id).as_bytes(),
            derive_audio_key(secret, &file_id).as_bytes()
        );
    }

    #[test]
    fn are_deterministic_for_same_secret_file_id_pair() {
        let secret = b"outro-segredo";
        let file_id = [6u8; FILE_ID_LEN];
        assert_eq!(
            derive_symbol_key(secret, &file_id).as_bytes(),
            derive_symbol_key(secret, &file_id).as_bytes()
        );
    }

    #[test]
    fn change_with_file_id() {
        let secret = b"mesmo-segredo";
        let a = derive_symbol_key(secret, &[1u8; FILE_ID_LEN]);
        let b = derive_symbol_key(secret, &[2u8; FILE_ID_LEN]);
        assert_ne!(a.as_bytes(), b.as_bytes());
    }
}
