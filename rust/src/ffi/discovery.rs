//! Superfície FFI de descoberta local — `docs/protocol.md` §9 (Fase 6, F0).
//!
//! Só produz `BeaconID`s prontos para anunciar/procurar; não sabe nada de
//! BLE, mDNS/DNS-SD, Wi-Fi Aware ou qualquer rádio em si — isso fica na
//! camada Dart e nos canais de plataforma. `K_sig` nunca atravessa esta
//! fronteira: os beacons já não são segredo (vão para o ar de qualquer
//! forma), mas a chave que os deriva não tem por que sair de `viska_proto`.

use crate::ffi::core::Core;
use crate::ffi::error::FfiError;
use crate::ffi::types::{ContactDto, DiscoveryBeaconsDto};
use viska_proto::crypto::identity::DEVICE_ID_LEN;
use viska_proto::discovery::{beacon_id, beacon_ids_for_window};
use viska_proto::signaling::signaling_key;
use viska_proto::util::time::current_epoch;

fn to_device_id(bytes: Vec<u8>) -> Result<[u8; DEVICE_ID_LEN], FfiError> {
    bytes.try_into().map_err(|_| FfiError::Internal)
}

impl Core {
    /// `device_id` desta identidade local — dado já público (trocado no QR,
    /// vai para o preâmbulo de toda conexão TCP local que discarmos, Fase 6
    /// F1). Só existe nesta fronteira porque nada em `ffi::core` precisava
    /// dele até a descoberta local.
    pub fn my_device_id(&self) -> Vec<u8> {
        self.identity.read().unwrap().public().device_id.to_vec()
    }

    /// `BeaconID` para anunciar agora (época corrente) e os três aceitáveis
    /// para procurar (épocas anterior/atual/seguinte) — `docs/protocol.md`
    /// §9.1. Os dois lados calculam o mesmo valor, sem distinção de direção.
    pub fn discovery_beacons(&self, peer_device_id: Vec<u8>) -> Result<DiscoveryBeaconsDto, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        let (peer, _, _, _) = self
            .store
            .find_contact(&device_id)?
            .ok_or(FfiError::ContactNotFound)?;
        let id = self.identity.read().map_err(|_| FfiError::Internal)?;
        let k_sig = signaling_key(&id, &peer)?;

        Ok(DiscoveryBeaconsDto {
            advertise_beacon: beacon_id(&k_sig, current_epoch()).to_vec(),
            scan_beacons: beacon_ids_for_window(&k_sig)
                .into_iter()
                .map(|b| b.to_vec())
                .collect(),
        })
    }

    /// Identifica a qual contato pareado um `BeaconID` recebido do rádio
    /// pertence — varre todos os contatos e compara a janela de três épocas
    /// de cada um. Fica em Rust porque só aqui há a identidade privada
    /// necessária para recalcular `K_sig` de qualquer contato arbitrário; o
    /// Dart nunca vê `K_sig`, só o resultado do casamento.
    pub fn match_discovered_beacon(&self, beacon: Vec<u8>) -> Result<Option<ContactDto>, FfiError> {
        let beacon: [u8; 16] = beacon.try_into().map_err(|_| FfiError::Internal)?;

        let id = self.identity.read().map_err(|_| FfiError::Internal)?;
        for (peer, paired_at, nickname, is_verified) in self.store.list_contacts()? {
            let k_sig = signaling_key(&id, &peer)?;
            if beacon_ids_for_window(&k_sig).contains(&beacon) {
                return Ok(Some(ContactDto::from_identity(&peer, paired_at, nickname, is_verified)));
            }
        }
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::core::Core;

    fn open_core(dir: &tempfile::TempDir) -> Core {
        Core::open(dir.path().to_str().unwrap().to_owned()).unwrap()
    }

    fn paired() -> (tempfile::TempDir, Core, Vec<u8>, tempfile::TempDir, Core, Vec<u8>) {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let core_a = open_core(&dir_a);
        let core_b = open_core(&dir_b);
        let contact_a_seen_by_b = core_b.pair_from_qr(core_a.my_qr_payload(), None).unwrap();
        let contact_b_seen_by_a = core_a.pair_from_qr(core_b.my_qr_payload(), None).unwrap();
        (
            dir_a,
            core_a,
            contact_a_seen_by_b.device_id,
            dir_b,
            core_b,
            contact_b_seen_by_a.device_id,
        )
    }

    #[test]
    fn my_device_id_is_what_other_side_sees_as_contact_device_id() {
        let (_dir_a, _core_a, _device_id_a, _dir_b, core_b, device_id_b) = paired();
        assert_eq!(core_b.my_device_id(), device_id_b);
    }

    #[test]
    fn advertise_beacon_from_one_side_is_in_scan_beacons_of_the_other() {
        let (_dir_a, core_a, device_id_a, _dir_b, core_b, device_id_b) = paired();

        let beacons_a = core_a.discovery_beacons(device_id_b).unwrap();
        let beacons_b = core_b.discovery_beacons(device_id_a).unwrap();

        assert!(beacons_b.scan_beacons.contains(&beacons_a.advertise_beacon));
        assert!(beacons_a.scan_beacons.contains(&beacons_b.advertise_beacon));
        // Sem distinção de direção — os dois lados anunciam o mesmo beacon.
        assert_eq!(beacons_a.advertise_beacon, beacons_b.advertise_beacon);
    }

    #[test]
    fn beacons_for_unknown_contact_fail() {
        let dir = tempfile::tempdir().unwrap();
        let core = open_core(&dir);
        assert_eq!(
            core.discovery_beacons(vec![0u8; 16]),
            Err(FfiError::ContactNotFound)
        );
    }

    #[test]
    fn match_discovered_beacon_finds_right_contact() {
        let (_dir_a, core_a, device_id_a, _dir_b, core_b, device_id_b) = paired();

        let beacon_de_a = core_a.discovery_beacons(device_id_b.clone()).unwrap().advertise_beacon;

        let encontrado = core_b.match_discovered_beacon(beacon_de_a).unwrap();

        assert_eq!(encontrado.unwrap().device_id, device_id_a);
    }

    #[test]
    fn match_discovered_beacon_returns_none_for_unknown_beacon() {
        let dir = tempfile::tempdir().unwrap();
        let core = open_core(&dir);

        let resultado = core.match_discovered_beacon(vec![0xAA; 16]).unwrap();

        assert_eq!(resultado, None);
    }
}
