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
