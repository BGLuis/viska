//! Envelope de transporte — `docs/protocol.md` §6/§6.2 (D4) e §11.2 (D14).
//!
//! ```text
//!  0                   1                   2                   3
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! |                     Counter (u32, big-endian)                 |
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! |                                                               |
//! +                   dh_pub (32 B, X25519 efêmera)              +
//! |                                                               |
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! |          Ciphertext = AEAD(MK, nonce, AAD=Counter‖dh_pub, ...)|
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! |                    Poly1305 Tag (16 B)                        |
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! ```
//!
//! Este módulo não cifra nada: `crypto::aead::seal` já devolve
//! `ciphertext ‖ tag` como um único buffer contíguo (a crate subjacente anexa
//! a tag em-lugar), então "montar o envelope" é só prefixar o contador e o
//! `dh_pub` diante desse buffer. A camada de sessão futura é quem chama
//! `aead::seal`/`open` e usa `aad` daqui para saber que bytes exatos entram
//! como AAD — a mesma convenção nos dois lados, e explícita em vez de
//! reconstruída por acaso em cada chamador.
//!
//! O `Counter` é o único metadado em claro exigido por D4 — o receptor
//! precisa dele antes de conseguir decifrar qualquer coisa, para derivar o
//! nonce (`0x00000000 ‖ 0x00000000 ‖ Counter_be`) e localizar a chave de
//! mensagem certa no ratchet.
//!
//! ## Por que `dh_pub` também está em claro aqui (D14)
//!
//! Uma versão anterior deste envelope seguia `docs/protocol.md` §6.1 à risca
//! e carregava `dh_pub` dentro do plaintext cifrado, ao lado do corpo. Isso é
//! circular: `crypto::ratchet::RatchetState::receiving_key` precisa de
//! `header.dh_pub` **antes** de conseguir derivar a chave de mensagem — no
//! caso de troca de cadeia DH, o passo `ratchet_dh_step` calcula
//! `dh_self_current.agree(dh_remote_new)` onde `dh_remote_new` É esse
//! `dh_pub`. Não existe ordem de operações em que decifrar primeiro revela o
//! valor que a própria decifragem precisa como entrada.
//!
//! A correção, decisão de projeto registrada em D14: mover `dh_pub` para o
//! cabeçalho em claro, ao lado do contador, e incluí-lo no AAD — o mesmo
//! padrão do Double Ratchet do Signal. Isso expõe só uma chave X25519
//! **efêmera** do ratchet, trocada a cada poucas mensagens, nunca a
//! identidade de longo prazo (`IK_dh`) — um vazamento estritamente menor do
//! que os já aceitos e documentados em D12 (IP real do par, exposto pela
//! própria natureza de uma conexão P2P direta).

use crate::crypto::aead::TAG_LEN;
use crate::crypto::dh::{DhPublic, KEY_LEN as DH_PUB_LEN};
use crate::util::encoding::read_u32;
use crate::{Error, Result};

/// Tamanho do contador em claro no início do envelope.
pub const COUNTER_LEN: usize = 4;

/// Tamanho do cabeçalho em claro inteiro: contador seguido do `dh_pub`.
const HEADER_LEN: usize = COUNTER_LEN + DH_PUB_LEN;

/// Monta o envelope a partir do contador, do `dh_pub` do emissor (§6.1,
/// `RatchetHeader.dh_pub`) e de um ciphertext já selado (`ciphertext ‖ tag`,
/// como `crypto::aead::seal` o produz).
pub fn encode(counter: u32, dh_pub: &DhPublic, sealed: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER_LEN + sealed.len());
    out.extend_from_slice(&counter.to_be_bytes());
    out.extend_from_slice(dh_pub.as_bytes());
    out.extend_from_slice(sealed);
    out
}

/// Desmonta um envelope: devolve o contador e o `dh_pub` em claro, e a fatia
/// `ciphertext ‖ tag` que segue, pronta para `crypto::aead::open`.
///
/// Só valida que há bytes suficientes para conter o cabeçalho e uma tag — não
/// há como validar mais do que isso sem a chave, e é exatamente por isso que
/// esta camada não tenta: qualquer coisa além de comprimento é trabalho do
/// AEAD. Em particular, um `dh_pub` de ordem baixa não é rejeitado aqui — só
/// tem comprimento fixo verificado; a rejeição acontece em `DhSecret::agree`,
/// do lado de quem de fato usa esse valor num acordo DH.
pub fn decode(envelope: &[u8]) -> Result<(u32, DhPublic, &[u8])> {
    if envelope.len() < HEADER_LEN + TAG_LEN {
        return Err(Error::Malformed(
            "envelope curto demais para conter cabeçalho e tag",
        ));
    }
    let counter = read_u32(envelope).expect("comprimento mínimo checado acima");
    let dh_pub = DhPublic::from_slice(&envelope[COUNTER_LEN..HEADER_LEN])
        .expect("comprimento mínimo checado acima garante os 32 bytes de dh_pub");
    Ok((counter, dh_pub, &envelope[HEADER_LEN..]))
}

/// Bytes de AAD que a camada de sessão deve passar ao AEAD: o contador e o
/// `dh_pub` em claro, exatamente como aparecem no envelope.
///
/// Exposto como função em vez de deixar cada chamador reconstruir esses bytes
/// por conta própria — essa convenção (o AAD é literalmente o cabeçalho em
/// claro do envelope) é normativa, não um detalhe de implementação.
pub fn aad(counter: u32, dh_pub: &DhPublic) -> [u8; HEADER_LEN] {
    let mut out = [0u8; HEADER_LEN];
    out[..COUNTER_LEN].copy_from_slice(&counter.to_be_bytes());
    out[COUNTER_LEN..].copy_from_slice(dh_pub.as_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dh_pub_de_teste(byte: u8) -> DhPublic {
        DhPublic::from_bytes([byte; DH_PUB_LEN])
    }

    #[test]
    fn roundtrip() {
        let sealed = vec![0xAAu8; 100 + TAG_LEN];
        let dh_pub = dh_pub_de_teste(0x11);
        let envelope = encode(42, &dh_pub, &sealed);

        let (counter, decoded_dh_pub, rest) = decode(&envelope).unwrap();
        assert_eq!(counter, 42);
        assert_eq!(decoded_dh_pub, dh_pub);
        assert_eq!(rest, sealed.as_slice());
    }

    #[test]
    fn aad_is_counter_followed_by_dh_pub() {
        let dh_pub = dh_pub_de_teste(0xAB);
        let bytes = aad(0x0102_0304, &dh_pub);

        assert_eq!(&bytes[..COUNTER_LEN], &[0x01, 0x02, 0x03, 0x04]);
        assert_eq!(&bytes[COUNTER_LEN..], dh_pub.as_bytes().as_slice());
    }

    #[test]
    fn rejects_too_short_envelope_without_panic() {
        for len in 0..(HEADER_LEN + TAG_LEN) {
            let curto = vec![0u8; len];
            assert!(matches!(decode(&curto), Err(Error::Malformed(_))));
        }
    }

    #[test]
    fn decode_never_panics_on_arbitrary_bytes() {
        // Não é o property test formal do módulo (esse vive em plaintext.rs),
        // mas o envelope também processa bytes de um par não confiável antes
        // de qualquer verificação criptográfica, e merece a mesma garantia.
        for len in 0..128 {
            let bytes = vec![0x5Au8; len];
            let _ = decode(&bytes);
        }
    }
}
