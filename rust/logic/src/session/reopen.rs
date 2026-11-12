//! Sinal `REOPEN` — `docs/protocol.md` §11.4, D27.
//!
//! O respondedor que reabre a sessão não tem o que mandar: a INIT é do
//! iniciador (§4). Este pacote é o pedido para o iniciador abrir uma sessão
//! nova. Precisa de três propriedades ao mesmo tempo:
//!
//! - **Não ter marcador em claro (D4).** Tem o tamanho de um envelope do
//!   bucket menor (1076 B) e é inteiro saída de XChaCha20-Poly1305: nonce
//!   aleatório, ciphertext e tag, sem nenhum byte previsível.
//! - **Ser deniável.** A chave vem do DH estático entre as duas `IK_dh`, que
//!   os dois lados conhecem, então qualquer um deles poderia ter produzido o
//!   pacote. Nenhuma assinatura.
//! - **Não poder ser repetido para sempre.** Um carimbo de tempo cifrado, com
//!   a mesma janela de §8.2, e o nonce de cada sinal aceito guardado em
//!   memória enquanto a janela dura. A direção entra no AAD para que o sinal
//!   de um lado não seja refletido de volta a ele mesmo.
//!
//! Repetir um sinal válido dentro da janela, antes de o guarda vê-lo, custa
//! no máximo um handshake: a sessão viva nunca é derrubada por ele (§11.4).

use crate::crypto::aead::{self, TAG_LEN, XNONCE_LEN};
use crate::crypto::dh::KEY_LEN as DH_PUB_LEN;
use crate::crypto::identity::{LocalIdentity, PublicIdentity};
use crate::crypto::kdf::{self, Key};
use crate::signaling::payload::{ACCEPTANCE_WINDOW_FUTURE_SECS, ACCEPTANCE_WINDOW_PAST_SECS};
use crate::signaling::Direction;
use crate::wire::envelope::COUNTER_LEN;
use crate::wire::transport::Transport;
use crate::{Error, Result};

/// Tamanho do sinal no fio: o de um envelope do bucket menor.
pub const REOPEN_LEN: usize = 1076;

// O tamanho só esconde o sinal se for exatamente o de um envelope do bucket
// menor, nos dois transportes (D23 põe a LAN nos mesmos buckets de sessão).
const _: () = assert!(
    REOPEN_LEN == COUNTER_LEN + DH_PUB_LEN + Transport::DataChannel.buckets()[0] + TAG_LEN
);
const _: () = assert!(Transport::DataChannel.buckets()[0] == Transport::LocalSocket.buckets()[0]);

const TIMESTAMP_LEN: usize = 8;
const PLAINTEXT_LEN: usize = REOPEN_LEN - XNONCE_LEN - TAG_LEN;
const _: () = assert!(PLAINTEXT_LEN == 1036);
const _: () = assert!(PLAINTEXT_LEN > TIMESTAMP_LEN);

/// Prefixo do AAD, literal e versionado.
const AAD_CONTEXT: &[u8] = b"viska-reopen-v1";

/// Teto de nonces guardados. Só o par (ou quem repete um sinal dele) produz
/// sinal válido, e a janela é de 3 minutos: passar disso é inundação, e a
/// resposta segura é recusar até a janela esvaziar.
const MAX_SEEN: usize = 64;

/// `K_reopen` — `derive_key("viska-reopen-v1", X25519(IK_dh_local, IK_dh_peer))`.
pub fn reopen_key(local: &LocalIdentity, peer: &PublicIdentity) -> Result<Key> {
    let shared = local.dh().agree(&peer.dh)?;
    Ok(kdf::derive(kdf::context::REOPEN, shared.as_bytes()))
}

fn aad(dir: Direction) -> Vec<u8> {
    let mut out = Vec::with_capacity(AAD_CONTEXT.len() + 3);
    out.extend_from_slice(AAD_CONTEXT);
    out.extend_from_slice(dir.as_bytes());
    out
}

/// Sela um sinal na direção `dir` (a do emissor), carimbado com `now`.
pub fn seal_at(key: &Key, dir: Direction, now: u64) -> Result<Vec<u8>> {
    let mut buffer = vec![0u8; PLAINTEXT_LEN];
    buffer[..TIMESTAMP_LEN].copy_from_slice(&now.to_be_bytes());
    // O resto é padding: CSPRNG, nunca zeros, para o plaintext não ter estrutura.
    crate::util::rng::fill(&mut buffer[TIMESTAMP_LEN..])?;
    aead::seal_xchacha(key, &aad(dir), &mut buffer)?;
    debug_assert_eq!(buffer.len(), REOPEN_LEN);
    Ok(buffer)
}

/// Abre um sinal recebido na direção `dir` (a do emissor) e devolve o nonce,
/// para o guarda de repetição.
///
/// Toda falha é `Error::AeadFailure`, inclusive tamanho errado e carimbo fora
/// da janela: o chamador não pode distinguir as causas (CLAUDE.md).
pub fn open_at(key: &Key, dir: Direction, now: u64, bytes: &[u8]) -> Result<[u8; XNONCE_LEN]> {
    if bytes.len() != REOPEN_LEN {
        return Err(Error::AeadFailure);
    }
    let nonce: [u8; XNONCE_LEN] = bytes
        .get(..XNONCE_LEN)
        .and_then(|b| b.try_into().ok())
        .ok_or(Error::AeadFailure)?;

    let mut buffer = bytes.to_vec();
    aead::open_xchacha(key, &aad(dir), &mut buffer)?;
    let timestamp = buffer
        .get(..TIMESTAMP_LEN)
        .and_then(|b| <[u8; TIMESTAMP_LEN]>::try_from(b).ok())
        .map(u64::from_be_bytes)
        .ok_or(Error::AeadFailure)?;
    if timestamp.saturating_add(ACCEPTANCE_WINDOW_PAST_SECS) < now
        || timestamp > now.saturating_add(ACCEPTANCE_WINDOW_FUTURE_SECS)
    {
        return Err(Error::AeadFailure);
    }
    Ok(nonce)
}

/// Nonces de sinais já aceitos, com o instante em que foram vistos.
///
/// Só em memória: um reinício esquece tudo, e o pior que um sinal repetido
/// depois disso consegue é um handshake a mais.
#[derive(Debug, Default)]
pub(crate) struct ReplayGuard {
    seen: Vec<([u8; XNONCE_LEN], u64)>,
}

impl ReplayGuard {
    /// `true` se o nonce é novo (e passa a ser lembrado); `false` se repete um
    /// já visto ou se o guarda está cheio.
    pub(crate) fn admit(&mut self, nonce: [u8; XNONCE_LEN], now: u64) -> bool {
        // Um sinal só é aceito até `PAST + FUTURE` segundos depois de quando
        // foi carimbado; depois disso a janela já o recusa sozinha.
        let horizon = ACCEPTANCE_WINDOW_PAST_SECS + ACCEPTANCE_WINDOW_FUTURE_SECS;
        self.seen.retain(|(_, at)| at.saturating_add(horizon) >= now);
        if self.seen.iter().any(|(seen, _)| *seen == nonce) || self.seen.len() >= MAX_SEEN {
            return false;
        }
        self.seen.push((nonce, now));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> Key {
        Key::from_bytes([0x5Au8; 32])
    }

    #[test]
    fn roundtrip_has_envelope_size() {
        let sealed = seal_at(&key(), Direction::B2A, 1_000).unwrap();
        assert_eq!(sealed.len(), REOPEN_LEN);
        assert!(open_at(&key(), Direction::B2A, 1_000, &sealed).is_ok());
    }

    #[test]
    fn two_signals_share_no_bytes_in_place() {
        // Nenhum byte fixo entre dois sinais: nada para DPI casar.
        let a = seal_at(&key(), Direction::B2A, 1_000).unwrap();
        let b = seal_at(&key(), Direction::B2A, 1_000).unwrap();
        let equal = a.iter().zip(&b).filter(|(x, y)| x == y).count();
        assert!(equal < 32, "{equal} bytes coincidem na mesma posição");
    }

    #[test]
    fn rejects_wrong_direction() {
        let sealed = seal_at(&key(), Direction::B2A, 1_000).unwrap();
        assert!(matches!(
            open_at(&key(), Direction::A2B, 1_000, &sealed),
            Err(Error::AeadFailure)
        ));
    }

    #[test]
    fn rejects_wrong_key() {
        let sealed = seal_at(&key(), Direction::B2A, 1_000).unwrap();
        let other = Key::from_bytes([0x5Bu8; 32]);
        assert!(open_at(&other, Direction::B2A, 1_000, &sealed).is_err());
    }

    #[test]
    fn rejects_timestamp_outside_window() {
        let sealed = seal_at(&key(), Direction::B2A, 1_000).unwrap();
        let late = 1_000 + ACCEPTANCE_WINDOW_PAST_SECS + 1;
        let early = 1_000 - ACCEPTANCE_WINDOW_FUTURE_SECS - 1;
        assert!(open_at(&key(), Direction::B2A, late, &sealed).is_err());
        assert!(open_at(&key(), Direction::B2A, early, &sealed).is_err());
        assert!(open_at(&key(), Direction::B2A, 1_000 + ACCEPTANCE_WINDOW_PAST_SECS, &sealed).is_ok());
    }

    #[test]
    fn rejects_wrong_length() {
        let sealed = seal_at(&key(), Direction::B2A, 1_000).unwrap();
        assert!(open_at(&key(), Direction::B2A, 1_000, &sealed[..REOPEN_LEN - 1]).is_err());
        let mut longer = sealed.clone();
        longer.push(0);
        assert!(open_at(&key(), Direction::B2A, 1_000, &longer).is_err());
        assert!(open_at(&key(), Direction::B2A, 1_000, &[]).is_err());
    }

    #[test]
    fn rejects_every_single_bit_flip() {
        let sealed = seal_at(&key(), Direction::B2A, 1_000).unwrap();
        for byte in 0..REOPEN_LEN {
            for bit in 0..8 {
                let mut tampered = sealed.clone();
                tampered[byte] ^= 1 << bit;
                assert!(
                    matches!(open_at(&key(), Direction::B2A, 1_000, &tampered), Err(Error::AeadFailure)),
                    "byte {byte} bit {bit} passou"
                );
            }
        }
    }

    #[test]
    fn replay_guard_rejects_repeat_and_forgets_after_window() {
        let mut guard = ReplayGuard::default();
        let nonce = [7u8; XNONCE_LEN];
        assert!(guard.admit(nonce, 1_000));
        assert!(!guard.admit(nonce, 1_010));
        let after = 1_000 + ACCEPTANCE_WINDOW_PAST_SECS + ACCEPTANCE_WINDOW_FUTURE_SECS + 1;
        assert!(guard.admit(nonce, after));
    }

    #[test]
    fn replay_guard_fails_closed_when_full() {
        let mut guard = ReplayGuard::default();
        for i in 0..MAX_SEEN {
            let mut nonce = [0u8; XNONCE_LEN];
            nonce[0] = i as u8;
            assert!(guard.admit(nonce, 1_000));
        }
        assert!(!guard.admit([0xFFu8; XNONCE_LEN], 1_000));
    }
}
