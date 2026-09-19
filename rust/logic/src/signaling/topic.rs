//! Tópicos de sinalização — `docs/protocol.md` §8.1 (D8).
//!
//! ```text
//! K_sig = derive_key("viska-signaling-v1", K_root_da_sessão_pareada)
//! epoch = floor(unix_time / 3600)
//! topic(dir, epoch) = hex(BLAKE3_keyed(K_sig, "viska-sig-v1" ‖ dir ‖ u64_be(epoch)))
//! ```
//!
//! `K_root_da_sessão_pareada` é o DH estático `X25519(IK_dh_local, IK_dh_peer)`
//! — qualquer um dos dois lados recalcula sozinho, a qualquer momento, sem
//! round-trip. `dir` é fixado pela mesma ordem lexicográfica de `IK_dh` usada
//! para o papel do handshake (§4, `PublicIdentity::is_before`), então os dois
//! lados sempre concordam sobre quem publica em qual tópico sem negociar
//! nada.

use crate::crypto::identity::{LocalIdentity, PublicIdentity};
use crate::crypto::kdf::{self, Key};
use crate::util::time::epoch_window;
use crate::Result;

/// Prefixo de domínio do tópico, literal e versionado — `docs/protocol.md` §8.1.
const TOPIC_CONTEXT: &[u8] = b"viska-sig-v1";

/// Direção do tópico — quem publica em qual.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    A2B,
    B2A,
}

impl Direction {
    fn as_bytes(self) -> &'static [u8] {
        match self {
            Direction::A2B => b"a2b",
            Direction::B2A => b"b2a",
        }
    }

    /// A direção do outro lado — quem publica em `a2b` assina `b2a` para
    /// ouvir o par, e vice-versa.
    pub fn flip(self) -> Direction {
        match self {
            Direction::A2B => Direction::B2A,
            Direction::B2A => Direction::A2B,
        }
    }
}

/// Deriva `K_sig` a partir do DH estático entre as duas identidades de longo
/// prazo — recalculável por qualquer um dos dois lados, a qualquer momento,
/// sem handshake. Domínio de KDF próprio (`SIGNALING`), separado do domínio
/// do handshake (`HANDSHAKE`), então os dois nunca colidem mesmo compartilhando
/// o mesmo material de entrada (o segredo DH entre as mesmas duas `IK_dh`
/// nunca é, sozinho, o segredo de handshake — esse usa três DHs efêmeros
/// distintos, ver §4.3).
pub fn signaling_key(local: &LocalIdentity, peer: &PublicIdentity) -> Result<Key> {
    let shared = local.dh().agree(&peer.dh)?;
    Ok(kdf::derive(kdf::context::SIGNALING, shared.as_bytes()))
}

/// Direção deste lado para `peer`: `A2B` se formos o lado lexicograficamente
/// menor, `B2A` caso contrário — mesma regra de `PublicIdentity::is_before`.
pub fn direction(local: &PublicIdentity, peer: &PublicIdentity) -> Direction {
    if local.is_before(peer) {
        Direction::A2B
    } else {
        Direction::B2A
    }
}

/// Tópico para uma direção e época específicas.
pub fn topic_hex(k_sig: &Key, dir: Direction, epoch: u64) -> String {
    let mut material = Vec::with_capacity(TOPIC_CONTEXT.len() + 3 + 8);
    material.extend_from_slice(TOPIC_CONTEXT);
    material.extend_from_slice(dir.as_bytes());
    material.extend_from_slice(&epoch.to_be_bytes());

    hex::encode(kdf::keyed(k_sig, &material))
}

/// Os três tópicos aceitáveis agora — época anterior, atual e seguinte —
/// para tolerar desvio de relógio entre os aparelhos.
pub fn topics_for_window(k_sig: &Key, dir: Direction) -> [String; 3] {
    epoch_window().map(|epoch| topic_hex(k_sig, dir, epoch))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::identity::LocalIdentity;

    fn pair() -> (LocalIdentity, LocalIdentity) {
        (
            LocalIdentity::generate().unwrap(),
            LocalIdentity::generate().unwrap(),
        )
    }

    #[test]
    fn signaling_key_e_identica_nos_dois_lados() {
        let (alice, bob) = pair();

        let k_alice = signaling_key(&alice, &bob.public()).unwrap();
        let k_bob = signaling_key(&bob, &alice.public()).unwrap();

        assert_eq!(k_alice.as_bytes(), k_bob.as_bytes());
    }

    #[test]
    fn direcao_e_concordante_e_nunca_igual_nos_dois_lados() {
        let (alice, bob) = pair();

        let dir_alice = direction(&alice.public(), &bob.public());
        let dir_bob = direction(&bob.public(), &alice.public());

        assert_ne!(dir_alice, dir_bob);
        assert_eq!(dir_alice.flip(), dir_bob);
        assert_eq!(dir_bob.flip(), dir_alice);
    }

    #[test]
    fn topico_e_identico_nos_dois_lados_para_a_mesma_direcao_e_epoca() {
        let (alice, bob) = pair();
        let k_alice = signaling_key(&alice, &bob.public()).unwrap();
        let k_bob = signaling_key(&bob, &alice.public()).unwrap();

        // Alice, ao publicar na direção dela, produz o mesmo tópico que Bob
        // calcula ao assinar essa mesma direção — é isso que faz os dois se
        // encontrarem no broker sem trocar o tópico por fora.
        let dir_alice = direction(&alice.public(), &bob.public());
        let epoch = 123_456;
        assert_eq!(
            topic_hex(&k_alice, dir_alice, epoch),
            topic_hex(&k_bob, dir_alice, epoch)
        );
    }

    #[test]
    fn topico_muda_entre_epocas_adjacentes() {
        let alice = LocalIdentity::generate().unwrap();
        let bob = LocalIdentity::generate().unwrap();
        let k_sig = signaling_key(&alice, &bob.public()).unwrap();

        let t0 = topic_hex(&k_sig, Direction::A2B, 1000);
        let t1 = topic_hex(&k_sig, Direction::A2B, 1001);
        assert_ne!(t0, t1);
    }

    #[test]
    fn topico_muda_entre_direcoes_na_mesma_epoca() {
        let alice = LocalIdentity::generate().unwrap();
        let bob = LocalIdentity::generate().unwrap();
        let k_sig = signaling_key(&alice, &bob.public()).unwrap();

        assert_ne!(
            topic_hex(&k_sig, Direction::A2B, 1000),
            topic_hex(&k_sig, Direction::B2A, 1000)
        );
    }

    #[test]
    fn topics_for_window_cobre_epoca_anterior_atual_e_seguinte() {
        let alice = LocalIdentity::generate().unwrap();
        let bob = LocalIdentity::generate().unwrap();
        let k_sig = signaling_key(&alice, &bob.public()).unwrap();

        let now = crate::util::time::current_epoch();
        let janela = topics_for_window(&k_sig, Direction::A2B);

        assert_eq!(
            janela,
            [
                topic_hex(&k_sig, Direction::A2B, now - 1),
                topic_hex(&k_sig, Direction::A2B, now),
                topic_hex(&k_sig, Direction::A2B, now + 1),
            ]
        );
    }
}
