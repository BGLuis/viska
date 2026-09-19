//! Diffie-Hellman X25519 com rejeição de pontos de ordem baixa.
//!
//! A biblioteca subjacente aceita qualquer chave pública de 32 bytes e devolve
//! um segredo, inclusive quando o ponto recebido tem ordem baixa e força o
//! resultado a zero. Um par malicioso pode usar isso para que os dois lados
//! "concordem" em um segredo que ele escolheu. Por isso todo DH neste crate
//! passa por `agree`, que rejeita o resultado all-zero.

use crate::{Error, Result};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, ZeroizeOnDrop};

/// Tamanho de uma chave X25519, pública ou privada.
pub const KEY_LEN: usize = 32;

/// Chave privada X25519.
pub struct DhSecret(StaticSecret);

/// Chave pública X25519.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct DhPublic([u8; KEY_LEN]);

/// Segredo compartilhado de um acordo X25519.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct DhShared([u8; KEY_LEN]);

impl DhSecret {
    /// Gera uma chave privada nova a partir do CSPRNG do sistema.
    pub fn generate() -> Result<Self> {
        let mut seed = crate::util::rng::array::<KEY_LEN>()?;
        let secret = StaticSecret::from(seed);
        seed.zeroize();
        Ok(Self(secret))
    }

    /// Reconstrói uma chave privada a partir de bytes persistidos.
    pub fn from_bytes(bytes: [u8; KEY_LEN]) -> Self {
        Self(StaticSecret::from(bytes))
    }

    /// Bytes da chave privada. Só para persistir no banco cifrado.
    pub fn to_bytes(&self) -> [u8; KEY_LEN] {
        self.0.to_bytes()
    }

    /// Chave pública correspondente.
    pub fn public(&self) -> DhPublic {
        DhPublic(PublicKey::from(&self.0).to_bytes())
    }

    /// Executa o acordo com `peer`, rejeitando contribuições de ordem baixa.
    pub fn agree(&self, peer: &DhPublic) -> Result<DhShared> {
        let shared = self.0.diffie_hellman(&PublicKey::from(peer.0));
        if !shared.was_contributory() {
            return Err(Error::LowOrderPoint);
        }
        Ok(DhShared(shared.to_bytes()))
    }
}

impl DhPublic {
    pub const fn from_bytes(bytes: [u8; KEY_LEN]) -> Self {
        Self(bytes)
    }

    pub fn from_slice(bytes: &[u8]) -> Result<Self> {
        let array: [u8; KEY_LEN] = bytes.try_into().map_err(|_| Error::BadLength {
            expected: KEY_LEN,
            actual: bytes.len(),
        })?;
        Ok(Self(array))
    }

    pub const fn as_bytes(&self) -> &[u8; KEY_LEN] {
        &self.0
    }
}

impl DhShared {
    pub fn as_bytes(&self) -> &[u8; KEY_LEN] {
        &self.0
    }
}

impl core::fmt::Debug for DhSecret {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("DhSecret(<redigida>)")
    }
}

impl core::fmt::Debug for DhShared {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("DhShared(<redigido>)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn acordo_e_simetrico() {
        let a = DhSecret::generate().unwrap();
        let b = DhSecret::generate().unwrap();

        let ab = a.agree(&b.public()).unwrap();
        let ba = b.agree(&a.public()).unwrap();

        assert_eq!(ab.as_bytes(), ba.as_bytes());
    }

    #[test]
    fn rejeita_pontos_de_ordem_baixa() {
        let secret = DhSecret::generate().unwrap();

        // Os pontos de ordem baixa canônicos da Curve25519. Todos forçam o
        // segredo compartilhado a zero, qualquer que seja a chave privada.
        const LOW_ORDER: [&str; 7] = [
            "0000000000000000000000000000000000000000000000000000000000000000",
            "0100000000000000000000000000000000000000000000000000000000000000",
            "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
            "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
            "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
            "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
            "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        ];

        for encoded in LOW_ORDER {
            let mut bytes = [0u8; 32];
            hex::decode_to_slice(encoded, &mut bytes).unwrap();
            let peer = DhPublic::from_bytes(bytes);
            assert!(
                matches!(secret.agree(&peer), Err(Error::LowOrderPoint)),
                "ponto de ordem baixa aceito: {encoded}"
            );
        }
    }
}
