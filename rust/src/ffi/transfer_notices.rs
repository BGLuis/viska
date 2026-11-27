//! Aviso ao par quando uma transferência termina só de um lado —
//! `docs/protocol.md` §7.8, D31.
//!
//! O aviso imediato (`FILE_COMPLETE`, `FILE_REJECT`, `FILE_CANCEL`) é melhor
//! esforço: sem sessão naquele momento, ele se perde, e o outro lado retomaria
//! até o teto de retenção. Por isso o lado que encerra deixa uma lápide no
//! lugar da linha ([`Core::retire_transfer`]), e cada atividade do par sobre
//! aquele `file_id` (um símbolo, um `FILE_FEEDBACK`, uma oferta reenviada) pede
//! o aviso de novo.
//!
//! O pedido sai como evento ([`TransferEventKind::NoticeReady`]), não como
//! retorno: quem vê a atividade (`decrypt_incoming`,
//! `ingest_incoming_wire_bytes`) não devolve bytes para o par, e o Dart sela o
//! aviso depois, por [`Core::seal_end_notice`], numa chamada própria.

use std::time::{Duration, Instant};

use crate::ffi::core::Core;
use crate::ffi::error::FfiError;
use crate::ffi::transfer::{to_device_id, to_file_id};
use crate::ffi::transfer_handles::can_seal_now;
use crate::ffi::types::{TransferEventDto, TransferEventKind};
use viska_proto::crypto::identity::DEVICE_ID_LEN;
use viska_proto::file::manifest::FILE_ID_LEN;
use viska_proto::store::transfers::{Direction, EndNotice};
use viska_proto::wire::packet_type::PacketType;
use viska_proto::wire::transport::Transport;

/// Intervalo mínimo entre dois pedidos de aviso da mesma lápide. Um envio
/// retomado despeja símbolos sem parar e o receptor manda `FILE_FEEDBACK` a
/// cada 500 ms (§7.4): responder a cada um gastaria ratchet e banda à toa. Curto
/// o bastante para um aviso perdido ser repetido bem antes de o par parar por
/// falta de progresso (2 min, §7.5).
const NOTICE_REPEAT_INTERVAL: Duration = Duration::from_secs(5);

/// Sela o aviso de fim de `file_id`, ou `None` se a sessão não cifra agora.
pub(super) fn seal_notice(
    session: &mut viska_proto::session::Session,
    file_id: &[u8; FILE_ID_LEN],
    notice: EndNotice,
) -> Option<Vec<u8>> {
    if !can_seal_now(session) {
        return None;
    }
    let packet_type = match notice {
        EndNotice::Complete => PacketType::FileComplete,
        EndNotice::Reject => PacketType::FileReject,
        EndNotice::Cancel => PacketType::FileCancel,
    };
    // Os três corpos são exatamente o `file_id` (§7.7, §7.8; `FileComplete::encode`).
    session
        .encrypt_outgoing(packet_type, file_id.to_vec(), Transport::DataChannel)
        .ok()
}

impl Core {
    /// O par agiu sobre `file_id`, que não tem transferência aqui. Se há lápide
    /// dele, do contato `from` quando se sabe quem mandou, pede o aviso ao Dart
    /// e devolve `true`. Nunca falha: quem chama já ignoraria um `file_id`
    /// desconhecido, e um aviso que não sai agora sai na próxima atividade.
    pub(super) fn notice_peer_activity(
        &self,
        file_id: &[u8; FILE_ID_LEN],
        from: Option<[u8; DEVICE_ID_LEN]>,
    ) -> bool {
        let now = viska_proto::util::time::unix_seconds() as i64;
        let Ok(Some(tombstone)) = self.store.find_transfer_tombstone(file_id, now) else {
            return false;
        };
        if from.is_some_and(|from| from != tombstone.contact_device_id) {
            return false;
        }
        if self.claim_notice_request(*file_id) {
            if let Ok(events) = self.transfer_events.lock() {
                events.emit(TransferEventDto {
                    peer_device_id: tombstone.contact_device_id.to_vec(),
                    file_id: file_id.to_vec(),
                    kind: TransferEventKind::NoticeReady,
                });
            }
        }
        true
    }

    /// `true` se a lápide de `file_id` não pediu aviso nos últimos
    /// [`NOTICE_REPEAT_INTERVAL`], e registra este pedido.
    fn claim_notice_request(&self, file_id: [u8; FILE_ID_LEN]) -> bool {
        let Ok(mut requests) = self.notice_requests.lock() else {
            return false;
        };
        let now = Instant::now();
        requests.retain(|_, at| now.duration_since(*at) < NOTICE_REPEAT_INTERVAL);
        if requests.contains_key(&file_id) {
            return false;
        }
        requests.insert(file_id, now);
        true
    }

    /// Sela o aviso de fim de uma transferência que este lado encerrou sozinho
    /// (`FILE_COMPLETE`, `FILE_REJECT` ou `FILE_CANCEL`, §7.8), para mandar ao
    /// contato pelo canal `control`. Chamar ao receber
    /// [`TransferEventKind::NoticeReady`]. `None` se a lápide não existe mais,
    /// é de outro contato ou a sessão não cifra agora: o próximo pedido tenta
    /// de novo.
    pub fn seal_end_notice(&self, peer_device_id: Vec<u8>, file_id: Vec<u8>) -> Result<Option<Vec<u8>>, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        let file_id = to_file_id(file_id)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);
        let now = viska_proto::util::time::unix_seconds() as i64;
        let Some(tombstone) = self.store.find_transfer_tombstone(&file_id, now)? else {
            return Ok(None);
        };
        if tombstone.contact_device_id != device_id {
            return Ok(None);
        }
        let mut sessions = self.lock_sessions()?;
        Ok(sessions
            .get_mut(&device_id)
            .and_then(|session| seal_notice(session, &file_id, tombstone.notice)))
    }

    /// Chamado de dentro de `Core::decrypt_incoming` quando um `FILE_CANCEL`
    /// chega (§7.8): o emissor desistiu. Só encerra um recebimento deste
    /// contato, em curso ou ainda retido como oferta; qualquer outra coisa é
    /// ignorada sem erro distinguível, como em `FILE_REJECT`.
    pub(super) fn handle_incoming_file_cancel(
        &self,
        contact_device_id: [u8; DEVICE_ID_LEN],
        body: &[u8],
    ) -> Result<(), FfiError> {
        // O corpo é exatamente o `file_id`; qualquer outro tamanho é lixo.
        let file_id: [u8; FILE_ID_LEN] = body.try_into().map_err(|_| FfiError::Internal)?;
        let retained_from_contact = self
            .lock_unconfirmed_offers()?
            .get(&file_id)
            .is_some_and(|offer| offer.contact_device_id == contact_device_id);
        if retained_from_contact {
            self.remove_unconfirmed_offer(&file_id)?;
        }
        let Some(stored) = self.store.find_file_transfer(&file_id)? else {
            return Ok(());
        };
        if stored.direction != Direction::Receiving || stored.contact_device_id != contact_device_id {
            return Ok(());
        }
        self.store
            .mark_received_message_failed_by_file_id(&file_id, &contact_device_id)?;
        self.end_transfer(&file_id)
    }
}
