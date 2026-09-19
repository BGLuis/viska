//! Payload de sinalização (SDP, candidatos ICE) — `docs/protocol.md` §8.2.
//!
//! Cifra com XChaCha20-Poly1305 sob `K_sig`, preenchido até exatamente
//! 1024 bytes. Um único tamanho de bucket, ao contrário dos dois buckets do
//! envelope de mensagem (D5): aqui não há por que variar — o observador do
//! broker já vê volume e timing por fora, e a rotação de tópico (§8.1) é a
//! mitigação real contra correlação de longo prazo, não o tamanho do pacote.

use crate::crypto::aead;
use crate::crypto::kdf::Key;
use crate::util::encoding::read_u16;
use crate::{Error, Result};

/// Tamanho total do payload cifrado no fio — `docs/protocol.md` §8.2.
pub const SEALED_LEN: usize = 1024;

const LEN_PREFIX_LEN: usize = 2;
const PLAINTEXT_LEN: usize = SEALED_LEN - aead::XNONCE_LEN - aead::TAG_LEN;

/// Maior payload real que cabe depois do prefixo de comprimento.
pub const MAX_PAYLOAD_LEN: usize = PLAINTEXT_LEN - LEN_PREFIX_LEN;

/// Cifra `payload` (SDP ou candidato ICE já serializado) para publicação.
///
/// Erra com `Error::PayloadTooLarge` se não couber no único bucket da
/// sinalização — mesmo contrato de `wire::plaintext::encode`: os produtores
/// (SDP, candidatos) são dimensionados para caber por construção.
pub fn seal(k_sig: &Key, payload: &[u8]) -> Result<Vec<u8>> {
    if payload.len() > MAX_PAYLOAD_LEN {
        return Err(Error::PayloadTooLarge {
            max: MAX_PAYLOAD_LEN,
        });
    }

    let len_prefix = payload.len() as u16;
    let mut buffer = vec![0u8; PLAINTEXT_LEN];
    buffer[..LEN_PREFIX_LEN].copy_from_slice(&len_prefix.to_be_bytes());
    buffer[LEN_PREFIX_LEN..LEN_PREFIX_LEN + payload.len()].copy_from_slice(payload);
    // O restante já nasceu zerado pelo `vec![0u8; ..]` acima — sobrescreve com
    // padding CSPRNG, nunca zeros previsíveis (mesma razão de
    // `wire::plaintext::encode`: um padding sempre-zero é uma marca que
    // sobrevive a qualquer vazamento futuro de estrutura do ciphertext).
    crate::util::rng::fill(&mut buffer[LEN_PREFIX_LEN + payload.len()..])?;

    aead::seal_xchacha(k_sig, b"", &mut buffer)?;
    debug_assert_eq!(buffer.len(), SEALED_LEN, "seal_xchacha deveria produzir nonce+PLAINTEXT_LEN+tag");
    Ok(buffer)
}

/// Decifra um payload de sinalização recebido do broker.
///
/// `bytes` vem de um broker público não confiável (§1, `docs/threat-model.md`):
/// comprimento errado ou falha do AEAD viram `Error::AeadFailure` sem
/// distinguir a causa, a mesma regra de `crypto::aead`, para não abrir
/// oráculo. Um prefixo de comprimento inconsistente *depois* do AEAD já ter
/// autenticado o buffer é tratado como `Error::Malformed` — nesse ponto a
/// mensagem já provou vir de quem tem `K_sig`, então a causa mais provável é
/// um bug ou uma versão de protocolo incompatível, não um ataque; ver a
/// mesma distinção em `session::try_decrypt`.
pub fn open(k_sig: &Key, bytes: &[u8]) -> Result<Vec<u8>> {
    if bytes.len() != SEALED_LEN {
        return Err(Error::AeadFailure);
    }

    let mut buffer = bytes.to_vec();
    aead::open_xchacha(k_sig, b"", &mut buffer)?;

    let real_len = read_u16(&buffer)
        .ok_or(Error::Malformed("prefixo de comprimento ausente no payload decifrado"))?
        as usize;
    let end = LEN_PREFIX_LEN
        .checked_add(real_len)
        .ok_or(Error::Malformed("overflow calculando o fim do payload"))?;

    buffer
        .get(LEN_PREFIX_LEN..end)
        .map(<[u8]>::to_vec)
        .ok_or(Error::Malformed(
            "comprimento declarado maior que o payload decifrado",
        ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chave_de_teste() -> Key {
        Key::from_bytes([0x42u8; 32])
    }

    #[test]
    fn ida_e_volta() {
        let k_sig = chave_de_teste();
        let payload = b"v=0\r\no=- 46117317 2 IN IP4 127.0.0.1\r\n...".to_vec();

        let sealed = seal(&k_sig, &payload).unwrap();
        assert_eq!(sealed.len(), SEALED_LEN);

        let opened = open(&k_sig, &sealed).unwrap();
        assert_eq!(opened, payload);
    }

    #[test]
    fn payload_vazio_e_aceito_e_decifra_vazio() {
        let k_sig = chave_de_teste();
        let sealed = seal(&k_sig, b"").unwrap();
        assert_eq!(open(&k_sig, &sealed).unwrap(), Vec::<u8>::new());
    }

    #[test]
    fn sempre_produz_exatamente_1024_bytes_qualquer_que_seja_o_tamanho_do_payload() {
        let k_sig = chave_de_teste();
        for len in [0, 1, 50, MAX_PAYLOAD_LEN] {
            let payload = vec![0xABu8; len];
            let sealed = seal(&k_sig, &payload).unwrap();
            assert_eq!(sealed.len(), SEALED_LEN, "tamanho errado para payload de {len} bytes");
        }
    }

    #[test]
    fn payload_maior_que_o_maximo_e_rejeitado() {
        let k_sig = chave_de_teste();
        let grande = vec![0u8; MAX_PAYLOAD_LEN + 1];
        assert!(matches!(
            seal(&k_sig, &grande),
            Err(Error::PayloadTooLarge { max }) if max == MAX_PAYLOAD_LEN
        ));
    }

    #[test]
    fn duas_cifragens_do_mesmo_payload_produzem_bytes_diferentes() {
        let k_sig = chave_de_teste();
        let payload = b"mesmo payload, duas cifragens".to_vec();

        let a = seal(&k_sig, &payload).unwrap();
        let b = seal(&k_sig, &payload).unwrap();

        // Nonce aleatório (XChaCha) garante isso mesmo com padding igual em
        // tamanho — e os dois ainda decifram para o mesmo payload.
        assert_ne!(a, b);
        assert_eq!(open(&k_sig, &a).unwrap(), payload);
        assert_eq!(open(&k_sig, &b).unwrap(), payload);
    }

    #[test]
    fn open_rejeita_chave_errada() {
        let k_sig = chave_de_teste();
        let outra_chave = Key::from_bytes([0x99u8; 32]);
        let sealed = seal(&k_sig, b"segredo").unwrap();

        assert!(matches!(
            open(&outra_chave, &sealed),
            Err(Error::AeadFailure)
        ));
    }

    #[test]
    fn open_rejeita_comprimento_errado_sem_panico() {
        let k_sig = chave_de_teste();
        for len in [0, 1, SEALED_LEN - 1, SEALED_LEN + 1] {
            assert!(matches!(
                open(&k_sig, &vec![0u8; len]),
                Err(Error::AeadFailure)
            ));
        }
    }

    #[test]
    fn open_nunca_panica_em_bytes_arbitrarios_do_tamanho_certo() {
        let k_sig = chave_de_teste();
        // Bytes aleatórios do tamanho exato quase certamente falham a
        // autenticação do AEAD — o que importa é que `open` sempre devolve
        // `Err`, nunca panica, processando entrada de um broker não confiável.
        for seed in 0..64u8 {
            let bytes = vec![seed; SEALED_LEN];
            let _ = open(&k_sig, &bytes);
        }
    }
}
