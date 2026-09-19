//! Tipos de dados que atravessam a fronteira FFI.
//!
//! Tudo aqui é dado público: chaves que já saíram no QR Code e foram
//! verificadas por `crypto::pairing::decode_qr`, ou valores derivados delas
//! (dígitos e palavras do safety number). Nenhum campo carrega material
//! privado — `LocalIdentity` nunca aparece nesta lista.

use viska_proto::crypto::identity::PublicIdentity;

/// Um contato pareado, como a UI precisa exibi-lo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContactDto {
    pub device_id: Vec<u8>,
    pub signing_pubkey: Vec<u8>,
    pub dh_pubkey: Vec<u8>,
    pub paired_at_unix_secs: i64,
    pub nickname: Option<String>,
}

impl ContactDto {
    pub(crate) fn from_identity(
        identity: &PublicIdentity,
        paired_at_unix_secs: i64,
        nickname: Option<String>,
    ) -> Self {
        Self {
            device_id: identity.device_id.to_vec(),
            signing_pubkey: identity.signing.to_vec(),
            dh_pubkey: identity.dh.as_bytes().to_vec(),
            paired_at_unix_secs,
            nickname,
        }
    }
}

/// O safety number entre a identidade local e um contato, nas duas
/// representações da spec §3.3.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SafetyNumberDto {
    /// 12 grupos de 5 dígitos, separados por espaço.
    pub digits: String,
    /// 6 palavras da lista BIP-39 PT-BR, separadas por espaço.
    pub words: String,
}
