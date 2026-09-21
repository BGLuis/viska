//! Identidade de longo prazo — §2 da especificação.
//!
//! Cada dispositivo tem três coisas persistentes: um par Ed25519 que assina
//! exclusivamente o payload do QR Code, um par X25519 que autentica os
//! handshakes, e um identificador opaco.
//!
//! A separação dos dois pares não é cosmética. O Ed25519 produz uma assinatura
//! transferível — algo que um terceiro pode verificar sozinho. Se ele assinasse
//! handshakes, qualquer transcript viraria prova de que este dispositivo
//! conversou com aquele, destruindo a deniabilidade. Então ele assina uma única
//! coisa, uma vez, e essa coisa é uma chave pública.

use crate::crypto::dh::{DhPublic, DhSecret};
use crate::{Error, Result};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use zeroize::Zeroize;

/// Tamanho do identificador opaco de dispositivo.
pub const DEVICE_ID_LEN: usize = 16;
/// Tamanho de uma chave Ed25519, pública ou privada.
pub const SIGNING_KEY_LEN: usize = 32;
/// Tamanho de uma assinatura Ed25519.
pub const SIGNATURE_LEN: usize = 64;

/// Identidade deste dispositivo, com as partes privadas.
pub struct LocalIdentity {
    device_id: [u8; DEVICE_ID_LEN],
    signing: SigningKey,
    dh: DhSecret,
}

/// Visão pública de uma identidade — a nossa ou a de um contato pareado.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PublicIdentity {
    pub device_id: [u8; DEVICE_ID_LEN],
    pub signing: [u8; SIGNING_KEY_LEN],
    pub dh: DhPublic,
}

impl LocalIdentity {
    /// Cria uma identidade nova.
    ///
    /// O `device_id` é aleatório, nunca derivado de IMEI, Android ID, endereço
    /// MAC ou qualquer outro identificador de hardware: ele existe para
    /// desambiguar dispositivos de um mesmo contato, não para rastreá-los.
    pub fn generate() -> Result<Self> {
        let device_id = crate::util::rng::array::<DEVICE_ID_LEN>()?;
        let mut signing_seed = crate::util::rng::array::<SIGNING_KEY_LEN>()?;
        let signing = SigningKey::from_bytes(&signing_seed);
        signing_seed.zeroize();

        Ok(Self {
            device_id,
            signing,
            dh: DhSecret::generate()?,
        })
    }

    /// Reconstrói a identidade a partir do banco cifrado.
    pub fn from_parts(
        device_id: [u8; DEVICE_ID_LEN],
        signing_seed: [u8; SIGNING_KEY_LEN],
        dh_secret: [u8; crate::crypto::dh::KEY_LEN],
    ) -> Self {
        let mut seed = signing_seed;
        let signing = SigningKey::from_bytes(&seed);
        seed.zeroize();

        Self {
            device_id,
            signing,
            dh: DhSecret::from_bytes(dh_secret),
        }
    }

    pub fn device_id(&self) -> &[u8; DEVICE_ID_LEN] {
        &self.device_id
    }

    pub fn dh(&self) -> &DhSecret {
        &self.dh
    }

    /// Semente Ed25519. Só para persistir no banco cifrado.
    pub fn signing_seed(&self) -> [u8; SIGNING_KEY_LEN] {
        self.signing.to_bytes()
    }

    /// Visão pública desta identidade — é isso que vai para o QR Code.
    pub fn public(&self) -> PublicIdentity {
        PublicIdentity {
            device_id: self.device_id,
            signing: self.signing.verifying_key().to_bytes(),
            dh: self.dh.public(),
        }
    }

    /// Assina `message` com a chave Ed25519.
    ///
    /// Restrito ao payload do QR Code. Qualquer outro uso precisa de uma
    /// justificativa explícita, porque assinatura é o oposto de deniabilidade.
    pub(crate) fn sign(&self, message: &[u8]) -> [u8; SIGNATURE_LEN] {
        self.signing.sign(message).to_bytes()
    }
}

impl PublicIdentity {
    /// Verifica uma assinatura Ed25519 produzida por esta identidade.
    ///
    /// Usa `verify_strict`, que rejeita chaves e assinaturas de ordem baixa —
    /// a verificação permissiva aceita assinaturas que validam sob mais de uma
    /// chave pública, o que quebra a ligação entre identidade e payload.
    pub fn verify(&self, message: &[u8], signature: &[u8; SIGNATURE_LEN]) -> Result<()> {
        let verifying = VerifyingKey::from_bytes(&self.signing)
            .map_err(|_| Error::InvalidPublicKey("Ed25519 não canônica"))?;
        let signature = Signature::from_bytes(signature);

        verifying
            .verify_strict(message, &signature)
            .map_err(|_| Error::BadSignature)
    }

    /// Ordem canônica entre duas identidades.
    ///
    /// Vários pontos do protocolo precisam de papéis assimétricos sem um
    /// round-trip de negociação: quem inicia o handshake, qual direção é "a2b"
    /// na sinalização, qual hash entra primeiro no safety number. Todos usam a
    /// ordem lexicográfica das chaves X25519, que os dois lados calculam
    /// sozinhos e sempre concordam.
    pub fn is_before(&self, other: &PublicIdentity) -> bool {
        self.dh.as_bytes() < other.dh.as_bytes()
    }
}

impl core::fmt::Debug for LocalIdentity {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("LocalIdentity")
            .field("device_id", &"<opaco>")
            .field("signing", &"<redigida>")
            .field("dh", &"<redigida>")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signs_and_verifies() {
        let identity = LocalIdentity::generate().unwrap();
        let message = b"payload do qr";
        let signature = identity.sign(message);

        identity.public().verify(message, &signature).unwrap();
    }

    #[test]
    fn rejects_signature_from_different_identity() {
        let mine = LocalIdentity::generate().unwrap();
        let theirs = LocalIdentity::generate().unwrap();
        let message = b"payload do qr";

        let signature = theirs.sign(message);
        assert!(matches!(
            mine.public().verify(message, &signature),
            Err(Error::BadSignature)
        ));
    }

    #[test]
    fn rejects_tampered_message() {
        let identity = LocalIdentity::generate().unwrap();
        let signature = identity.sign(b"original");

        assert!(matches!(
            identity.public().verify(b"adulterada", &signature),
            Err(Error::BadSignature)
        ));
    }

    #[test]
    fn canonical_ordering_is_total_and_agreed() {
        let a = LocalIdentity::generate().unwrap().public();
        let b = LocalIdentity::generate().unwrap().public();

        // Exatamente um dos dois vem antes, e os dois lados concordam.
        assert_ne!(a.is_before(&b), b.is_before(&a));
    }
}
