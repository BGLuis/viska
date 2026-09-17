//! Envelope de transporte — `docs/protocol.md` §6 e D4.
//!
//! ```text
//!  0                   1                   2                   3
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! |                     Counter (u32, big-endian)                 |
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! |          Ciphertext = AEAD(MK, nonce, AAD=Counter, ...)       |
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! |                    Poly1305 Tag (16 B)                        |
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! ```
//!
//! Este módulo não cifra nada: `crypto::aead::seal` já devolve
//! `ciphertext ‖ tag` como um único buffer contíguo (a crate subjacente anexa
//! a tag em-lugar), então "montar o envelope" é só prefixar o contador diante
//! desse buffer. A camada de sessão futura é quem chama `aead::seal`/`open` e
//! usa `aad` daqui para saber que bytes exatos entram como AAD — a mesma
//! convenção nos dois lados, e explícita em vez de reconstruída por acaso em
//! cada chamador.
//!
//! O `Counter` é o único metadado em claro do protocolo (D4): o receptor
//! precisa dele antes de conseguir decifrar qualquer coisa, para derivar o
//! nonce (`0x00000000 ‖ 0x00000000 ‖ Counter_be`) e localizar a chave de
//! mensagem certa no ratchet.

use crate::crypto::aead::TAG_LEN;
use crate::util::encoding::read_u32;
use crate::{Error, Result};

/// Tamanho do contador em claro no início do envelope.
pub const COUNTER_LEN: usize = 4;

/// Monta o envelope a partir do contador e de um ciphertext já selado
/// (`ciphertext ‖ tag`, como `crypto::aead::seal` o produz).
pub fn encode(counter: u32, sealed: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(COUNTER_LEN + sealed.len());
    out.extend_from_slice(&counter.to_be_bytes());
    out.extend_from_slice(sealed);
    out
}

/// Desmonta um envelope: devolve o contador em claro e a fatia
/// `ciphertext ‖ tag` que segue, pronta para `crypto::aead::open`.
///
/// Só valida que há bytes suficientes para conter o contador e uma tag — não
/// há como validar mais do que isso sem a chave, e é exatamente por isso que
/// esta camada não tenta: qualquer coisa além de comprimento é trabalho do
/// AEAD.
pub fn decode(envelope: &[u8]) -> Result<(u32, &[u8])> {
    if envelope.len() < COUNTER_LEN + TAG_LEN {
        return Err(Error::Malformed(
            "envelope curto demais para conter contador e tag",
        ));
    }
    let counter = read_u32(envelope).expect("comprimento mínimo checado acima");
    Ok((counter, &envelope[COUNTER_LEN..]))
}

/// Bytes de AAD que a camada de sessão deve passar ao AEAD: o contador em
/// claro, exatamente como aparece no envelope.
///
/// Exposto como função em vez de deixar cada chamador escrever
/// `counter.to_be_bytes()` de novo — essa convenção (o AAD é literalmente o
/// campo `Counter` do envelope) é normativa, não um detalhe de implementação.
pub fn aad(counter: u32) -> [u8; COUNTER_LEN] {
    counter.to_be_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ida_e_volta() {
        let sealed = vec![0xAAu8; 100 + TAG_LEN];
        let envelope = encode(42, &sealed);

        let (counter, rest) = decode(&envelope).unwrap();
        assert_eq!(counter, 42);
        assert_eq!(rest, sealed.as_slice());
    }

    #[test]
    fn aad_e_o_contador_big_endian() {
        assert_eq!(aad(1), [0, 0, 0, 1]);
        assert_eq!(aad(0x0102_0304), [0x01, 0x02, 0x03, 0x04]);
    }

    #[test]
    fn rejeita_envelope_curto_demais_sem_panico() {
        for len in 0..(COUNTER_LEN + TAG_LEN) {
            let curto = vec![0u8; len];
            assert!(matches!(decode(&curto), Err(Error::Malformed(_))));
        }
    }

    #[test]
    fn decode_nunca_panica_em_bytes_arbitrarios() {
        // Não é o property test formal do módulo (esse vive em plaintext.rs),
        // mas o envelope também processa bytes de um par não confiável antes
        // de qualquer verificação criptográfica, e merece a mesma garantia.
        for len in 0..64 {
            let bytes = vec![0x5Au8; len];
            let _ = decode(&bytes);
        }
    }
}
