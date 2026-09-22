//! Derivação de chaves — §1 da especificação.
//!
//! Tudo deriva de `BLAKE3::derive_key`, que é uma KDF de domínio separado: dois
//! contextos diferentes produzem chaves independentes mesmo a partir do mesmo
//! material de entrada. Os contextos são literais fixos e versionados; mudar um
//! contexto é uma quebra de protocolo e exige subir a versão.

use zeroize::{Zeroize, ZeroizeOnDrop};

/// Tamanho padrão de chave simétrica no Viska.
pub const KEY_LEN: usize = 32;

/// Chave simétrica de 32 bytes, zerada ao sair de escopo.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct Key(pub [u8; KEY_LEN]);

impl Key {
    pub const fn from_bytes(bytes: [u8; KEY_LEN]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; KEY_LEN] {
        &self.0
    }
}

// A implementação manual esconde o conteúdo: uma chave jamais deve aparecer em
// log, painel de crash ou mensagem de erro.
impl core::fmt::Debug for Key {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("Key(<redigida>)")
    }
}

/// Contextos de derivação. São normativos: veja §1 de `docs/protocol.md`.
pub mod context {
    pub const QR_SIGNATURE: &str = "viska-qr-sig-v1";
    pub const SAFETY_NUMBER: &str = "viska-safety-number-v1";
    /// Índices de palavra do safety number (§3.3) — derivação separada da dos
    /// dígitos para não reaproveitar bytes já consumidos pelo XOF de 60 bytes
    /// e não acoplar o layout de bits das duas representações.
    pub const SAFETY_NUMBER_WORDS: &str = "viska-safety-number-words-v1";
    pub const HANDSHAKE: &str = "viska-handshake-v1";
    pub const ROOT_CHAIN: &str = "viska-root-chain-v1";
    /// Avanço da cadeia simétrica, de envio **e** de recepção.
    ///
    /// Contexto único de propósito: a cadeia de envio de um par é a cadeia de
    /// recepção do outro, o mesmo segredo evoluindo nos dois aparelhos. Um
    /// contexto por lado faria as duas divergirem na primeira mensagem.
    pub const SEND_CHAIN: &str = "viska-send-chain-v1";
    pub const MESSAGE_KEY: &str = "viska-msg-key-v1";
    pub const REKEM: &str = "viska-rekem-v1";
    pub const SIGNALING: &str = "viska-signaling-v1";
    pub const BEACON: &str = "viska-beacon-v1";
    pub const FILE_KEY: &str = "viska-file-key-v1";
    pub const STAGING: &str = "viska-staging-v1";
    /// Cifra o nome original do arquivo dentro do corpo do manifesto (§7.1).
    pub const FILE_NAME: &str = "viska-file-name-v1";
    /// Cifra cada símbolo RaptorQ no canal não confiável — fora do ratchet,
    /// no mesmo espírito de `SIGNALING` (D6/D11): um símbolo precisa
    /// decifrar mesmo depois de a sessão ter sido reaberta, e o volume de
    /// símbolos por transferência estressaria o teto de chaves puladas do
    /// ratchet (§5.5) se corresse pela cadeia normal.
    pub const FILE_SYMBOL: &str = "viska-file-symbol-v1";
    /// Cifra cada `AUDIO_CHUNK` de uma nota de voz — mesmo raciocínio de
    /// `FILE_SYMBOL` (fora do ratchet, D11), contexto próprio para nunca
    /// reaproveitar a mesma chave entre os dois usos mesmo quando os dois
    /// derivam do mesmo `K_file` (Fase 5, D16).
    pub const AUDIO_CHUNK: &str = "viska-audio-chunk-v1";
    pub const DATABASE: &str = "viska-db-key-v1";
}

/// Deriva uma chave de 32 bytes a partir de um contexto e material de entrada.
pub fn derive(context: &str, material: &[u8]) -> Key {
    Key(blake3::derive_key(context, material))
}

/// Deriva duas chaves independentes de 32 bytes em um único passo.
///
/// Usado pelo ratchet, onde cada passo da cadeia raiz produz simultaneamente a
/// nova raiz e a nova chave de cadeia.
pub fn derive_pair(context: &str, material: &[u8]) -> (Key, Key) {
    let mut wide = [0u8; KEY_LEN * 2];
    blake3::Hasher::new_derive_key(context)
        .update(material)
        .finalize_xof()
        .fill(&mut wide);

    let mut first = [0u8; KEY_LEN];
    let mut second = [0u8; KEY_LEN];
    first.copy_from_slice(&wide[..KEY_LEN]);
    second.copy_from_slice(&wide[KEY_LEN..]);
    wide.zeroize();

    (Key(first), Key(second))
}

/// Deriva `N` bytes arbitrários a partir de um contexto (saída XOF).
pub fn derive_bytes<const N: usize>(context: &str, material: &[u8]) -> [u8; N] {
    let mut out = [0u8; N];
    blake3::Hasher::new_derive_key(context)
        .update(material)
        .finalize_xof()
        .fill(&mut out);
    out
}

/// MAC/PRF com chave: `BLAKE3_keyed(key, data)`.
///
/// É o que gera tópicos de sinalização e identificadores de beacon: pseudo-
/// aleatórios para quem não tem a chave, determinísticos para quem tem.
pub fn keyed(key: &Key, data: &[u8]) -> [u8; 32] {
    *blake3::keyed_hash(key.as_bytes(), data).as_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn domain_separation_produces_distinct_keys_for_same_material() {
        let material = b"shared secret material";
        let key1 = derive(context::HANDSHAKE, material);
        let key2 = derive(context::ROOT_CHAIN, material);
        assert_ne!(key1.as_bytes(), key2.as_bytes());
    }

    #[test]
    fn different_material_produces_distinct_keys_in_same_context() {
        let key1 = derive(context::MESSAGE_KEY, b"input-a");
        let key2 = derive(context::MESSAGE_KEY, b"input-b");
        assert_ne!(key1.as_bytes(), key2.as_bytes());
    }

    #[test]
    fn derive_pair_produces_two_mutually_distinct_keys() {
        let (k1, k2) = derive_pair(context::ROOT_CHAIN, b"ratchet step");
        assert_ne!(k1.as_bytes(), k2.as_bytes());
    }

    #[test]
    fn derive_pair_matches_derive_bytes_stream_split() {
        let material = b"deterministic stream input";
        let (k1, k2) = derive_pair(context::ROOT_CHAIN, material);
        let full_stream = derive_bytes::<64>(context::ROOT_CHAIN, material);

        assert_eq!(k1.as_bytes(), &full_stream[..32]);
        assert_eq!(k2.as_bytes(), &full_stream[32..]);
    }

    #[test]
    fn derive_bytes_produces_requested_length_deterministically() {
        let out1 = derive_bytes::<16>(context::SAFETY_NUMBER, b"seed");
        let out2 = derive_bytes::<16>(context::SAFETY_NUMBER, b"seed");
        let out3 = derive_bytes::<16>(context::SAFETY_NUMBER, b"other seed");

        assert_eq!(out1, out2);
        assert_ne!(out1, out3);
    }

    #[test]
    fn keyed_hash_acts_as_prf_and_changes_with_key_and_data() {
        let key1 = Key::from_bytes([1u8; KEY_LEN]);
        let key2 = Key::from_bytes([2u8; KEY_LEN]);
        let data1 = b"topic epoch 100";
        let data2 = b"topic epoch 101";

        let tag1 = keyed(&key1, data1);
        let tag1_repeat = keyed(&key1, data1);
        let tag_diff_data = keyed(&key1, data2);
        let tag_diff_key = keyed(&key2, data1);

        assert_eq!(tag1, tag1_repeat);
        assert_ne!(tag1, tag_diff_data);
        assert_ne!(tag1, tag_diff_key);
    }

    #[test]
    fn debug_representation_redacts_key_material() {
        let key = Key::from_bytes([0x42; KEY_LEN]);
        let debug_str = format!("{:?}", key);
        assert_eq!(debug_str, "Key(<redigida>)");
        assert!(!debug_str.contains("42"));
    }
}
