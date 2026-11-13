//! Retomada de transferências depois de bloqueio ou reinício e os prazos que
//! encerram as que pararam — `docs/protocol.md` §7.5 e §7.7 item 5, D15, D28.
//!
//! Fica fora de `ffi/transfer.rs` porque é um ciclo de vida à parte: o handle
//! em memória é descartável, e tudo aqui reconstrói ou encerra uma
//! transferência a partir do que sobrou em disco (linha no banco, `.staging`
//! do receptor, cópia cifrada do emissor em `outgoing/`).
//!
//! Duas regras atravessam o arquivo. Um handle só entra no mapa com a Core
//! destrancada e a linha ainda no banco ([`Core::install_handle`]): a
//! reconstrução lê o arquivo inteiro fora de qualquer trava, e nesse meio-tempo
//! a Core pode trancar ou a transferência acabar. E uma transferência só é
//! destruída por um defeito que não se resolve sozinho (arquivo sumido,
//! adulterado ou cortado, manifesto ilegível); uma falha de E/S fica para a
//! próxima retomada, que o teto de retenção limita.

use std::collections::HashSet;

use crate::ffi::core::Core;
use crate::ffi::error::FfiError;
use crate::ffi::transfer::{seal_file_reject, to_device_id, OFFER_RESPONSE_TIMEOUT_SECS};
use crate::ffi::transfer_handles::{can_seal_now, Claim, OutgoingHandle, TransferHandle};
use crate::ffi::types::{ResumedDirectionDto, ResumedTransferDto};
use viska_proto::crypto::identity::DEVICE_ID_LEN;
use viska_proto::file::manifest::{Manifest, FILE_ID_LEN};
use viska_proto::file::outgoing;
use viska_proto::file::staging;
use viska_proto::file::transfer::{self, FileFeedback, ReceiveTransfer, TRANSFER_SECRET_LEN};
use viska_proto::store::transfers::{Direction, StoredTransfer};
use viska_proto::wire::packet_type::PacketType;
use viska_proto::wire::transport::Transport;

/// Teto de retenção de uma transferência em repouso (§7.5, D28): passado isto
/// desde a criação, a linha, o `transfer_secret`, o `.staging` e a cópia em
/// `outgoing/` são apagados mesmo sem conclusão. Limita por quanto tempo uma
/// apreensão do aparelho destrancado expõe uma transferência parada.
pub(super) const TRANSFER_RETENTION_SECS: i64 = 7 * 24 * 60 * 60;

/// Resultado de garantir um handle em memória para uma linha.
enum Rebuild {
    /// O handle está no mapa.
    Ready,
    /// A transferência não tinha como continuar e foi encerrada.
    Ended,
    /// Falha passageira, ou a Core trancou: fica para a próxima retomada.
    Later,
}

/// Defeito que nenhuma retomada futura conserta: o conteúdo em disco não é
/// mais o desta transferência.
fn is_lost_for_good(err: &viska_proto::Error) -> bool {
    matches!(err, viska_proto::Error::AeadFailure | viska_proto::Error::MerkleMismatch)
}

/// Por que uma transferência persistida foi encerrada sem completar.
#[derive(Debug, Clone, Copy)]
enum Ending {
    /// Oferta de arquivo sem resposta dentro de [`OFFER_RESPONSE_TIMEOUT_SECS`].
    OfferExpired,
    /// Passou de [`TRANSFER_RETENTION_SECS`].
    RetentionCeiling,
    /// A cópia de envio ou o `.staging` não serve mais.
    Unresumable,
}

impl Core {
    /// Aplica os prazos das transferências persistidas: a oferta de arquivo sem
    /// resposta em [`OFFER_RESPONSE_TIMEOUT_SECS`] expira (§7.7 item 5) e
    /// qualquer transferência com mais de [`TRANSFER_RETENTION_SECS`] some
    /// (§7.5). Só lê do banco as linhas vencidas, e nunca o segredo delas.
    pub(super) fn enforce_transfer_deadlines(&self) -> Result<(), FfiError> {
        self.enforce_transfer_deadlines_at(viska_proto::util::time::unix_seconds() as i64)
    }

    pub(super) fn enforce_transfer_deadlines_at(&self, now: i64) -> Result<(), FfiError> {
        let due = self.store.list_due_file_transfers(
            now.saturating_sub(TRANSFER_RETENTION_SECS),
            now.saturating_sub(OFFER_RESPONSE_TIMEOUT_SECS),
        )?;
        // Uma falha não pode custar o prazo das demais: todas são tentadas, e as
        // que falharem continuam no banco para a próxima chamada repetir.
        let mut first_error = None;
        for transfer in due {
            let ending = if transfer.offer_expired {
                Ending::OfferExpired
            } else {
                Ending::RetentionCeiling
            };
            let outcome = self.drop_transfer(
                &transfer.file_id,
                &transfer.contact_device_id,
                transfer.direction,
                ending,
            );
            if let Err(e) = outcome {
                first_error.get_or_insert(e);
            }
        }
        first_error.map_or(Ok(()), Err)
    }

    /// Apaga `.staging` e cópias de envio sem linha no banco: sobras de um
    /// processo que morreu no meio. Só em `open`/`unlock`, quando nenhum
    /// `start_send` pode estar gravando uma cópia cuja linha ainda não existe;
    /// no resto do tempo, quem encerra uma transferência apaga os arquivos dela.
    pub(super) fn sweep_transfer_files(&self) -> Result<(), FfiError> {
        let active: HashSet<_> = self.store.list_active_file_transfer_ids()?.into_iter().collect();
        staging::sweep_orphaned(&self.staging_dir, &active)?;
        staging::sweep_orphaned(&self.outgoing_dir, &active)?;
        Ok(())
    }

    /// Encerra uma transferência que não vai mais andar: marca a mensagem do
    /// envio conforme o motivo, descarta o handle, apaga a linha (o que destrói
    /// a chave, D15) e os arquivos.
    fn drop_transfer(
        &self,
        file_id: &[u8; FILE_ID_LEN],
        contact: &[u8; DEVICE_ID_LEN],
        direction: Direction,
        ending: Ending,
    ) -> Result<(), FfiError> {
        // A mensagem vem antes, como em `handle_incoming_file_reject`: se a
        // escrita falhar, a linha continua e a próxima chamada repete tudo.
        if direction == Direction::Sending {
            match ending {
                Ending::OfferExpired => self.store.mark_message_expired_by_file_id(file_id, contact)?,
                Ending::RetentionCeiling | Ending::Unresumable => {
                    self.store.mark_message_failed_by_file_id(file_id, contact)?
                }
            };
        }
        self.end_transfer(file_id)
    }

    /// Geração atual da sessão com o contato, 0 sem sessão.
    fn session_generation(&self, contact: &[u8; DEVICE_ID_LEN]) -> Result<u32, FfiError> {
        Ok(self.lock_sessions()?.get(contact).map_or(0, |session| session.generation()))
    }

    fn drop_stored(&self, stored: &StoredTransfer, ending: Ending) -> Result<(), FfiError> {
        self.drop_transfer(&stored.file_id, &stored.contact_device_id, stored.direction, ending)
    }

    /// Reconstrói e devolve as transferências com o contato que podem continuar
    /// (§7.5). Chamar quando a sessão com ele chega a `Established`, inclusive
    /// depois de trocada por outra (§11.4), e quando o canal reconecta: pode ser
    /// chamada quantas vezes for, pois um handle que já está em memória fica como
    /// está. Enquanto uma sessão candidata segura o envio (§11.4), devolve vazio:
    /// a oferta selada agora sairia pela sessão que o par acabou de perder.
    ///
    /// Um envio cuja cópia em `outgoing/` sumiu, foi cortada ou não bate mais
    /// com a raiz é encerrado como falha. Um recebimento cujo `.staging` sumiu
    /// ou não autentica é encerrado e volta como `Abandoned`, com o
    /// `FILE_REJECT` que avisa o emissor. Uma falha passageira só pula aquela
    /// transferência nesta chamada. Um envio sem resposta volta com
    /// `needs_offer`, porque o `FILE_METADATA` original pode ter se perdido com
    /// a sessão anterior.
    pub fn resume_transfers(&self, peer_device_id: Vec<u8>) -> Result<Vec<ResumedTransferDto>, FfiError> {
        self.ensure_not_locked()?;
        let device_id = to_device_id(peer_device_id)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);
        if !self.lock_sessions()?.get(&device_id).is_some_and(can_seal_now) {
            return Ok(Vec::new());
        }
        // Melhor esforço: retomar algo vencido só para descartá-lo depois seria
        // reler o arquivo à toa, mas um prazo que falhe agora volta na próxima.
        let _ = self.enforce_transfer_deadlines();

        let mut resumed = Vec::new();
        for direction in [Direction::Sending, Direction::Receiving] {
            for stored in self.store.list_file_transfers_for_contact(&device_id, direction)? {
                // Cada transferência é independente: uma linha que falhe agora
                // não pode segurar as outras do contato até o próximo evento.
                if let Ok(Some(dto)) = self.resume_one(&device_id, &stored) {
                    resumed.push(dto);
                }
            }
        }
        Ok(resumed)
    }

    fn resume_one(
        &self,
        device_id: &[u8; DEVICE_ID_LEN],
        stored: &StoredTransfer,
    ) -> Result<Option<ResumedTransferDto>, FfiError> {
        let Ok(manifest) = Manifest::decode(&stored.manifest_cbor) else {
            self.drop_stored(stored, Ending::Unresumable)?;
            return Ok(None);
        };
        match stored.direction {
            Direction::Sending => {
                // `start_send` grava a mensagem antes da linha; uma linha sem
                // mensagem mandaria um arquivo que a pessoa não vê na conversa.
                let Some(message_id) =
                    self.store.outgoing_message_id_by_file_id(&stored.file_id, device_id)?
                else {
                    self.drop_stored(stored, Ending::Unresumable)?;
                    return Ok(None);
                };
                if !matches!(self.ensure_send_handle(stored, &manifest)?, Rebuild::Ready) {
                    return Ok(None);
                }
                self.store.reopen_failed_message_by_file_id(&stored.file_id, device_id)?;
                Ok(Some(ResumedTransferDto {
                    file_id: stored.file_id.to_vec(),
                    direction: ResumedDirectionDto::Send,
                    needs_offer: !stored.answered,
                    sealed_notice: None,
                    message_id: Some(message_id),
                }))
            }
            Direction::Receiving => match self.ensure_receive_handle(stored, manifest)? {
                Rebuild::Ready => Ok(Some(ResumedTransferDto {
                    file_id: stored.file_id.to_vec(),
                    direction: ResumedDirectionDto::Receive,
                    needs_offer: false,
                    sealed_notice: None,
                    message_id: None,
                })),
                // O emissor ainda tem a linha e tentaria retomar até o teto de
                // retenção; o `FILE_REJECT` de §7.7 o encerra. Melhor esforço,
                // como a recusa: sem sessão para selar, o aviso se perde.
                Rebuild::Ended => {
                    let mut sessions = self.lock_sessions()?;
                    let notice = sessions
                        .get_mut(device_id)
                        .filter(|session| can_seal_now(session))
                        .and_then(|session| seal_file_reject(session, &stored.file_id));
                    Ok(notice.map(|notice| ResumedTransferDto {
                        file_id: stored.file_id.to_vec(),
                        direction: ResumedDirectionDto::Abandoned,
                        needs_offer: false,
                        sealed_notice: Some(notice),
                        message_id: None,
                    }))
                }
                Rebuild::Later => Ok(None),
            },
        }
    }

    /// O `FILE_METADATA` de um envio retomado cuja oferta ainda não teve
    /// resposta, selado na sessão atual com o mesmo `file_id`, segredo e
    /// manifesto. `None` se não há mais o que oferecer (a oferta foi
    /// respondida, a transferência acabou ou não é um envio para este contato)
    /// ou se a sessão não cifra agora.
    pub fn seal_resumed_offer(
        &self,
        peer_device_id: Vec<u8>,
        file_id: Vec<u8>,
    ) -> Result<Option<Vec<u8>>, FfiError> {
        self.ensure_not_locked()?;
        let device_id = to_device_id(peer_device_id)?;
        let file_id: [u8; FILE_ID_LEN] = file_id.try_into().map_err(|_| FfiError::Internal)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);
        let Some(stored) = self.store.find_file_transfer(&file_id)? else {
            return Ok(None);
        };
        if stored.direction != Direction::Sending
            || stored.contact_device_id != device_id
            || stored.answered
        {
            return Ok(None);
        }
        let manifest = Manifest::decode(&stored.manifest_cbor)?;
        self.reseal_metadata(&device_id, &stored, &manifest)
    }

    /// Garante um `SendTransfer` em memória para `stored`, lido da cópia em
    /// `outgoing/` depois de conferida a raiz.
    fn ensure_send_handle(&self, stored: &StoredTransfer, manifest: &Manifest) -> Result<Rebuild, FfiError> {
        let generation = self.session_generation(&stored.contact_device_id)?;
        self.rebuild(stored, &self.outgoing_dir, || {
            // Conferir a raiz relê a cópia inteira, fora de qualquer trava.
            let reader = outgoing::open_outgoing_copy(&self.outgoing_dir, manifest, &stored.transfer_secret)?;
            Ok(TransferHandle::Send(OutgoingHandle::new(
                manifest.clone(),
                stored.kind,
                &stored.transfer_secret,
                reader,
                generation,
                stored.answered,
            )))
        })
    }

    /// Garante um `ReceiveTransfer` em memória para `stored`, retomado do
    /// `.staging`.
    fn ensure_receive_handle(&self, stored: &StoredTransfer, manifest: Manifest) -> Result<Rebuild, FfiError> {
        self.rebuild(stored, &self.staging_dir, || {
            let receive = ReceiveTransfer::resume(manifest, stored.kind, &stored.transfer_secret, &self.staging_dir)?;
            Ok(TransferHandle::Receive(receive))
        })
    }

    /// O roteiro comum das duas reconstruções. A reserva cobre a leitura do
    /// arquivo e, no recebimento, o corte do staging em `ReceiveTransfer::resume`:
    /// uma segunda reconstrução, ou o `finish` concorrente, cortaria páginas que
    /// o outro está usando. Arquivo sumido ou que não autentica encerra a
    /// transferência; qualquer outra falha fica para a próxima retomada.
    fn rebuild(
        &self,
        stored: &StoredTransfer,
        dir: &std::path::Path,
        open: impl FnOnce() -> viska_proto::Result<TransferHandle>,
    ) -> Result<Rebuild, FfiError> {
        let claim = match self.claim_for_rebuild(stored.file_id)? {
            Claim::Live => return Ok(Rebuild::Ready),
            Claim::Busy => return Ok(Rebuild::Later),
            Claim::Claimed(guard) => guard,
        };
        if !staging::staging_path(dir, &stored.file_id).exists() {
            self.drop_stored(stored, Ending::Unresumable)?;
            return Ok(Rebuild::Ended);
        }
        let handle = match open() {
            Ok(handle) => handle,
            Err(err) if is_lost_for_good(&err) => {
                self.drop_stored(stored, Ending::Unresumable)?;
                return Ok(Rebuild::Ended);
            }
            Err(_) => return Ok(Rebuild::Later),
        };
        Ok(if self.install_handle(stored.file_id, handle, Some(claim))? {
            Rebuild::Ready
        } else {
            Rebuild::Later
        })
    }

    /// Sela de novo o `FILE_METADATA` de um envio, com o mesmo `file_id`,
    /// segredo e manifesto. `None` se a sessão deixou de poder cifrar desde a
    /// checagem.
    fn reseal_metadata(
        &self,
        device_id: &[u8; DEVICE_ID_LEN],
        stored: &StoredTransfer,
        manifest: &Manifest,
    ) -> Result<Option<Vec<u8>>, FfiError> {
        // Um segredo com outro tamanho seria uma linha corrompida, que nenhum
        // `FILE_METADATA` válido produziria.
        let secret: zeroize::Zeroizing<[u8; TRANSFER_SECRET_LEN]> = zeroize::Zeroizing::new(
            stored
                .transfer_secret
                .as_slice()
                .try_into()
                .map_err(|_| FfiError::Internal)?,
        );
        let body = transfer::encode_metadata_body(stored.kind, &secret, manifest)?;
        let mut sessions = self.lock_sessions()?;
        let Some(session) = sessions.get_mut(device_id).filter(|s| can_seal_now(s)) else {
            return Ok(None);
        };
        Ok(Some(session.encrypt_outgoing(
            PacketType::FileMetadata,
            body,
            Transport::DataChannel,
        )?))
    }

    /// Entrega um `FILE_FEEDBACK` ao envio em memória. Se o receptor está atrás
    /// do emissor numa sessão nova, monta um emissor novo a partir da cópia e
    /// deixa o feedback guiá-lo: o receptor que retomou do staging pode ter
    /// perdido o fim de um bloco que já tinha confirmado (blocos da LAN não
    /// fecham em página, §7.5), e `SendTransfer` só anda para a frente. Na
    /// mesma sessão, um receptor nunca volta: um feedback que pareça atrás é
    /// só um atrasado, ultrapassado por outro já processado.
    pub(super) fn ingest_send_feedback(
        &self,
        stored: &StoredTransfer,
        manifest: &Manifest,
        feedback: &FileFeedback,
    ) -> Result<(), FfiError> {
        let generation = self.session_generation(&stored.contact_device_id)?;
        {
            let mut transfers = self.lock_transfers()?;
            let Some(TransferHandle::Send(send)) = transfers.get_mut(&stored.file_id) else {
                return Ok(());
            };
            send.answered = true;
            let behind = feedback.first_incomplete_block() < send.transfer.current_block();
            if !behind || send.generation == generation {
                send.transfer.ingest_feedback(feedback)?;
                // Um feedback em dia fixa a geração: daqui em diante, só um
                // receptor que reabriu de novo faz o envio voltar.
                if !behind {
                    send.generation = generation;
                }
                return Ok(());
            }
        }
        // Fora da trava: pular os blocos que o receptor ainda tem decifra a
        // cópia até eles. A cópia já teve a raiz conferida ao entrar em memória,
        // e cada página continua autenticada pelo AEAD.
        let reader = outgoing::read_outgoing_copy(&self.outgoing_dir, manifest, &stored.transfer_secret)?;
        let mut rewound =
            OutgoingHandle::new(manifest.clone(), stored.kind, &stored.transfer_secret, reader, generation, true);
        rewound.transfer.ingest_feedback(feedback)?;

        let mut transfers = self.lock_transfers()?;
        if self.is_locked() {
            return Ok(());
        }
        // Só troca se o handle continuar adiante e ainda não tiver recuado nesta
        // sessão: outro feedback pode ter feito isso enquanto este era montado.
        if let Some(TransferHandle::Send(send)) = transfers.get_mut(&stored.file_id) {
            if send.generation != generation && send.transfer.current_block() > rewound.transfer.current_block() {
                *send = rewound;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::transfer::tests::{
        established_pair, fid, open_core, pair_with_pending_offer, state_of, write_temp_file,
        EstablishedPair,
    };
    use crate::ffi::types::{DeliveryStateDto, SendFileStartedDto, SessionStateKind};
    use crate::ffi::FfiError;

    fn created_at(core: &Core, file_id: &[u8]) -> i64 {
        core.store.find_file_transfer(&fid(file_id)).unwrap().unwrap().created_at_unix_secs
    }

    fn outgoing_copy_exists(core: &Core, file_id: &[u8]) -> bool {
        staging::staging_path(&core.outgoing_dir, &fid(file_id)).exists()
    }

    #[test]
    fn unanswered_offer_expires_exactly_at_the_deadline() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);
        let sent_at = created_at(&pair.core_a, &started.file_id);

        pair.core_a
            .enforce_transfer_deadlines_at(sent_at + OFFER_RESPONSE_TIMEOUT_SECS - 1)
            .unwrap();
        assert!(pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_some());

        pair.core_a
            .enforce_transfer_deadlines_at(sent_at + OFFER_RESPONSE_TIMEOUT_SECS)
            .unwrap();
        assert!(pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_none());
        assert_eq!(pair.core_a.next_outgoing_wire_chunk(started.file_id.clone()).unwrap(), None);
        assert!(!outgoing_copy_exists(&pair.core_a, &started.file_id));
        let timeline = pair.core_a.list_messages(pair.device_id_b.clone()).unwrap();
        assert_eq!(timeline[0].delivery_state, DeliveryStateDto::Expired);

        // O fim tardio do bombeamento no Dart não apaga o estado final.
        pair.core_a.mark_message_sent(started.message_id).unwrap();
        let timeline = pair.core_a.list_messages(pair.device_id_b.clone()).unwrap();
        assert_eq!(timeline[0].delivery_state, DeliveryStateDto::Expired);
    }

    #[test]
    fn first_feedback_ends_the_offer_deadline() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let src_path = write_temp_file(&dir_src, "aceito.bin", &vec![7u8; 4_000]);
        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();
        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata.clone())
            .unwrap();
        let sent_at = created_at(&pair.core_a, &started.file_id);

        let feedback = pair
            .core_b
            .file_feedback(pair.device_id_a.clone(), started.file_id.clone())
            .unwrap();
        pair.core_a
            .decrypt_incoming(pair.device_id_b.clone(), feedback)
            .unwrap();

        assert!(pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().unwrap().answered);
        pair.core_a
            .enforce_transfer_deadlines_at(sent_at + TRANSFER_RETENTION_SECS - 1)
            .unwrap();
        assert!(pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_some());
    }

    #[test]
    fn feedback_from_another_contact_does_not_answer_the_offer() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);
        let body = FileFeedback {
            file_id: fid(&started.file_id),
            block_index: 0,
            symbols_received: 0,
            blocks_completed: vec![false],
        }
        .encode();

        pair.core_a.handle_incoming_file_feedback([0xEE; DEVICE_ID_LEN], &body).unwrap();

        assert!(!pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().unwrap().answered);
    }

    #[test]
    fn rejected_or_cancelled_offer_leaves_nothing_behind() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);
        let sealed = pair.core_b.reject_file_offer(started.file_id.clone()).unwrap().unwrap();
        pair.core_a.decrypt_incoming(pair.device_id_b.clone(), sealed).unwrap();
        assert!(pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_none());
        assert!(!outgoing_copy_exists(&pair.core_a, &started.file_id));

        let src_path = write_temp_file(&dir_src, "cancelado.bin", &vec![1u8; 4_000]);
        let second = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();
        assert!(outgoing_copy_exists(&pair.core_a, &second.file_id));
        pair.core_a.cancel_transfer(second.file_id.clone()).unwrap();
        assert!(pair.core_a.store.find_file_transfer(&fid(&second.file_id)).unwrap().is_none());
        assert!(!outgoing_copy_exists(&pair.core_a, &second.file_id));
    }

    #[test]
    fn offer_deadline_survives_lock_and_unlock() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);
        let sent_at = created_at(&pair.core_a, &started.file_id);

        pair.core_a.lock().unwrap();
        pair.core_a.unlock().unwrap();

        assert!(pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_some());
        pair.core_a
            .enforce_transfer_deadlines_at(sent_at + OFFER_RESPONSE_TIMEOUT_SECS)
            .unwrap();
        assert!(pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_none());
        let timeline = pair.core_a.list_messages(pair.device_id_b.clone()).unwrap();
        assert_eq!(timeline[0].delivery_state, DeliveryStateDto::Expired);
    }

    #[test]
    fn deadlines_are_retried_after_a_store_failure() {
        let dir_src = tempfile::tempdir().unwrap();
        let pair = established_pair();
        let mut ids = Vec::new();
        for name in ["a.bin", "b.bin"] {
            let path = write_temp_file(&dir_src, name, &vec![3u8; 2_000]);
            let started = pair
                .core_a
                .start_send_file(pair.device_id_b.clone(), path, false)
                .unwrap();
            ids.push(started.file_id);
        }
        let sent_at = created_at(&pair.core_a, &ids[0]);
        pair.core_a.store.close().unwrap();

        assert!(pair
            .core_a
            .enforce_transfer_deadlines_at(sent_at + OFFER_RESPONSE_TIMEOUT_SECS)
            .is_err());

        pair.core_a.unlock().unwrap();
        pair.core_a
            .enforce_transfer_deadlines_at(sent_at + OFFER_RESPONSE_TIMEOUT_SECS + 10)
            .unwrap();
        assert!(ids
            .iter()
            .all(|id| pair.core_a.store.find_file_transfer(&fid(id)).unwrap().is_none()));
    }


    // --- Retomada depois de bloqueio ou reinício (§7.5, issue #82) ---

    /// Lado da transferência num `EstablishedPair`: o `Core` e o identificador
    /// pelo qual ele chama o outro.
    fn side(pair: &EstablishedPair, a: bool) -> (&Core, Vec<u8>) {
        if a {
            (&pair.core_a, pair.device_id_b.clone())
        } else {
            (&pair.core_b, pair.device_id_a.clone())
        }
    }

    /// Religa a sessão depois de um lado trancar (ou reabrir) o app, pelo
    /// caminho de §11.4 que o app usa: o lado que perdeu a sessão anuncia ao
    /// conectar, as respostas vão e voltam, e um texto em cada sentido promove
    /// a candidata e dá cadeia de envio aos dois.
    fn reconnect(pair: &EstablishedPair, restarted_is_a: bool) {
        let (restarted, restarted_peer) = side(pair, restarted_is_a);
        let mut bytes = restarted.connect_signal(restarted_peer).unwrap().expect("sem sessão, o lado anuncia");
        let mut to_a = !restarted_is_a;
        for _ in 0..16 {
            let (core, peer) = side(pair, to_a);
            match core.receive_incoming(peer, bytes).unwrap().reply {
                Some(reply) => {
                    bytes = reply;
                    to_a = !to_a;
                }
                None => break,
            }
        }
        for from_a in [true, false, true] {
            let (from, from_peer) = side(pair, from_a);
            let (to, to_peer) = side(pair, !from_a);
            let mut out: Vec<Vec<u8>> = from
                .seal_outgoing_text(from_peer.clone(), "oi".to_owned())
                .unwrap()
                .bytes
                .into_iter()
                .collect();
            out.extend(from.flush_pending(from_peer).unwrap().into_iter().filter_map(|m| m.bytes));
            for bytes in out {
                to.receive_incoming(to_peer.clone(), bytes).unwrap();
            }
        }
        for a in [true, false] {
            let (core, peer) = side(pair, a);
            let status = core.session_status(peer).unwrap().unwrap();
            assert_eq!(status.state, SessionStateKind::Established);
        }
    }

    /// O laço que o Dart faz: bombeia os símbolos do emissor (A) até ele parar
    /// e devolve um `FILE_FEEDBACK` do receptor (B), até B ter `blocks` blocos.
    fn drive(pair: &EstablishedPair, file_id: &[u8], blocks: u32) {
        for _ in 0..10_000 {
            let progress = pair.core_b.transfer_progress(file_id.to_vec()).unwrap().unwrap();
            if progress.blocks_done >= blocks {
                return;
            }
            while let Some(chunk) = pair.core_a.next_outgoing_wire_chunk(file_id.to_vec()).unwrap() {
                pair.core_b.ingest_incoming_wire_bytes(chunk).unwrap();
            }
            let feedback = pair.core_b.file_feedback(pair.device_id_a.clone(), file_id.to_vec()).unwrap();
            pair.core_a.receive_incoming(pair.device_id_b.clone(), feedback).unwrap();
        }
        panic!("a transferência não avançou");
    }

    /// Termina o recebimento em B, entrega o `FILE_COMPLETE` a A e devolve o
    /// que B gravou.
    fn finish(pair: &EstablishedPair, file_id: &[u8], dir_dst: &tempfile::TempDir) -> Vec<u8> {
        let total = pair.core_b.transfer_progress(file_id.to_vec()).unwrap().unwrap().total_blocks;
        drive(pair, file_id, total);
        let dst = dir_dst.path().join("recebido.bin");
        let complete = pair
            .core_b
            .finish_receive_file(pair.device_id_a.clone(), file_id.to_vec(), dst.to_str().unwrap().to_owned())
            .unwrap();
        pair.core_a.receive_incoming(pair.device_id_b.clone(), complete.unwrap()).unwrap();
        std::fs::read(dst).unwrap()
    }

    /// Dois blocos no DataChannel (D6): um de 16 MiB, que vai inteiro a disco
    /// no receptor, e um curto no fim.
    fn two_block_file() -> Vec<u8> {
        (0..(16 * 1024 * 1024 + 4096)).map(|i: u32| (i % 251) as u8).collect()
    }

    fn start_two_block_send(pair: &EstablishedPair, dir_src: &tempfile::TempDir) -> (SendFileStartedDto, Vec<u8>) {
        let original = two_block_file();
        let path = write_temp_file(dir_src, "grande.bin", &original);
        let started = pair.core_a.start_send_file(pair.device_id_b.clone(), path, false).unwrap();
        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata.clone())
            .unwrap();
        (started, original)
    }

    fn assert_sender_clean(pair: &EstablishedPair, file_id: &[u8]) {
        assert!(pair.core_a.store.find_file_transfer(&fid(file_id)).unwrap().is_none());
        assert!(!outgoing_copy_exists(&pair.core_a, file_id));
        assert!(pair.core_a.transfer_progress(file_id.to_vec()).unwrap().is_none());
    }

    #[test]
    fn send_survives_sender_lock_and_unlock() {
        let pair = established_pair();
        let (dir_src, dir_dst) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let (started, original) = start_two_block_send(&pair, &dir_src);
        drive(&pair, &started.file_id, 1);

        pair.core_a.lock().unwrap();
        pair.core_a.unlock().unwrap();
        assert!(pair.core_a.transfer_progress(started.file_id.clone()).unwrap().is_none());
        assert_eq!(state_of(&pair, started.message_id), DeliveryStateDto::Pending);
        reconnect(&pair, true);

        let resumed = pair.core_a.resume_transfers(pair.device_id_b.clone()).unwrap();
        assert_eq!(
            resumed,
            vec![ResumedTransferDto {
                file_id: started.file_id.clone(),
                direction: ResumedDirectionDto::Send,
                needs_offer: false,
                sealed_notice: None,
                message_id: Some(started.message_id),
            }],
            "a oferta já respondida não é reenviada"
        );
        let receiving = pair.core_b.resume_transfers(pair.device_id_a.clone()).unwrap();
        assert_eq!(receiving[0].direction, ResumedDirectionDto::Receive);

        assert_eq!(finish(&pair, &started.file_id, &dir_dst), original);
        assert_sender_clean(&pair, &started.file_id);
    }

    #[test]
    fn receive_survives_receiver_lock_and_unlock() {
        let pair = established_pair();
        let (dir_src, dir_dst) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let (started, original) = start_two_block_send(&pair, &dir_src);
        drive(&pair, &started.file_id, 1);

        pair.core_b.lock().unwrap();
        pair.core_b.unlock().unwrap();
        reconnect(&pair, false);

        let resumed = pair.core_b.resume_transfers(pair.device_id_a.clone()).unwrap();
        assert_eq!(resumed.len(), 1);
        assert_eq!(resumed[0].direction, ResumedDirectionDto::Receive);
        let progress = pair.core_b.transfer_progress(started.file_id.clone()).unwrap().unwrap();
        assert_eq!(progress.blocks_done, 1, "o bloco gravado no staging não volta a ser pedido");
        pair.core_a.resume_transfers(pair.device_id_b.clone()).unwrap();

        assert_eq!(finish(&pair, &started.file_id, &dir_dst), original);
        assert_sender_clean(&pair, &started.file_id);
    }

    #[test]
    fn receive_survives_receiver_restart() {
        let mut pair = established_pair();
        let (dir_src, dir_dst) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let (started, original) = start_two_block_send(&pair, &dir_src);
        drive(&pair, &started.file_id, 1);

        pair.core_b = open_core(&pair._dir_b);
        reconnect(&pair, false);

        pair.core_b.resume_transfers(pair.device_id_a.clone()).unwrap();
        let progress = pair.core_b.transfer_progress(started.file_id.clone()).unwrap().unwrap();
        assert_eq!(progress.blocks_done, 1);
        pair.core_a.resume_transfers(pair.device_id_b.clone()).unwrap();

        assert_eq!(finish(&pair, &started.file_id, &dir_dst), original);
        assert_sender_clean(&pair, &started.file_id);
    }

    #[test]
    fn unanswered_offer_is_resent_after_sender_restart_and_completes() {
        let mut pair = established_pair();
        let (dir_src, dir_dst) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let original: Vec<u8> = (0..20_000u32).map(|i| (i % 251) as u8).collect();
        let path = write_temp_file(&dir_src, "perdida.bin", &original);
        // O `FILE_METADATA` nunca chega a B: o app de A fecha antes.
        let started = pair.core_a.start_send_file(pair.device_id_b.clone(), path, false).unwrap();

        pair.core_a = open_core(&pair._dir_a);
        assert_eq!(state_of(&pair, started.message_id), DeliveryStateDto::Pending);
        reconnect(&pair, true);

        let resumed = pair.core_a.resume_transfers(pair.device_id_b.clone()).unwrap();
        assert!(resumed[0].needs_offer, "oferta sem resposta é reenviada");
        let offer = pair
            .core_a
            .seal_resumed_offer(pair.device_id_b.clone(), started.file_id.clone())
            .unwrap()
            .unwrap();
        pair.core_b.decrypt_incoming(pair.device_id_a.clone(), offer).unwrap();

        // Uma segunda oferta selada é ignorada por B, que já a conhece.
        let again = pair
            .core_a
            .seal_resumed_offer(pair.device_id_b.clone(), started.file_id.clone())
            .unwrap()
            .unwrap();
        pair.core_b.decrypt_incoming(pair.device_id_a.clone(), again).unwrap();
        assert_eq!(pair.core_b.list_active_file_transfer_ids().unwrap(), vec![started.file_id.clone()]);

        assert_eq!(finish(&pair, &started.file_id, &dir_dst), original);
        assert_sender_clean(&pair, &started.file_id);
        let after = pair.core_a.resume_transfers(pair.device_id_b.clone()).unwrap();
        assert!(after.is_empty());
    }

    #[test]
    fn resume_is_idempotent_and_keeps_live_handles() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let (started, _) = start_two_block_send(&pair, &dir_src);
        drive(&pair, &started.file_id, 1);
        let before = pair.core_a.transfer_progress(started.file_id.clone()).unwrap().unwrap();

        let first = pair.core_a.resume_transfers(pair.device_id_b.clone()).unwrap();
        let second = pair.core_a.resume_transfers(pair.device_id_b.clone()).unwrap();

        assert_eq!(first, second);
        assert_eq!(pair.core_a.transfer_progress(started.file_id.clone()).unwrap().unwrap(), before);
    }

    #[test]
    fn resume_without_an_established_session_does_nothing() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let path = write_temp_file(&dir_src, "a.bin", &[1u8; 3_000]);
        let started = pair.core_a.start_send_file(pair.device_id_b.clone(), path, false).unwrap();
        pair.core_a.lock().unwrap();
        pair.core_a.unlock().unwrap();

        assert!(pair.core_a.resume_transfers(pair.device_id_b.clone()).unwrap().is_empty());
        assert!(pair.core_a.transfer_progress(started.file_id.clone()).unwrap().is_none());
        assert!(pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_some());
    }

    #[test]
    fn resume_while_locked_is_refused() {
        let pair = established_pair();
        pair.core_a.lock().unwrap();
        assert!(matches!(
            pair.core_a.resume_transfers(pair.device_id_b.clone()),
            Err(FfiError::Locked)
        ));
    }

    #[test]
    fn tampered_outgoing_copy_fails_the_send_on_resume() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let path = write_temp_file(&dir_src, "a.bin", &[9u8; 100_000]);
        let started = pair.core_a.start_send_file(pair.device_id_b.clone(), path, false).unwrap();
        pair.core_a.lock().unwrap();
        let copy = staging::staging_path(&pair.core_a.outgoing_dir, &fid(&started.file_id));
        let mut bytes = std::fs::read(&copy).unwrap();
        bytes[50] ^= 1;
        std::fs::write(&copy, bytes).unwrap();
        pair.core_a.unlock().unwrap();
        reconnect(&pair, true);

        assert!(pair.core_a.resume_transfers(pair.device_id_b.clone()).unwrap().is_empty());
        assert_eq!(state_of(&pair, started.message_id), DeliveryStateDto::Failed);
        assert_sender_clean(&pair, &started.file_id);
    }

    #[test]
    fn a_receive_that_cannot_resume_tells_the_sender_to_stop() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let (started, _) = start_two_block_send(&pair, &dir_src);
        pair.core_b.lock().unwrap();
        std::fs::remove_file(staging::staging_path(&pair.core_b.staging_dir, &fid(&started.file_id))).unwrap();
        pair.core_b.unlock().unwrap();
        reconnect(&pair, false);

        let resumed = pair.core_b.resume_transfers(pair.device_id_a.clone()).unwrap();
        assert_eq!(resumed.len(), 1);
        assert_eq!(resumed[0].direction, ResumedDirectionDto::Abandoned);
        assert!(pair.core_b.list_active_file_transfer_ids().unwrap().is_empty());

        let notice = resumed[0].sealed_notice.clone().unwrap();
        pair.core_a.decrypt_incoming(pair.device_id_b.clone(), notice).unwrap();
        assert_sender_clean(&pair, &started.file_id);
        assert_eq!(state_of(&pair, started.message_id), DeliveryStateDto::Rejected);
    }

    #[test]
    fn a_late_feedback_in_the_same_session_does_not_rewind_the_sender() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let (started, _) = start_two_block_send(&pair, &dir_src);
        // Um feedback de antes de o bloco 0 completar, entregue depois.
        let early = pair.core_b.file_feedback(pair.device_id_a.clone(), started.file_id.clone()).unwrap();
        drive(&pair, &started.file_id, 1);
        assert_eq!(pair.core_a.transfer_progress(started.file_id.clone()).unwrap().unwrap().blocks_done, 1);

        pair.core_a.receive_incoming(pair.device_id_b.clone(), early).unwrap();

        assert_eq!(pair.core_a.transfer_progress(started.file_id.clone()).unwrap().unwrap().blocks_done, 1);
    }

    #[test]
    fn progress_reports_whether_the_offer_still_awaits_an_answer() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);
        assert!(pair.core_a.transfer_progress(started.file_id.clone()).unwrap().unwrap().awaiting_answer);

        pair.core_b.accept_file_offer(started.file_id.clone()).unwrap();
        let feedback = pair.core_b.file_feedback(pair.device_id_a.clone(), started.file_id.clone()).unwrap();
        pair.core_a.decrypt_incoming(pair.device_id_b.clone(), feedback).unwrap();

        assert!(!pair.core_a.transfer_progress(started.file_id.clone()).unwrap().unwrap().awaiting_answer);
        assert!(!pair.core_b.transfer_progress(started.file_id).unwrap().unwrap().awaiting_answer);
    }

    #[test]
    fn seal_resumed_offer_only_seals_an_unanswered_send_of_that_contact() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);
        assert!(pair.core_a.seal_resumed_offer(pair.device_id_b.clone(), started.file_id.clone()).unwrap().is_some());
        assert!(pair.core_a.seal_resumed_offer(vec![0xEE; 16], started.file_id.clone()).unwrap().is_none());
        assert!(pair.core_a.seal_resumed_offer(pair.device_id_b.clone(), vec![0x11; 16]).unwrap().is_none());

        pair.core_b.accept_file_offer(started.file_id.clone()).unwrap();
        let feedback = pair.core_b.file_feedback(pair.device_id_a.clone(), started.file_id.clone()).unwrap();
        pair.core_a.decrypt_incoming(pair.device_id_b.clone(), feedback).unwrap();

        assert!(pair.core_a.seal_resumed_offer(pair.device_id_b.clone(), started.file_id).unwrap().is_none());
    }

    #[test]
    fn transfers_past_the_retention_ceiling_are_dropped_on_both_sides() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let (started, _) = start_two_block_send(&pair, &dir_src);
        drive(&pair, &started.file_id, 1);
        let staging_b = staging::staging_path(&pair.core_b.staging_dir, &fid(&started.file_id));
        assert!(staging_b.exists());

        for core in [&pair.core_a, &pair.core_b] {
            let created = created_at(core, &started.file_id);
            core.enforce_transfer_deadlines_at(created + TRANSFER_RETENTION_SECS - 1).unwrap();
            assert!(core.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_some());
            core.enforce_transfer_deadlines_at(created + TRANSFER_RETENTION_SECS).unwrap();
            assert!(core.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_none());
        }
        assert_sender_clean(&pair, &started.file_id);
        assert!(!staging_b.exists());
        assert!(pair.core_b.transfer_progress(started.file_id.clone()).unwrap().is_none());
        assert_eq!(state_of(&pair, started.message_id), DeliveryStateDto::Failed);
    }

    #[test]
    fn reopening_core_keeps_a_resumable_send_pending() {
        let mut pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let path = write_temp_file(&dir_src, "a.bin", &[2u8; 3_000]);
        let started = pair.core_a.start_send_file(pair.device_id_b.clone(), path, false).unwrap();
        // O bombeamento caiu e o Dart marcou falha; a retomada desfaz.
        pair.core_a.mark_message_failed(started.message_id).unwrap();

        pair.core_a = open_core(&pair._dir_a);
        assert_eq!(state_of(&pair, started.message_id), DeliveryStateDto::Failed);
        assert!(outgoing_copy_exists(&pair.core_a, &started.file_id));
        reconnect(&pair, true);
        pair.core_a.resume_transfers(pair.device_id_b.clone()).unwrap();
        assert_eq!(state_of(&pair, started.message_id), DeliveryStateDto::Pending);
    }

    #[test]
    fn start_send_without_session_leaves_no_copy_behind() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let path = write_temp_file(&dir_src, "a.bin", &[2u8; 3_000]);
        pair.core_a.lock_sessions().unwrap().clear();

        assert!(pair.core_a.start_send_file(pair.device_id_b.clone(), path, false).is_err());
        let leftovers = std::fs::read_dir(&pair.core_a.outgoing_dir).map(|d| d.count()).unwrap_or(0);
        assert_eq!(leftovers, 0);
    }

    /// LAN: blocos de 65535 × 1024 B não fecham em página, então o receptor que
    /// retoma pode voltar a um bloco que já tinha confirmado enquanto o emissor,
    /// que não trancou, segue adiante. Aqui o corte da página é forçado.
    #[test]
    fn sender_rewinds_when_the_receiver_resumes_behind_it() {
        let pair = established_pair();
        let (dir_src, dir_dst) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let (started, original) = start_two_block_send(&pair, &dir_src);
        drive(&pair, &started.file_id, 1);
        assert_eq!(pair.core_a.transfer_progress(started.file_id.clone()).unwrap().unwrap().blocks_done, 1);

        pair.core_b.lock().unwrap();
        // Tira a última página inteira do bloco 0, como se ela tivesse ficado só
        // na RAM do receptor.
        let path = staging::staging_path(&pair.core_b.staging_dir, &fid(&started.file_id));
        let len = std::fs::metadata(&path).unwrap().len();
        let page = (staging::PAGE_LEN + 40) as u64;
        std::fs::OpenOptions::new().write(true).open(&path).unwrap().set_len(len - page).unwrap();
        pair.core_b.unlock().unwrap();
        reconnect(&pair, false);

        pair.core_b.resume_transfers(pair.device_id_a.clone()).unwrap();
        assert_eq!(pair.core_b.transfer_progress(started.file_id.clone()).unwrap().unwrap().blocks_done, 0);
        pair.core_a.resume_transfers(pair.device_id_b.clone()).unwrap();

        assert_eq!(finish(&pair, &started.file_id, &dir_dst), original);
        assert_sender_clean(&pair, &started.file_id);
    }

    #[test]
    fn deadlines_never_sweep_a_copy_whose_row_does_not_exist_yet() {
        let pair = established_pair();
        std::fs::create_dir_all(&pair.core_a.outgoing_dir).unwrap();
        // O que `start_send` deixa em disco enquanto copia, antes de inserir a linha.
        let in_progress = staging::staging_path(&pair.core_a.outgoing_dir, &[0xAB; FILE_ID_LEN]);
        std::fs::write(&in_progress, b"pagina").unwrap();

        pair.core_a.enforce_transfer_deadlines().unwrap();
        pair.core_a.list_messages(pair.device_id_b.clone()).unwrap();
        assert!(in_progress.exists());

        // Só a abertura do cofre, quando nenhum envio pode estar copiando, varre.
        pair.core_a.lock().unwrap();
        pair.core_a.unlock().unwrap();
        assert!(!in_progress.exists());
    }

    /// Um handle já pronto para a Core de `pair.core_a`, montado a partir da
    /// linha e da cópia do envio `started`.
    fn rebuilt_send(pair: &EstablishedPair, started: &SendFileStartedDto) -> TransferHandle {
        let stored = pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().unwrap();
        let manifest = Manifest::decode(&stored.manifest_cbor).unwrap();
        let reader = outgoing::open_outgoing_copy(&pair.core_a.outgoing_dir, &manifest, &stored.transfer_secret).unwrap();
        TransferHandle::Send(OutgoingHandle::new(manifest, stored.kind, &stored.transfer_secret, reader, 0, false))
    }

    #[test]
    fn a_handle_rebuilt_across_a_lock_is_not_installed() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let path = write_temp_file(&dir_src, "a.bin", &[4u8; 3_000]);
        let started = pair.core_a.start_send_file(pair.device_id_b.clone(), path, false).unwrap();
        let handle = rebuilt_send(&pair, &started);

        pair.core_a.lock().unwrap();

        assert!(!pair.core_a.install_handle(fid(&started.file_id), handle, None).unwrap());
        assert!(pair.core_a.lock_transfers().unwrap().is_empty());
    }

    #[test]
    fn a_handle_for_a_transfer_that_ended_meanwhile_is_not_installed() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let path = write_temp_file(&dir_src, "a.bin", &[4u8; 3_000]);
        let started = pair.core_a.start_send_file(pair.device_id_b.clone(), path, false).unwrap();
        let handle = rebuilt_send(&pair, &started);

        pair.core_a.cancel_transfer(started.file_id.clone()).unwrap();

        assert!(!pair.core_a.install_handle(fid(&started.file_id), handle, None).unwrap());
        assert!(pair.core_a.transfer_progress(started.file_id.clone()).unwrap().is_none());
    }

    #[test]
    fn one_unresumable_send_does_not_hold_back_the_others() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let mut started = Vec::new();
        for name in ["a.bin", "b.bin"] {
            let path = write_temp_file(&dir_src, name, &[5u8; 3_000]);
            started.push(pair.core_a.start_send_file(pair.device_id_b.clone(), path, false).unwrap());
        }
        pair.core_a.lock().unwrap();
        std::fs::remove_file(staging::staging_path(&pair.core_a.outgoing_dir, &fid(&started[0].file_id))).unwrap();
        pair.core_a.unlock().unwrap();
        reconnect(&pair, true);

        let resumed = pair.core_a.resume_transfers(pair.device_id_b.clone()).unwrap();

        assert_eq!(resumed.len(), 1);
        assert_eq!(resumed[0].file_id, started[1].file_id);
        assert_eq!(state_of(&pair, started[0].message_id), DeliveryStateDto::Failed);
    }

    #[test]
    fn pumping_calls_refuse_while_locked_instead_of_looking_finished() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let path = write_temp_file(&dir_src, "a.bin", &[6u8; 3_000]);
        let started = pair.core_a.start_send_file(pair.device_id_b.clone(), path, false).unwrap();

        pair.core_a.lock().unwrap();

        assert!(matches!(pair.core_a.next_outgoing_wire_chunk(started.file_id.clone()), Err(FfiError::Locked)));
        assert!(matches!(pair.core_a.transfer_progress(started.file_id), Err(FfiError::Locked)));
    }

    #[test]
    fn concurrent_resumes_of_one_receive_leave_the_staging_intact() {
        let pair = established_pair();
        let (dir_src, dir_dst) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let (started, original) = start_two_block_send(&pair, &dir_src);
        drive(&pair, &started.file_id, 1);
        pair.core_b.lock().unwrap();
        pair.core_b.unlock().unwrap();
        reconnect(&pair, false);

        // Evento de sessão e canal novo pedem a mesma retomada ao mesmo tempo.
        std::thread::scope(|scope| {
            for _ in 0..4 {
                scope.spawn(|| pair.core_b.resume_transfers(pair.device_id_a.clone()).unwrap());
            }
        });
        pair.core_a.resume_transfers(pair.device_id_b.clone()).unwrap();

        assert_eq!(finish(&pair, &started.file_id, &dir_dst), original);
        assert_sender_clean(&pair, &started.file_id);
    }

    #[test]
    fn a_rebuild_never_runs_while_the_file_id_is_claimed() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let (started, _) = start_two_block_send(&pair, &dir_src);
        let file_id = fid(&started.file_id);
        let staging = staging::staging_path(&pair.core_b.staging_dir, &file_id);

        // `finish_receive` em andamento: o handle saiu do mapa e o id está reservado.
        let (handle, claim) = pair.core_b.take_for_finish(file_id).unwrap().unwrap();
        let before = std::fs::metadata(&staging).unwrap().len();
        let resumed = pair.core_b.resume_transfers(pair.device_id_a.clone()).unwrap();

        assert!(resumed.is_empty(), "a retomada espera quem está terminando");
        assert_eq!(std::fs::metadata(&staging).unwrap().len(), before);
        drop(claim);
        drop(handle);
        assert_eq!(pair.core_b.resume_transfers(pair.device_id_a.clone()).unwrap().len(), 1);
    }

    /// `/dev/full` abre para escrita e falha em toda escrita: é o disco cheio no
    /// meio da decifragem para o destino, depois de o handle sair do mapa.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_finish_that_fails_writing_keeps_a_complete_handle_for_another_try() {
        let pair = established_pair();
        let (dir_src, dir_dst) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let original: Vec<u8> = (0..20_000u32).map(|i| (i % 251) as u8).collect();
        let path = write_temp_file(&dir_src, "a.bin", &original);
        let started = pair.core_a.start_send_file(pair.device_id_b.clone(), path, false).unwrap();
        pair.core_b.decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata).unwrap();
        drive(&pair, &started.file_id, 1);

        assert!(pair
            .core_b
            .finish_receive_file(pair.device_id_a.clone(), started.file_id.clone(), "/dev/full".to_owned())
            .is_err());

        let progress = pair.core_b.transfer_progress(started.file_id.clone()).unwrap().unwrap();
        assert!(progress.is_complete, "o handle volta ao mapa, completo");
        assert!(pair.core_b.transfer_claims.lock().unwrap().is_empty());
        assert!(pair.core_b.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_some());
        assert_eq!(finish(&pair, &started.file_id, &dir_dst), original, "só decifra de novo");
        assert_sender_clean(&pair, &started.file_id);
    }

    #[test]
    fn a_committed_file_survives_a_file_complete_that_cannot_be_sealed() {
        let pair = established_pair();
        let (dir_src, dir_dst) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let original: Vec<u8> = (0..20_000u32).map(|i| (i % 251) as u8).collect();
        let path = write_temp_file(&dir_src, "a.bin", &original);
        let started = pair.core_a.start_send_file(pair.device_id_b.clone(), path, false).unwrap();
        pair.core_b.decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata).unwrap();
        drive(&pair, &started.file_id, 1);
        pair.core_b.lock_sessions().unwrap().clear();

        let dst = dir_dst.path().join("recebido.bin");
        let sealed = pair
            .core_b
            .finish_receive_file(pair.device_id_a.clone(), started.file_id.clone(), dst.to_str().unwrap().to_owned())
            .unwrap();

        assert!(sealed.is_none(), "sem sessão, o aviso se perde");
        assert_eq!(std::fs::read(dst).unwrap(), original, "mas o arquivo fica");
        assert!(pair.core_b.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_none());
    }

    #[test]
    fn a_rebuild_releases_its_claim_when_the_handle_goes_in() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let (started, _) = start_two_block_send(&pair, &dir_src);
        drive(&pair, &started.file_id, 1);
        pair.core_b.lock().unwrap();
        pair.core_b.unlock().unwrap();
        reconnect(&pair, false);

        pair.core_b.resume_transfers(pair.device_id_a.clone()).unwrap();

        assert!(pair.core_b.transfer_claims.lock().unwrap().is_empty());
        let (handle, claim) = pair.core_b.take_for_finish(fid(&started.file_id)).unwrap().unwrap();
        drop(claim);
        drop(handle);
    }

    #[test]
    fn an_in_step_feedback_pins_the_generation_against_later_late_ones() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let (started, _) = start_two_block_send(&pair, &dir_src);
        let early = pair.core_b.file_feedback(pair.device_id_a.clone(), started.file_id.clone()).unwrap();
        drive(&pair, &started.file_id, 1);
        // A sessão de A troca (o par reabriu) sem que B fique para trás.
        if let Some(TransferHandle::Send(send)) = pair.core_a.lock_transfers().unwrap().get_mut(&fid(&started.file_id)) {
            send.generation = u32::MAX;
        }
        let in_step = pair.core_b.file_feedback(pair.device_id_a.clone(), started.file_id.clone()).unwrap();
        pair.core_a.receive_incoming(pair.device_id_b.clone(), in_step).unwrap();

        pair.core_a.receive_incoming(pair.device_id_b.clone(), early).unwrap();

        assert_eq!(pair.core_a.transfer_progress(started.file_id.clone()).unwrap().unwrap().blocks_done, 1);
    }
}
