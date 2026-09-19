//! Encapsulamento de chaves pós-quântico — ML-KEM-768 (FIPS 203).
//!
//! O KEM fica atrás de um trait por um motivo prático: as implementações
//! disponíveis em Rust ainda estão em versões 0.0.x e a API muda. Trocar de
//! backend não pode implicar reescrever handshake e ratchet.
//!
//! O backend é `libcrux-ml-kem`, formalmente verificado (HACL*/F*) e usado em
//! produção. A alternativa óbvia, `ml-kem` (RustCrypto), foi descartada porque
//! a própria documentação dela avisa que não passou por auditoria — para a
//! primitiva de que depende toda a resistência quântica do projeto, essa
//! diferença decide.

use crate::{Error, Result};
use zeroize::{Zeroize, ZeroizeOnDrop};

/// Tamanho da chave pública de encapsulamento ML-KEM-768.
pub const PUBLIC_KEY_LEN: usize = 1184;
/// Tamanho da chave privada de decapsulamento ML-KEM-768.
pub const SECRET_KEY_LEN: usize = 2400;
/// Tamanho do ciphertext ML-KEM-768.
pub const CIPHERTEXT_LEN: usize = 1088;
/// Tamanho do segredo compartilhado produzido pelo KEM.
pub const SHARED_SECRET_LEN: usize = 32;

/// Chave pública de encapsulamento. Pública por definição, não precisa de higiene.
#[derive(Clone, PartialEq, Eq)]
pub struct KemPublicKey(pub [u8; PUBLIC_KEY_LEN]);

/// Chave privada de decapsulamento.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct KemSecretKey([u8; SECRET_KEY_LEN]);

/// Ciphertext do encapsulamento.
#[derive(Clone, PartialEq, Eq)]
pub struct KemCiphertext(pub [u8; CIPHERTEXT_LEN]);

/// Segredo compartilhado produzido pelo KEM.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct KemSharedSecret([u8; SHARED_SECRET_LEN]);

impl KemPublicKey {
    pub fn as_bytes(&self) -> &[u8; PUBLIC_KEY_LEN] {
        &self.0
    }

    pub fn from_slice(bytes: &[u8]) -> Result<Self> {
        let array: [u8; PUBLIC_KEY_LEN] = bytes.try_into().map_err(|_| Error::BadLength {
            expected: PUBLIC_KEY_LEN,
            actual: bytes.len(),
        })?;
        Ok(Self(array))
    }
}

impl KemCiphertext {
    pub fn as_bytes(&self) -> &[u8; CIPHERTEXT_LEN] {
        &self.0
    }

    pub fn from_slice(bytes: &[u8]) -> Result<Self> {
        let array: [u8; CIPHERTEXT_LEN] = bytes.try_into().map_err(|_| Error::BadLength {
            expected: CIPHERTEXT_LEN,
            actual: bytes.len(),
        })?;
        Ok(Self(array))
    }
}

impl KemSecretKey {
    pub fn as_bytes(&self) -> &[u8; SECRET_KEY_LEN] {
        &self.0
    }

    pub fn from_bytes(bytes: [u8; SECRET_KEY_LEN]) -> Self {
        Self(bytes)
    }
}

impl KemSharedSecret {
    pub fn as_bytes(&self) -> &[u8; SHARED_SECRET_LEN] {
        &self.0
    }
}

impl core::fmt::Debug for KemPublicKey {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("KemPublicKey(..)")
    }
}

impl core::fmt::Debug for KemCiphertext {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("KemCiphertext(..)")
    }
}

impl core::fmt::Debug for KemSecretKey {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("KemSecretKey(<redigida>)")
    }
}

impl core::fmt::Debug for KemSharedSecret {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("KemSharedSecret(<redigido>)")
    }
}

/// Par de chaves do KEM.
#[derive(Debug)]
pub struct KemKeyPair {
    pub public: KemPublicKey,
    pub secret: KemSecretKey,
}

/// Interface de um KEM pós-quântico de nível 3 do NIST.
pub trait Kem {
    /// Gera um par de chaves novo a partir do CSPRNG do sistema.
    fn generate() -> Result<KemKeyPair>;

    /// Encapsula um segredo contra `public`.
    fn encapsulate(public: &KemPublicKey) -> Result<(KemCiphertext, KemSharedSecret)>;

    /// Recupera o segredo encapsulado.
    fn decapsulate(secret: &KemSecretKey, ciphertext: &KemCiphertext) -> Result<KemSharedSecret>;
}

/// Backend ativo, selecionado em tempo de compilação.
///
/// Struct de chaves vazias em vez de unit struct (`;`): o parser do
/// `flutter_rust_bridge_codegen` não suporta unit structs em nenhum lugar do
/// crate, mesmo em tipos que nunca cruzam o FFI — troca puramente sintática,
/// sem mudança de comportamento (`MlKem768` só é usado via `Self::método()`).
#[derive(Debug)]
pub struct MlKem768 {}

mod backend {
    use super::*;
    use libcrux_ml_kem::mlkem768;

    impl Kem for MlKem768 {
        fn generate() -> Result<KemKeyPair> {
            // ML-KEM-768 consome 64 bytes de entropia na geração de chaves: 32
            // para a semente do módulo e 32 para o segredo de rejeição implícita.
            let mut seed = crate::util::rng::array::<64>()?;
            let pair = mlkem768::generate_key_pair(seed);
            seed.zeroize();

            Ok(KemKeyPair {
                public: KemPublicKey(*pair.public_key().as_slice()),
                secret: KemSecretKey(*pair.private_key().as_slice()),
            })
        }

        fn encapsulate(public: &KemPublicKey) -> Result<(KemCiphertext, KemSharedSecret)> {
            let key = mlkem768::MlKem768PublicKey::from(public.0);
            // FIPS 203 exige a checagem de "modulus" na chave recebida: uma chave
            // malformada pode ser usada para induzir segredos previsíveis.
            if !mlkem768::validate_public_key(&key) {
                return Err(Error::InvalidPublicKey("ML-KEM-768 reprovada na validação"));
            }

            let mut randomness = crate::util::rng::array::<32>()?;
            let (ciphertext, shared) = mlkem768::encapsulate(&key, randomness);
            randomness.zeroize();

            Ok((
                KemCiphertext(*ciphertext.as_slice()),
                KemSharedSecret(shared),
            ))
        }

        fn decapsulate(
            secret: &KemSecretKey,
            ciphertext: &KemCiphertext,
        ) -> Result<KemSharedSecret> {
            let sk = mlkem768::MlKem768PrivateKey::from(secret.0);
            let ct = mlkem768::MlKem768Ciphertext::from(ciphertext.0);
            // ML-KEM nunca falha em decapsular: um ciphertext inválido produz um
            // segredo pseudoaleatório (rejeição implícita). A divergência só
            // aparece adiante, quando o AEAD não abrir.
            Ok(KemSharedSecret(mlkem768::decapsulate(&sk, &ct)))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encapsulamento_ida_e_volta() {
        let pair = MlKem768::generate().unwrap();
        let (ciphertext, sender_secret) = MlKem768::encapsulate(&pair.public).unwrap();
        let receiver_secret = MlKem768::decapsulate(&pair.secret, &ciphertext).unwrap();

        assert_eq!(sender_secret.as_bytes(), receiver_secret.as_bytes());
    }

    #[test]
    fn tamanhos_conferem_com_o_fips_203() {
        let pair = MlKem768::generate().unwrap();
        let (ciphertext, shared) = MlKem768::encapsulate(&pair.public).unwrap();

        assert_eq!(pair.public.as_bytes().len(), 1184);
        assert_eq!(pair.secret.as_bytes().len(), 2400);
        assert_eq!(ciphertext.as_bytes().len(), 1088);
        assert_eq!(shared.as_bytes().len(), 32);
    }

    #[test]
    fn pares_distintos_produzem_segredos_distintos() {
        let first = MlKem768::generate().unwrap();
        let second = MlKem768::generate().unwrap();
        assert_ne!(first.public.as_bytes(), second.public.as_bytes());

        let (ct, ss) = MlKem768::encapsulate(&first.public).unwrap();
        // Decapsular com a chave errada não falha: ML-KEM faz rejeição
        // implícita e devolve um segredo pseudoaleatório. O que não pode
        // acontecer é os dois baterem.
        let wrong = MlKem768::decapsulate(&second.secret, &ct).unwrap();
        assert_ne!(ss.as_bytes(), wrong.as_bytes());
    }
}
