//! `BeaconID` e `PreambleID` rotativos por época — `docs/protocol.md` §9.1 e §9.3.
//!
//! ```text
//! epoch    = floor(unix_time / 3600)
//! beacon   = BLAKE3_keyed(K_sig, "viska-beacon-v1" ‖ dir ‖ u64_be(epoch))[0..16]
//! preamble = BLAKE3_keyed(K_sig, "viska-preamble-v1" ‖ dir ‖ u64_be(epoch))[0..16]
//! ```
//!
//! `K_sig` é o mesmo segredo usado para os tópicos de sinalização
//! (`signaling::signaling_key`) — um DH estático entre as duas identidades de
//! longo prazo, recalculável por qualquer lado sem round-trip. Tanto o beacon
//! quanto o preâmbulo são direcionais (`a2b`/`b2a`), como `topic_hex`: os dois lados
//! calculam valores diferentes para evitar que um observador passivo ligue os dois
//! aparelhos anunciando ou conectando simultaneamente (S-10).

use crate::crypto::kdf::{self, Key};
use crate::signaling::Direction;
use crate::util::time::epoch_window;

/// Tamanho do `BeaconID` — cabe exatamente num UUID de serviço BLE de 128
/// bits (`docs/protocol.md` §9.1).
pub const BEACON_LEN: usize = 16;

/// Tamanho do `PreambleID` para o preâmbulo TCP (§9.3).
pub const PREAMBLE_LEN: usize = 16;

/// `BeaconID` para uma direção e época específicas.
pub fn beacon_id(k_sig: &Key, dir: Direction, epoch: u64) -> [u8; BEACON_LEN] {
    let mut material = Vec::with_capacity(kdf::context::BEACON.len() + 3 + 8);
    material.extend_from_slice(kdf::context::BEACON.as_bytes());
    material.extend_from_slice(dir.as_bytes());
    material.extend_from_slice(&epoch.to_be_bytes());

    let full = kdf::keyed(k_sig, &material);
    let mut beacon = [0u8; BEACON_LEN];
    beacon.copy_from_slice(&full[..BEACON_LEN]);
    beacon
}

/// Os três `BeaconID`s aceitáveis na janela de épocas — anterior, atual e seguinte —
/// para a direção especificada.
pub fn beacon_ids_for_window(k_sig: &Key, dir: Direction) -> [[u8; BEACON_LEN]; 3] {
    epoch_window().map(|epoch| beacon_id(k_sig, dir, epoch))
}

/// `PreambleID` para uma direção e época específicas.
pub fn preamble_id(k_sig: &Key, dir: Direction, epoch: u64) -> [u8; PREAMBLE_LEN] {
    let mut material = Vec::with_capacity(kdf::context::PREAMBLE.len() + 3 + 8);
    material.extend_from_slice(kdf::context::PREAMBLE.as_bytes());
    material.extend_from_slice(dir.as_bytes());
    material.extend_from_slice(&epoch.to_be_bytes());

    let full = kdf::keyed(k_sig, &material);
    let mut id = [0u8; PREAMBLE_LEN];
    id.copy_from_slice(&full[..PREAMBLE_LEN]);
    id
}

/// Os três `PreambleID`s aceitáveis na janela de épocas para a direção especificada.
pub fn preamble_ids_for_window(k_sig: &Key, dir: Direction) -> [[u8; PREAMBLE_LEN]; 3] {
    epoch_window().map(|epoch| preamble_id(k_sig, dir, epoch))
}

/// Nome de instância mDNS/DNS-SD: o `BeaconID` em hexadecimal minúsculo —
/// `docs/protocol.md` §9.2.
pub fn instance_name_hex(beacon: &[u8; BEACON_LEN]) -> String {
    hex::encode(beacon)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::identity::LocalIdentity;
    use crate::signaling::{signaling_key, topic::direction};

    fn shared_k_sig() -> (Key, Key) {
        let alice = LocalIdentity::generate().unwrap();
        let bob = LocalIdentity::generate().unwrap();
        let k_alice = signaling_key(&alice, &bob.public()).unwrap();
        let k_bob = signaling_key(&bob, &alice.public()).unwrap();
        (k_alice, k_bob)
    }

    #[test]
    fn beacons_of_a_and_b_for_same_pair_are_different() {
        let (k_alice, k_bob) = shared_k_sig();
        assert_ne!(
            beacon_id(&k_alice, Direction::A2B, 123_456),
            beacon_id(&k_bob, Direction::B2A, 123_456)
        );
    }

    #[test]
    fn scan_beacons_matches_peer_advertised_beacon() {
        let (k_alice, k_bob) = shared_k_sig();
        let now = crate::util::time::current_epoch();
        let adv_a = beacon_id(&k_alice, Direction::A2B, now);
        let scan_b = beacon_ids_for_window(&k_bob, Direction::A2B);
        assert!(scan_b.contains(&adv_a));
    }

    #[test]
    fn beacon_id_changes_between_adjacent_epochs() {
        let (k_sig, _) = shared_k_sig();
        assert_ne!(
            beacon_id(&k_sig, Direction::A2B, 1000),
            beacon_id(&k_sig, Direction::A2B, 1001)
        );
    }

    #[test]
    fn preamble_id_differs_between_two_epochs() {
        let (k_sig, _) = shared_k_sig();
        assert_ne!(
            preamble_id(&k_sig, Direction::A2B, 1000),
            preamble_id(&k_sig, Direction::A2B, 1001)
        );
    }

    #[test]
    fn preamble_id_differs_between_two_contacts() {
        let alice = LocalIdentity::generate().unwrap();
        let bob = LocalIdentity::generate().unwrap();
        let charlie = LocalIdentity::generate().unwrap();

        let k_bob = signaling_key(&alice, &bob.public()).unwrap();
        let k_charlie = signaling_key(&alice, &charlie.public()).unwrap();

        let dir_b = direction(&alice.public(), &bob.public());
        let dir_c = direction(&alice.public(), &charlie.public());

        assert_ne!(
            preamble_id(&k_bob, dir_b, 1000),
            preamble_id(&k_charlie, dir_c, 1000)
        );
    }

    #[test]
    fn party_without_shared_k_sig_produces_different_beacon() {
        let (k_sig, _) = shared_k_sig();
        let alice = LocalIdentity::generate().unwrap();
        let mallory = LocalIdentity::generate().unwrap();
        let k_estranho = signaling_key(&alice, &mallory.public()).unwrap();

        assert_ne!(
            beacon_id(&k_sig, Direction::A2B, 1000),
            beacon_id(&k_estranho, Direction::A2B, 1000)
        );
    }

    #[test]
    fn beacon_ids_for_window_covers_previous_current_and_next_epoch() {
        let (k_sig, _) = shared_k_sig();
        let now = crate::util::time::current_epoch();

        let janela = beacon_ids_for_window(&k_sig, Direction::A2B);

        assert_eq!(
            janela,
            [
                beacon_id(&k_sig, Direction::A2B, now - 1),
                beacon_id(&k_sig, Direction::A2B, now),
                beacon_id(&k_sig, Direction::A2B, now + 1),
            ]
        );
    }

    #[test]
    fn instance_name_hex_is_lowercase_hex_of_16_bytes() {
        let (k_sig, _) = shared_k_sig();
        let beacon = beacon_id(&k_sig, Direction::A2B, 42);

        let hex_name = instance_name_hex(&beacon);

        assert_eq!(hex_name.len(), BEACON_LEN * 2);
        assert!(hex_name.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    }
}
