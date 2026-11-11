//! Payload de sinalização (SDP, candidatos ICE) — `docs/protocol.md` §8.2 (S-12).
//!
//! Cifra com XChaCha20-Poly1305 sob `K_sig`, preenchido até exatamente
//! 1024 bytes. O AAD amarra o selo ao contexto de domínio, à direção e à época
//! (`"viska-sig-v1" ‖ dir ‖ u64_be(epoch)`), impedindo repetição e reflexão
//! pelo broker hostil (§1.1, S-12). O plaintext inclui um carimbo de tempo
//! com janela de aceitação temporal para evitar reutilização de ofertas antigas.

use crate::crypto::aead;
use crate::crypto::kdf::Key;
use crate::util::encoding::read_u16;
use crate::{Error, Result};

use super::topic::{self, Direction};

/// Tamanho total do payload cifrado no fio — `docs/protocol.md` §8.2.
pub const SEALED_LEN: usize = 1024;

const TIMESTAMP_LEN: usize = 8;
const LEN_PREFIX_LEN: usize = 2;
const HEADER_LEN: usize = TIMESTAMP_LEN + LEN_PREFIX_LEN;
const PLAINTEXT_LEN: usize = SEALED_LEN - aead::XNONCE_LEN - aead::TAG_LEN;

/// Maior payload real que cabe depois do carimbo de tempo e do prefixo de comprimento.
pub const MAX_PAYLOAD_LEN: usize = PLAINTEXT_LEN - HEADER_LEN;

/// Janela de aceitação temporal (S-12): tolera até 120s no passado e 60s no futuro
/// para acomodar pequenos desvios de relógio entre os pares sem permitir reencenação.
pub const ACCEPTANCE_WINDOW_PAST_SECS: u64 = 120;
pub const ACCEPTANCE_WINDOW_FUTURE_SECS: u64 = 60;

/// Cifra `payload` (SDP ou candidato ICE já serializado) para publicação na direção e época especificadas.
///
/// O carimbo de tempo atual é incluído no início do plaintext e o material de tópico
/// é autenticado via AAD (S-12).
pub fn seal(k_sig: &Key, dir: Direction, epoch: u64, payload: &[u8]) -> Result<Vec<u8>> {
    seal_at(k_sig, dir, epoch, crate::util::time::unix_seconds(), payload)
}

/// Como [`seal`], permitindo especificar o carimbo de tempo para testes determinísticos.
pub fn seal_at(
    k_sig: &Key,
    dir: Direction,
    epoch: u64,
    timestamp: u64,
    payload: &[u8],
) -> Result<Vec<u8>> {
    if payload.len() > MAX_PAYLOAD_LEN {
        return Err(Error::PayloadTooLarge {
            max: MAX_PAYLOAD_LEN,
        });
    }

    let len_prefix = payload.len() as u16;
    let mut buffer = vec![0u8; PLAINTEXT_LEN];
    buffer[..TIMESTAMP_LEN].copy_from_slice(&timestamp.to_be_bytes());
    buffer[TIMESTAMP_LEN..HEADER_LEN].copy_from_slice(&len_prefix.to_be_bytes());
    buffer[HEADER_LEN..HEADER_LEN + payload.len()].copy_from_slice(payload);
    // O restante já nasceu zerado pelo `vec![0u8; ..]` acima — sobrescreve com
    // padding CSPRNG, nunca zeros previsíveis.
    crate::util::rng::fill(&mut buffer[HEADER_LEN + payload.len()..])?;

    let aad = topic::aad(dir, epoch);
    aead::seal_xchacha(k_sig, &aad, &mut buffer)?;
    debug_assert_eq!(buffer.len(), SEALED_LEN, "seal_xchacha deveria produzir nonce+PLAINTEXT_LEN+tag");
    Ok(buffer)
}

/// Decifra um payload de sinalização recebido do broker.
///
/// Valida direção e época através do AAD, e confere se o carimbo de tempo interno
/// cai dentro da janela de aceitação temporal (S-12).
pub fn open(k_sig: &Key, dir: Direction, epoch: u64, bytes: &[u8]) -> Result<Vec<u8>> {
    open_at(k_sig, dir, epoch, crate::util::time::unix_seconds(), bytes)
}

/// Como [`open`], permitindo especificar o instante de referência para validação temporal.
pub fn open_at(
    k_sig: &Key,
    dir: Direction,
    epoch: u64,
    now: u64,
    bytes: &[u8],
) -> Result<Vec<u8>> {
    if bytes.len() != SEALED_LEN {
        return Err(Error::AeadFailure);
    }

    let aad = topic::aad(dir, epoch);
    let mut buffer = bytes.to_vec();
    aead::open_xchacha(k_sig, &aad, &mut buffer)?;

    let timestamp_bytes = buffer
        .get(..TIMESTAMP_LEN)
        .ok_or(Error::AeadFailure)?;
    let timestamp = u64::from_be_bytes(
        timestamp_bytes
            .try_into()
            .map_err(|_| Error::AeadFailure)?,
    );

    // Validação da janela de aceitação temporal: carimbo muito velho ou muito no futuro
    // falha com Error::AeadFailure para não abrir oráculo.
    if timestamp.saturating_add(ACCEPTANCE_WINDOW_PAST_SECS) < now
        || timestamp > now.saturating_add(ACCEPTANCE_WINDOW_FUTURE_SECS)
    {
        return Err(Error::AeadFailure);
    }

    let len_bytes = buffer
        .get(TIMESTAMP_LEN..HEADER_LEN)
        .ok_or(Error::Malformed("prefixo de comprimento ausente no payload decifrado"))?;
    let real_len = read_u16(len_bytes)
        .ok_or(Error::Malformed("prefixo de comprimento ausente no payload decifrado"))?
        as usize;
    let end = HEADER_LEN
        .checked_add(real_len)
        .ok_or(Error::Malformed("overflow calculando o fim do payload"))?;

    buffer
        .get(HEADER_LEN..end)
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
    fn roundtrip() {
        let k_sig = chave_de_teste();
        let payload = b"v=0\r\no=- 46117317 2 IN IP4 127.0.0.1\r\n...".to_vec();

        let sealed = seal(&k_sig, Direction::A2B, 100, &payload).unwrap();
        assert_eq!(sealed.len(), SEALED_LEN);

        let opened = open(&k_sig, Direction::A2B, 100, &sealed).unwrap();
        assert_eq!(opened, payload);
    }

    #[test]
    fn empty_payload_is_accepted_and_decrypts_empty() {
        let k_sig = chave_de_teste();
        let sealed = seal(&k_sig, Direction::A2B, 100, b"").unwrap();
        assert_eq!(open(&k_sig, Direction::A2B, 100, &sealed).unwrap(), Vec::<u8>::new());
    }

    #[test]
    fn always_produces_exactly_1024_bytes_regardless_of_payload_size() {
        let k_sig = chave_de_teste();
        for len in [0, 1, 50, MAX_PAYLOAD_LEN] {
            let payload = vec![0xABu8; len];
            let sealed = seal(&k_sig, Direction::A2B, 100, &payload).unwrap();
            assert_eq!(sealed.len(), SEALED_LEN, "tamanho errado para payload de {len} bytes");
        }
    }

    #[test]
    fn payload_larger_than_maximum_is_rejected() {
        let k_sig = chave_de_teste();
        let grande = vec![0u8; MAX_PAYLOAD_LEN + 1];
        assert!(matches!(
            seal(&k_sig, Direction::A2B, 100, &grande),
            Err(Error::PayloadTooLarge { max }) if max == MAX_PAYLOAD_LEN
        ));
    }

    #[test]
    fn two_encryptions_of_same_payload_produce_different_bytes() {
        let k_sig = chave_de_teste();
        let payload = b"mesmo payload, duas cifragens".to_vec();

        let a = seal(&k_sig, Direction::A2B, 100, &payload).unwrap();
        let b = seal(&k_sig, Direction::A2B, 100, &payload).unwrap();

        assert_ne!(a, b);
        assert_eq!(open(&k_sig, Direction::A2B, 100, &a).unwrap(), payload);
        assert_eq!(open(&k_sig, Direction::A2B, 100, &b).unwrap(), payload);
    }

    #[test]
    fn open_rejects_wrong_key() {
        let k_sig = chave_de_teste();
        let outra_chave = Key::from_bytes([0x99u8; 32]);
        let sealed = seal(&k_sig, Direction::A2B, 100, b"segredo").unwrap();

        assert!(matches!(
            open(&outra_chave, Direction::A2B, 100, &sealed),
            Err(Error::AeadFailure)
        ));
    }

    #[test]
    fn open_rejects_swapped_direction_with_aead_failure() {
        let k_sig = chave_de_teste();
        let payload = b"oferta de sinalizacao".to_vec();
        let sealed = seal(&k_sig, Direction::A2B, 100, &payload).unwrap();

        let res = open(&k_sig, Direction::B2A, 100, &sealed);
        assert!(matches!(res, Err(Error::AeadFailure)));
    }

    #[test]
    fn open_rejects_swapped_epoch_with_aead_failure() {
        let k_sig = chave_de_teste();
        let payload = b"oferta de sinalizacao".to_vec();
        let sealed = seal(&k_sig, Direction::A2B, 100, &payload).unwrap();

        let res = open(&k_sig, Direction::A2B, 101, &sealed);
        assert!(matches!(res, Err(Error::AeadFailure)));
    }

    #[test]
    fn open_rejects_expired_timestamp_with_aead_failure() {
        let k_sig = chave_de_teste();
        let payload = b"oferta antiga".to_vec();
        let now = 1_000_000u64;
        let expired_time = now - ACCEPTANCE_WINDOW_PAST_SECS - 1;
        let sealed = seal_at(&k_sig, Direction::A2B, 100, expired_time, &payload).unwrap();

        let res = open_at(&k_sig, Direction::A2B, 100, now, &sealed);
        assert!(matches!(res, Err(Error::AeadFailure)));
    }

    #[test]
    fn open_rejects_future_timestamp_with_aead_failure() {
        let k_sig = chave_de_teste();
        let payload = b"oferta do futuro".to_vec();
        let now = 1_000_000u64;
        let future_time = now + ACCEPTANCE_WINDOW_FUTURE_SECS + 1;
        let sealed = seal_at(&k_sig, Direction::A2B, 100, future_time, &payload).unwrap();

        let res = open_at(&k_sig, Direction::A2B, 100, now, &sealed);
        assert!(matches!(res, Err(Error::AeadFailure)));
    }

    #[test]
    fn open_accepts_timestamp_within_window() {
        let k_sig = chave_de_teste();
        let payload = b"oferta valida".to_vec();
        let now = 1_000_000u64;
        let valid_time = now - 30;
        let sealed = seal_at(&k_sig, Direction::A2B, 100, valid_time, &payload).unwrap();

        let res = open_at(&k_sig, Direction::A2B, 100, now, &sealed).unwrap();
        assert_eq!(res, payload);
    }

    #[test]
    fn open_rejects_wrong_length_without_panic() {
        let k_sig = chave_de_teste();
        for len in [0, 1, SEALED_LEN - 1, SEALED_LEN + 1] {
            assert!(matches!(
                open(&k_sig, Direction::A2B, 100, &vec![0u8; len]),
                Err(Error::AeadFailure)
            ));
        }
    }

    #[test]
    fn open_never_panics_on_arbitrary_bytes_of_correct_size() {
        let k_sig = chave_de_teste();
        for seed in 0..64u8 {
            let bytes = vec![seed; SEALED_LEN];
            let _ = open(&k_sig, Direction::A2B, 100, &bytes);
        }
    }
}
