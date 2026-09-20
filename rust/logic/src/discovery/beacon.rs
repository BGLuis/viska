//! `BeaconID` rotativo por época — `docs/protocol.md` §9.1.
//!
//! ```text
//! epoch  = floor(unix_time / 3600)
//! beacon = BLAKE3_keyed(K_sig, "viska-beacon-v1" ‖ u64_be(epoch))[0..16]
//! ```
//!
//! `K_sig` é o mesmo segredo usado para os tópicos de sinalização
//! (`signaling::signaling_key`) — um DH estático entre as duas identidades de
//! longo prazo, recalculável por qualquer lado sem round-trip. Ao contrário
//! de `topic_hex`, o beacon não distingue direção: os dois lados calculam
//! exatamente o mesmo valor, porque os 16 bytes viram um único UUID de
//! serviço BLE (ou nome de instância mDNS) que qualquer um dos dois pode
//! anunciar ou procurar.

use crate::crypto::kdf::{self, Key};
use crate::util::time::epoch_window;

/// Tamanho do `BeaconID` — cabe exatamente num UUID de serviço BLE de 128
/// bits (`docs/protocol.md` §9.1).
pub const BEACON_LEN: usize = 16;

/// `BeaconID` para uma época específica.
pub fn beacon_id(k_sig: &Key, epoch: u64) -> [u8; BEACON_LEN] {
    let mut material = Vec::with_capacity(kdf::context::BEACON.len() + 8);
    material.extend_from_slice(kdf::context::BEACON.as_bytes());
    material.extend_from_slice(&epoch.to_be_bytes());

    let full = kdf::keyed(k_sig, &material);
    let mut beacon = [0u8; BEACON_LEN];
    beacon.copy_from_slice(&full[..BEACON_LEN]);
    beacon
}

/// Os três `BeaconID`s aceitáveis agora — época anterior, atual e seguinte —
/// para tolerar desvio de relógio entre os aparelhos.
pub fn beacon_ids_for_window(k_sig: &Key) -> [[u8; BEACON_LEN]; 3] {
    epoch_window().map(|epoch| beacon_id(k_sig, epoch))
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
    use crate::signaling::signaling_key;

    fn shared_k_sig() -> (Key, Key) {
        let alice = LocalIdentity::generate().unwrap();
        let bob = LocalIdentity::generate().unwrap();
        let k_alice = signaling_key(&alice, &bob.public()).unwrap();
        let k_bob = signaling_key(&bob, &alice.public()).unwrap();
        (k_alice, k_bob)
    }

    #[test]
    fn beacon_id_e_identico_nos_dois_lados_na_mesma_epoca() {
        let (k_alice, k_bob) = shared_k_sig();
        assert_eq!(beacon_id(&k_alice, 123_456), beacon_id(&k_bob, 123_456));
    }

    #[test]
    fn beacon_id_muda_entre_epocas_adjacentes() {
        let (k_sig, _) = shared_k_sig();
        assert_ne!(beacon_id(&k_sig, 1000), beacon_id(&k_sig, 1001));
    }

    #[test]
    fn quem_nao_compartilha_k_sig_produz_beacon_diferente() {
        let (k_sig, _) = shared_k_sig();
        let alice = LocalIdentity::generate().unwrap();
        let mallory = LocalIdentity::generate().unwrap();
        let k_estranho = signaling_key(&alice, &mallory.public()).unwrap();

        assert_ne!(beacon_id(&k_sig, 1000), beacon_id(&k_estranho, 1000));
    }

    #[test]
    fn beacon_ids_for_window_cobre_epoca_anterior_atual_e_seguinte() {
        let (k_sig, _) = shared_k_sig();
        let now = crate::util::time::current_epoch();

        let janela = beacon_ids_for_window(&k_sig);

        assert_eq!(
            janela,
            [
                beacon_id(&k_sig, now - 1),
                beacon_id(&k_sig, now),
                beacon_id(&k_sig, now + 1),
            ]
        );
    }

    #[test]
    fn instance_name_hex_e_hexadecimal_minusculo_de_16_bytes() {
        let (k_sig, _) = shared_k_sig();
        let beacon = beacon_id(&k_sig, 42);

        let hex_name = instance_name_hex(&beacon);

        assert_eq!(hex_name.len(), BEACON_LEN * 2);
        assert!(hex_name.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    }
}
