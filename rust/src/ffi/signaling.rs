//! Superfície FFI de sinalização — Fase 3, F4.
//!
//! Só produz tópicos e payloads prontos para publicar/assinar; não sabe nada
//! de MQTT, Nostr ou qualquer transporte de sinalização em si — isso é
//! `lib/src/transport/signaling/mqtt.dart`. Cada chamada recalcula `K_sig`
//! do zero (um DH estático entre identidades já pareadas, barato) — ao
//! contrário das sessões de mensagem, nada aqui fica guardado em `Core`.

use crate::ffi::core::Core;
use crate::ffi::error::FfiError;
use crate::ffi::types::SignalingTopicsDto;
use viska_proto::crypto::identity::{PublicIdentity, DEVICE_ID_LEN};
use viska_proto::signaling::{payload, topic};

fn to_device_id(bytes: Vec<u8>) -> Result<[u8; DEVICE_ID_LEN], FfiError> {
    bytes.try_into().map_err(|_| FfiError::Internal)
}

impl Core {
    /// Resolve o contato e a `K_sig` compartilhada com ele — repetido nos
    /// três métodos abaixo, então isolado aqui.
    fn signaling_key_for(&self, device_id: &[u8; DEVICE_ID_LEN]) -> Result<(PublicIdentity, viska_proto::crypto::kdf::Key), FfiError> {
        let (peer, _) = self
            .store
            .find_contact(device_id)?
            .ok_or(FfiError::ContactNotFound)?;
        let k_sig = topic::signaling_key(&self.identity, &peer)?;
        Ok((peer, k_sig))
    }

    /// Tópico para publicar agora (época corrente, nossa direção) e os três
    /// tópicos para assinar (épocas anterior/atual/seguinte, direção do
    /// par) — `docs/protocol.md` §8.1.
    pub fn signaling_topics(&self, peer_device_id: Vec<u8>) -> Result<SignalingTopicsDto, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        let (peer, k_sig) = self.signaling_key_for(&device_id)?;

        let my_direction = topic::direction(&self.identity.public(), &peer);
        let publish_topic = topic::topic_hex(
            &k_sig,
            my_direction,
            viska_proto::util::time::current_epoch(),
        );
        let subscribe_topics = topic::topics_for_window(&k_sig, my_direction.flip()).to_vec();

        Ok(SignalingTopicsDto {
            publish_topic,
            subscribe_topics,
        })
    }

    /// Cifra um payload de sinalização (SDP ou candidato ICE já
    /// serializado) para publicar — sempre exatamente 1024 B.
    pub fn seal_signaling_payload(
        &self,
        peer_device_id: Vec<u8>,
        payload_bytes: Vec<u8>,
    ) -> Result<Vec<u8>, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        let (_, k_sig) = self.signaling_key_for(&device_id)?;
        Ok(payload::seal(&k_sig, &payload_bytes)?)
    }

    /// Decifra um payload de sinalização recebido do broker.
    ///
    /// `Ok(None)` cobre qualquer falha — comprimento errado, tag do AEAD
    /// inválida — sem distinguir a causa, mesma política de
    /// `Session::decrypt_incoming` para não abrir oráculo a um broker não
    /// confiável.
    pub fn open_signaling_payload(
        &self,
        peer_device_id: Vec<u8>,
        sealed: Vec<u8>,
    ) -> Result<Option<Vec<u8>>, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        let (_, k_sig) = self.signaling_key_for(&device_id)?;
        Ok(payload::open(&k_sig, &sealed).ok())
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
        let contact_a_seen_by_b = core_b.pair_from_qr(core_a.my_qr_payload()).unwrap();
        let contact_b_seen_by_a = core_a.pair_from_qr(core_b.my_qr_payload()).unwrap();
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
    fn publish_topic_de_um_lado_esta_entre_os_tres_topicos_de_assinatura_do_outro() {
        let (_dir_a, core_a, device_id_a, _dir_b, core_b, device_id_b) = paired();

        let topics_a = core_a.signaling_topics(device_id_b).unwrap();
        let topics_b = core_b.signaling_topics(device_id_a).unwrap();

        assert!(
            topics_b.subscribe_topics.contains(&topics_a.publish_topic),
            "tópico de publicação de A deveria estar entre os assinados por B"
        );
        assert!(
            topics_a.subscribe_topics.contains(&topics_b.publish_topic),
            "tópico de publicação de B deveria estar entre os assinados por A"
        );
        assert_ne!(topics_a.publish_topic, topics_b.publish_topic);
    }

    #[test]
    fn topicos_de_contato_desconhecido_erram() {
        let dir = tempfile::tempdir().unwrap();
        let core = open_core(&dir);
        assert_eq!(
            core.signaling_topics(vec![0u8; 16]),
            Err(FfiError::ContactNotFound)
        );
    }

    #[test]
    fn payload_selado_por_um_lado_abre_do_outro() {
        let (_dir_a, core_a, device_id_a, _dir_b, core_b, device_id_b) = paired();

        let sealed = core_a
            .seal_signaling_payload(device_id_b, b"oferta sdp de teste".to_vec())
            .unwrap();
        assert_eq!(sealed.len(), viska_proto::signaling::payload::SEALED_LEN);

        let opened = core_b.open_signaling_payload(device_id_a, sealed).unwrap();
        assert_eq!(opened, Some(b"oferta sdp de teste".to_vec()));
    }

    #[test]
    fn payload_adulterado_e_descartado_como_none() {
        let (_dir_a, core_a, device_id_a, _dir_b, core_b, device_id_b) = paired();

        let mut sealed = core_a
            .seal_signaling_payload(device_id_b, b"sera adulterado".to_vec())
            .unwrap();
        let last = sealed.len() - 1;
        sealed[last] ^= 0xff;

        let opened = core_b.open_signaling_payload(device_id_a, sealed).unwrap();
        assert_eq!(opened, None);
    }
}
