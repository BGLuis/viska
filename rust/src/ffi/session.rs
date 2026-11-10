//! Superfície FFI de sessão e mensagem — Fase 3, F2.
//!
//! O núcleo Rust é síncrono por desenho (`viska_proto` não depende de nenhum
//! runtime assíncrono). Todo evento de rede — canal abriu, bytes chegaram —
//! nasce do lado Dart (`flutter_webrtc`/`mqtt_client`, Fase 3 F3/F4), que
//! então chama estes métodos de forma síncrona; os métodos abaixo são
//! request/response comuns, que o `flutter_rust_bridge` já despacha em thread
//! própria e devolve como `Future` ao Dart automaticamente.
//!
//! Única exceção: [`Core::subscribe_session_events`]. O estado de uma sessão
//! muda dentro do Rust sem que o Dart tenha chamado nada (o limiar de falhas
//! de AEAD leva a `Failed`, §11.1), então aqui há algo que só o Rust sabe e
//! precisa empurrar. É o único `StreamSink` do crate; não o replique para o
//! que o Dart já consegue descobrir perguntando.

use std::collections::HashMap;
use std::sync::MutexGuard;

use crate::ffi::core::Core;
use crate::ffi::error::FfiError;
use crate::ffi::types::{
    DeliveryStateDto, IncomingMessageDto, MessageDirectionDto, MessageDto, MessageKindDto,
    SealedMessageDto, SessionStateEventDto, SessionStateKind, SessionStatusDto,
};
use crate::frb_generated::StreamSink;
use crate::session_events::{PublishOnExit, SessionEventSink};
use viska_proto::crypto::identity::DEVICE_ID_LEN;
use viska_proto::session::Session;
use viska_proto::store::transfers::Direction as TransferDirection;
use viska_proto::wire::packet_type::PacketType;
use viska_proto::wire::transport::Transport;

fn to_device_id(bytes: Vec<u8>) -> Result<[u8; DEVICE_ID_LEN], FfiError> {
    bytes.try_into().map_err(|_| FfiError::Internal)
}

impl Core {
    /// Abre (ou devolve, se já existir) a sessão com um contato pareado.
    ///
    /// Idempotente: chamadas repetidas para o mesmo contato nunca reabrem o
    /// handshake. `outgoing_handshake` vem preenchido em toda chamada feita
    /// enquanto formos iniciador e ainda não tivermos recebido a RESP — não
    /// só na primeira — porque mais de uma parte do app pode precisar desses
    /// bytes em momentos diferentes (o transporte WebRTC, para decidir quem
    /// oferta o SDP; o controlador de chat, para de fato publicar a mensagem
    /// de handshake assim que o canal abrir). Ver
    /// `viska_proto::session::Session::pending_outgoing_handshake`.
    pub fn ensure_session(&self, peer_device_id: Vec<u8>) -> Result<SessionStatusDto, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);
        let mut sessions = self.lock_sessions()?;

        if let Some(session) = sessions.get(&device_id) {
            return Ok(status_dto(session));
        }

        self.open_session(&mut sessions, device_id)
    }

    /// Descarta a sessão `Failed` (ou que passou do limiar de §11.2) e abre
    /// uma nova com o mesmo contato — o que `ensure_session` nunca faz.
    ///
    /// Só age quando a sessão realmente não serve: com ela `Established` sã ou
    /// em handshake, devolve o status atual sem tocar em nada, para um toque
    /// repetido na UI não derrubar uma sessão que acabou de se restabelecer.
    ///
    /// O reset é local. O par não é avisado (não há marcador de tipo no fio,
    /// D4): se ele seguir `Established`, a INIT nova só vale depois que a
    /// sessão dele também falhar. Ver `docs/protocol.md` §11.1.
    ///
    /// Efeitos: textos em `Sending` voltam à fila (foram cifrados na sessão
    /// antiga e `flush_pending` os cifra de novo); envios de arquivo e voz em
    /// andamento com este contato são cancelados e marcados como falha, porque
    /// o `FILE_METADATA` foi selado na sessão que deixou de existir.
    pub fn reset_session(&self, peer_device_id: Vec<u8>) -> Result<SessionStatusDto, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);
        let status = {
            let mut sessions = self.lock_sessions()?;
            if let Some(session) = sessions.get(&device_id) {
                if !session.is_failed() && !session.needs_rehandshake() {
                    return Ok(status_dto(session));
                }
                sessions.remove(&device_id);
            }
            self.open_session(&mut sessions, device_id)?
        };

        self.abort_outgoing_transfers(&device_id)?;
        self.store.requeue_sending_messages_for_contact(&device_id)?;
        Ok(status)
    }

    /// Cancela os envios de arquivo e voz deste contato e falha as linhas.
    fn abort_outgoing_transfers(&self, device_id: &[u8; DEVICE_ID_LEN]) -> Result<(), FfiError> {
        let outgoing = self
            .store
            .list_file_transfers_for_contact(device_id, TransferDirection::Sending)?;
        {
            let mut transfers = self.transfers.lock().map_err(|_| FfiError::Internal)?;
            for transfer in &outgoing {
                transfers.remove(&transfer.file_id);
            }
        }
        for transfer in &outgoing {
            self.store.delete_file_transfer(&transfer.file_id)?;
        }
        let active: std::collections::HashSet<_> =
            self.store.list_active_file_transfer_ids()?.into_iter().collect();
        viska_proto::file::staging::sweep_orphaned(&self.staging_dir, &active)?;
        self.store.fail_pending_transfers_for_contact(device_id)?;
        Ok(())
    }

    /// Passa a receber os eventos de mudança de estado das sessões, a partir
    /// do estado atual de cada uma (replay): um evento emitido antes da
    /// assinatura não se perderia para o Dart. Uma nova assinatura substitui
    /// a anterior.
    pub fn subscribe_session_events(
        &self,
        sink: StreamSink<SessionStateEventDto>,
    ) -> Result<(), FfiError> {
        self.set_session_event_sink(Box::new(move |event| {
            // Erro aqui é o Dart já ter fechado o stream: nada a fazer.
            let _ = sink.add(event);
        }))
    }

    /// Núcleo de [`Self::subscribe_session_events`], sem o `StreamSink`, para
    /// que os testes observem os eventos sem subir a ponte.
    pub(crate) fn set_session_event_sink(
        &self,
        sink: SessionEventSink,
    ) -> Result<(), FfiError> {
        let sessions = self.sessions.lock().map_err(|_| FfiError::Internal)?;
        let mut events = self.session_events.lock().map_err(|_| FfiError::Internal)?;
        events.set_sink(
            sink,
            sessions.iter().map(|(id, session)| (*id, Some(snapshot(session)))),
        );
        Ok(())
    }

    /// Emite o estado atual da sessão de `device_id` se ele mudou desde o
    /// último evento entregue.
    pub(crate) fn publish_session(&self, device_id: &[u8; DEVICE_ID_LEN]) {
        let (Ok(sessions), Ok(mut events)) = (self.sessions.lock(), self.session_events.lock())
        else {
            return;
        };
        events.publish(device_id, sessions.get(device_id).map(snapshot));
    }

    /// Como [`Self::publish_session`] para todos os contatos já entregues —
    /// usado quando as sessões somem de uma vez (bloqueio do cofre).
    pub(crate) fn publish_all_sessions(&self) {
        let (Ok(sessions), Ok(mut events)) = (self.sessions.lock(), self.session_events.lock())
        else {
            return;
        };
        for id in events.published_ids() {
            events.publish(&id, sessions.get(&id).map(snapshot));
        }
    }

    /// Publica o estado da sessão ao sair do escopo, por qualquer caminho
    /// (inclusive `?`): as transições nascem em pontos demais para lembrar de
    /// chamar `publish_session` em cada `return`.
    pub(crate) fn publish_on_exit(&self, device_id: [u8; DEVICE_ID_LEN]) -> PublishOnExit<'_> {
        PublishOnExit { core: self, device_id }
    }

    /// Abre a sessão com um contato pareado e a registra em `sessions`.
    fn open_session(
        &self,
        sessions: &mut HashMap<[u8; 16], Session>,
        device_id: [u8; DEVICE_ID_LEN],
    ) -> Result<SessionStatusDto, FfiError> {
        let (peer, _, _, _) = self
            .store
            .find_contact(&device_id)?
            .ok_or(FfiError::ContactNotFound)?;
        let suite_id = self.store.get_contact_suite_id(&device_id)?;
        let upgrade_suite = self
            .agreed_upgrades
            .lock()
            .ok()
            .and_then(|mut m| m.remove(&device_id));
        let id = self.identity.read().map_err(|_| FfiError::Internal)?;
        let (session, _) = Session::open_with_upgrade(&id, peer, suite_id, upgrade_suite)?;
        let status = status_dto(&session);
        sessions.insert(device_id, session);
        Ok(status)
    }

    /// Alimenta a sessão com uma mensagem de handshake recebida via
    /// sinalização (INIT ou RESP, conforme o estado atual). Devolve os bytes
    /// de resposta a publicar, se houver.
    ///
    /// Erra com `FfiError::NoActiveSession` se `ensure_session` não tiver
    /// sido chamado antes para este contato — este método nunca cria uma
    /// sessão sozinho: o papel (quem inicia) já foi decidido no momento em
    /// que a sessão foi aberta, e recriá-la aqui poderia escolher o papel
    /// errado dependendo só de qual mensagem chegou primeiro.
    pub fn feed_handshake(
        &self,
        peer_device_id: Vec<u8>,
        bytes: Vec<u8>,
    ) -> Result<Option<Vec<u8>>, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);
        let mut sessions = self.lock_sessions()?;
        let session = sessions
            .get_mut(&device_id)
            .ok_or(FfiError::NoActiveSession)?;

        let id = self.identity.read().map_err(|_| FfiError::Internal)?;
        let resp = session.process_handshake_message(&id, &bytes)?;
        let recorded = self.store.get_contact_suite_id(&device_id)?;
        if session.should_upgrade_contact(recorded) {
            let _ = self.store.set_contact_suite_id(&device_id, session.current_suite());
        }
        Ok(resp)
    }

    /// Cifra um pacote `CONTROL_SUITES` para publicação no canal de dados (§6.2, `0x42`).
    pub fn build_control_suites(
        &self,
        peer_device_id: Vec<u8>,
    ) -> Result<Option<Vec<u8>>, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);
        let mut sessions = self.lock_sessions()?;
        let session = sessions
            .get_mut(&device_id)
            .ok_or(FfiError::NoActiveSession)?;
        if !session.is_established() {
            return Ok(None);
        }
        match session.build_control_suites(Transport::DataChannel) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(viska_proto::Error::SuiteRetired(_)) => Err(FfiError::SuiteRetired),
            Err(_) => Ok(None),
        }
    }

    /// Cifra `body` como `MSG_TEXT` e persiste como `pending` antes de
    /// qualquer tentativa de envio — eco otimista: a UI mostra a mensagem
    /// mesmo que o transporte esteja indisponível no momento da chamada.
    ///
    /// `bytes` do DTO devolvido vem `None` quando a sessão ainda não está
    /// `Established` ou ainda não tem cadeia de envio (o respondedor só a
    /// ganha ao processar a primeira mensagem do iniciador): a mensagem já
    /// está persistida, e `flush_pending` a entrega assim que isso mudar.
    /// Quando devolve bytes, a linha passa a `Sending`; quem não conseguir
    /// enviá-los deve chamar `requeue_message`.
    pub fn seal_outgoing_text(
        &self,
        peer_device_id: Vec<u8>,
        body: String,
    ) -> Result<SealedMessageDto, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);
        let created_at = viska_proto::util::time::unix_seconds() as i64;

        // Se o corpo for uma reação, vincula à mensagem no banco local:
        if let Some((target_id, emoji)) = viska_proto::store::messages::parse_reaction_metadata(&body) {
            let _ = self.store.add_reaction_by_target(&target_id, &device_id, &emoji, created_at);
        }

        let message_id = self.store.insert_pending_message(
            &device_id,
            PacketType::MsgText,
            &body,
            created_at,
        )?;

        let mut sessions = self.lock_sessions()?;
        let bytes = match sessions.get_mut(&device_id) {
            Some(session) if session.is_established() => {
                let ciphertext = session
                    .encrypt_outgoing(PacketType::MsgText, body.into_bytes(), Transport::DataChannel)
                    .ok()
                    // Sem conseguir marcar `Sending`, os bytes não podem sair:
                    // a linha segue `Pending` e `flush_pending` a cifra de novo
                    // (o contador gasto aqui é só um salto no ratchet).
                    .filter(|_| self.store.mark_message_sending(message_id).is_ok());
                if let Some(ref ct) = ciphertext {
                    if let Ok(cnt) = viska_proto::wire::envelope::counter(ct) {
                        let _ = self.store.update_message_ratchet_counter(message_id, cnt as i64);
                    }
                }
                ciphertext
            }
            _ => None,
        };

        Ok(SealedMessageDto { message_id, bytes })
    }

    /// Decifra um envelope recebido no `DataChannel`.
    ///
    /// `Ok(None)` cobre qualquer falha de decifragem — a mesma política de
    /// `Session::decrypt_incoming`, nenhuma causa diferenciada por fora.
    /// `MSG_TYPING` nunca é persistido (`docs/protocol.md` §6.2): devolve um
    /// DTO efêmero, sem `message_id`.
    ///
    /// `FILE_METADATA`/`FILE_FEEDBACK`/`FILE_COMPLETE` (Fase 4) são
    /// processados aqui como efeito colateral — inicia/atualiza/encerra o
    /// que está em `Core::transfers`/`store::transfers` — e sempre devolvem
    /// `Ok(None)`: não há DTO de mensagem para eles, e mudar a assinatura
    /// deste método para acomodar isso quebraria `chat_controller.dart`
    /// sem necessidade. Quem quer saber de uma oferta de arquivo nova chama
    /// `Core::pending_file_offers` depois. Falha ao processar um desses três
    /// (CBOR malformado, `file_id` desconhecido) é silenciada — mesma
    /// política de silêncio de qualquer corpo malformado nesta fronteira, e
    /// nunca deveria acontecer vindo de um par honesto.
    ///
    /// `FILE_SYMBOL` nunca chega aqui: contorna `Session` por completo (ver
    /// `viska_proto::file::transfer`, doc do módulo) — chega pelo canal
    /// `file` do WebRTC, direto em `Core::ingest_incoming_file_symbol`.
    pub fn decrypt_incoming(
        &self,
        peer_device_id: Vec<u8>,
        envelope: Vec<u8>,
    ) -> Result<Option<IncomingMessageDto>, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);
        let mut sessions = self.lock_sessions()?;
        let session = sessions
            .get_mut(&device_id)
            .ok_or(FfiError::NoActiveSession)?;
        let inner = session.decrypt_incoming(&envelope, Transport::DataChannel)?;
        if let Some(upgrade) = session.agreed_upgrade_suite() {
            if let Ok(mut upgrades) = self.agreed_upgrades.lock() {
                upgrades.insert(device_id, upgrade);
            }
        }
        let should_upgrade = session.should_upgrade_contact(
            self.store.get_contact_suite_id(&device_id).unwrap_or(0),
        );
        let current_suite = session.current_suite();
        if should_upgrade {
            let _ = self.store.set_contact_suite_id(&device_id, current_suite);
        }

        let Some(inner) = inner else {
            return Ok(None);
        };
        // Libera o lock de sessões antes de tocar o banco — as duas coisas
        // não precisam do mesmo lock, e segurar um enquanto se espera o
        // outro é desnecessário.
        drop(sessions);

        let received_at = viska_proto::util::time::unix_seconds() as i64;
        match inner.packet_type {
            PacketType::MsgText => {
                let body = String::from_utf8(inner.body).map_err(|_| FfiError::Internal)?;

                // Se o corpo for uma reação, vincula à mensagem no banco local:
                if let Some((target_id, emoji)) = viska_proto::store::messages::parse_reaction_metadata(&body) {
                    let _ = self.store.add_reaction_by_target(&target_id, &device_id, &emoji, received_at);
                    return Ok(Some(IncomingMessageDto {
                        message_id: None,
                        body,
                        is_typing: false,
                        received_at_unix_secs: received_at,
                    }));
                }

                let message_id = self.store.insert_incoming_message(
                    &device_id,
                    PacketType::MsgText,
                    &body,
                    received_at,
                )?;
                if let Ok(cnt) = viska_proto::wire::envelope::counter(&envelope) {
                    let _ = self.store.update_message_ratchet_counter(message_id, cnt as i64);
                }
                Ok(Some(IncomingMessageDto {
                    message_id: Some(message_id),
                    body,
                    is_typing: false,
                    received_at_unix_secs: received_at,
                }))
            }
            PacketType::MsgReceipt => {
                if let Some(target_id) = viska_proto::store::messages::parse_receipt_target_id(&inner.body) {
                    let _ = self.store.mark_delivered_by_target(&target_id, &device_id);
                }
                Ok(None)
            }
            PacketType::MsgTyping => Ok(Some(IncomingMessageDto {
                message_id: None,
                body: String::new(),
                is_typing: true,
                received_at_unix_secs: received_at,
            })),
            PacketType::FileMetadata => {
                let _ = self.handle_incoming_file_metadata(device_id, zeroize::Zeroizing::new(inner.body));
                Ok(None)
            }
            PacketType::FileFeedback => {
                let _ = self.handle_incoming_file_feedback(inner.body);
                Ok(None)
            }
            PacketType::FileComplete => {
                let _ = self.handle_incoming_file_complete(inner.body);
                Ok(None)
            }
            PacketType::FileReject => {
                let _ = self.handle_incoming_file_reject(device_id, inner.body);
                Ok(None)
            }
            _ => Ok(None),
        }
    }

    /// Cifra e empacota um recibo de entrega (MSG_RECEIPT) confirmando o recebimento de uma mensagem.
    pub fn seal_outgoing_receipt(
        &self,
        peer_device_id: Vec<u8>,
        target_id: String,
    ) -> Result<SealedMessageDto, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);
        let mut sessions = self.lock_sessions()?;
        let session = sessions
            .get_mut(&device_id)
            .ok_or(FfiError::NoActiveSession)?;

        let payload = format!(r#"{{"v":1,"type":"receipt","targetId":"{}"}}"#, target_id);
        let bytes = session
            .encrypt_outgoing(
                PacketType::MsgReceipt,
                payload.into_bytes(),
                Transport::DataChannel,
            )
            .ok();

        Ok(SealedMessageDto {
            message_id: 0,
            bytes,
        })
    }

    /// Marca uma mensagem de saída como entregue ao transporte — chamar só
    /// depois que o envio de rede (`RTCDataChannel.send` ou equivalente) não
    /// lançar erro.
    pub fn mark_message_sent(&self, message_id: i64) -> Result<(), FfiError> {
        self.store.mark_message_sent(message_id)?;
        Ok(())
    }

    /// Devolve à fila uma mensagem que foi cifrada mas não chegou a sair
    /// (`sendToContact` falhou), para a próxima drenagem tentá-la de novo.
    /// Só afeta mensagens `sending`.
    pub fn requeue_message(&self, message_id: i64) -> Result<(), FfiError> {
        self.store.requeue_message(message_id)?;
        Ok(())
    }

    /// Marca uma mensagem de saída como falha — chamar quando o envio de um
    /// arquivo é interrompido por queda do transporte. Só afeta mensagens
    /// ainda `pending`.
    pub fn mark_message_failed(&self, message_id: i64) -> Result<(), FfiError> {
        self.store.mark_message_failed(message_id)?;
        Ok(())
    }

    /// Marca uma mensagem de saída como confirmada pelo par (via MSG_RECEIPT).
    pub fn mark_message_delivered(&self, message_id: i64) -> Result<(), FfiError> {
        self.store.mark_message_delivered(message_id)?;
        Ok(())
    }

    /// Cifra todas as mensagens `pending` de um contato — chamar quando o
    /// transporte reabre (reconexão do `DataChannel`) ou a sessão termina de
    /// estabelecer. Para na primeira falha de cifragem (ex.:
    /// `needs_rehandshake`): as mensagens seguintes continuam `pending` para
    /// a próxima tentativa, em vez de pular uma no meio da fila e quebrar a
    /// ordem de entrega.
    pub fn flush_pending(
        &self,
        peer_device_id: Vec<u8>,
    ) -> Result<Vec<SealedMessageDto>, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);
        // Listar sob o lock de sessões: duas drenagens concorrentes não podem
        // ver a mesma linha `Pending` antes de a primeira marcá-la `Sending`.
        let mut sessions = self.lock_sessions()?;
        let pending = self.store.list_pending_messages(&device_id)?;
        if pending.is_empty() {
            return Ok(Vec::new());
        }

        let session = sessions
            .get_mut(&device_id)
            .ok_or(FfiError::NoActiveSession)?;
        if !session.is_established() {
            return Ok(Vec::new());
        }

        let mut sealed = Vec::with_capacity(pending.len());
        for message in pending {
            match session.encrypt_outgoing(
                PacketType::MsgText,
                message.body.into_bytes(),
                Transport::DataChannel,
            ) {
                Ok(bytes) => {
                    // Falhar ao marcar não pode descartar o que já foi
                    // selado: as linhas anteriores estão `Sending` e perderiam
                    // seus bytes. Esta segue `Pending` para a próxima drenagem.
                    if self.store.mark_message_sending(message.id).is_err() {
                        break;
                    }
                    sealed.push(SealedMessageDto {
                        message_id: message.id,
                        bytes: Some(bytes),
                    });
                }
                Err(_) => break,
            }
        }
        Ok(sealed)
    }

    /// Status atual da sessão com um contato, sem alterar nada — `None` se
    /// `ensure_session` nunca foi chamado para ele.
    pub fn session_status(
        &self,
        peer_device_id: Vec<u8>,
    ) -> Result<Option<SessionStatusDto>, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        let sessions = self.lock_sessions()?;
        Ok(sessions.get(&device_id).map(status_dto))
    }

    /// Mensagens de um contato com paginação opcional (`since_id`, `limit`).
    pub fn list_messages_paginated(
        &self,
        peer_device_id: Vec<u8>,
        since_id: Option<i64>,
        limit: Option<usize>,
    ) -> Result<Vec<MessageDto>, FfiError> {
        self.ensure_not_locked()?;
        let device_id = to_device_id(peer_device_id)?;
        let stored = self.store.list_messages_paginated(&device_id, since_id, limit)?;
        Ok(stored.into_iter().map(message_dto).collect())
    }

    /// Todas as mensagens já trocadas com um contato, mais antigas primeiro
    /// — histórico completo para a tela de chat abrir com.
    pub fn list_messages(&self, peer_device_id: Vec<u8>) -> Result<Vec<MessageDto>, FfiError> {
        self.list_messages_paginated(peer_device_id, None, None)
    }

    pub(super) fn lock_sessions(&self) -> Result<MutexGuard<'_, HashMap<[u8; 16], Session>>, FfiError> {
        self.ensure_not_locked()?;
        self.sessions.lock().map_err(|_| FfiError::Internal)
    }
}

/// `message.packet_type` só é `MsgText` ou `AudioChunk` (Fase 5) — os
/// únicos dois que `store::messages::reject_typing` deixa passar. Para
/// `AudioChunk`, `body` é `hex(file_id)` (convenção de `ffi/transfer.rs`,
/// que é quem escreve essas linhas) — um valor que não decodifica como hex
/// vira `audio_file_id: None` em vez de erro, mesma política de "nunca
/// panica com dado próprio corrompido" do resto da fronteira FFI.
fn message_dto(message: viska_proto::store::messages::StoredMessage) -> MessageDto {
    let direction = match message.direction {
        viska_proto::store::messages::Direction::Outgoing => MessageDirectionDto::Outgoing,
        viska_proto::store::messages::Direction::Incoming => MessageDirectionDto::Incoming,
    };
    let delivery_state = match message.delivery_state {
        viska_proto::store::messages::DeliveryState::Pending => DeliveryStateDto::Pending,
        viska_proto::store::messages::DeliveryState::Sent => DeliveryStateDto::Sent,
        viska_proto::store::messages::DeliveryState::Delivered => DeliveryStateDto::Delivered,
        viska_proto::store::messages::DeliveryState::Failed => DeliveryStateDto::Failed,
        viska_proto::store::messages::DeliveryState::Sending => DeliveryStateDto::Sending,
        viska_proto::store::messages::DeliveryState::Rejected => DeliveryStateDto::Rejected,
    };

    let (kind, body, audio_file_id) =
        if message.packet_type == viska_proto::wire::packet_type::PacketType::AudioChunk {
            (MessageKindDto::VoiceNote, String::new(), hex::decode(&message.body).ok())
        } else if message.packet_type == viska_proto::wire::packet_type::PacketType::FileMetadata {
            (MessageKindDto::File, message.body, None)
        } else {
            (MessageKindDto::Text, message.body, None)
        };

    MessageDto {
        id: message.id,
        global_id: message.global_id,
        direction,
        kind,
        body,
        audio_file_id,
        delivery_state,
        created_at_unix_secs: message.created_at_unix_secs,
        is_ephemeral: message.is_ephemeral,
        reply_to_id: message.reply_to_id,
        view_once: message.view_once,
        reactions: message.reactions,
    }
}

fn snapshot(session: &Session) -> (SessionStateKind, bool) {
    let status = status_dto(session);
    (status.state, status.needs_rehandshake)
}

fn status_dto(session: &Session) -> SessionStatusDto {
    let state = if session.is_failed() {
        SessionStateKind::Failed
    } else if session.is_established() {
        SessionStateKind::Established
    } else {
        SessionStateKind::Handshaking
    };
    let outgoing_handshake = session.pending_outgoing_handshake().map(<[u8]>::to_vec);

    SessionStatusDto {
        state,
        needs_rehandshake: session.needs_rehandshake(),
        outgoing_handshake,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::core::Core;

    fn open_core(dir: &tempfile::TempDir) -> Core {
        Core::open(dir.path().to_str().unwrap().to_owned()).unwrap()
    }

    /// Duas `Core` pareadas, cada uma com o `device_id` da outra (capturado
    /// do `ContactDto` que o próprio pareamento devolve, não recalculado à
    /// mão a partir do QR).
    struct PairedCores {
        _dir_a: tempfile::TempDir,
        core_a: Core,
        device_id_a: Vec<u8>,
        _dir_b: tempfile::TempDir,
        core_b: Core,
        device_id_b: Vec<u8>,
    }

    fn paired_pair() -> PairedCores {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let core_a = open_core(&dir_a);
        let core_b = open_core(&dir_b);
        let contact_a_seen_by_b = core_b.pair_from_qr(core_a.my_qr_payload(), None).unwrap();
        let contact_b_seen_by_a = core_a.pair_from_qr(core_b.my_qr_payload(), None).unwrap();

        let mut result = PairedCores {
            _dir_a: dir_a,
            core_a,
            device_id_a: contact_a_seen_by_b.device_id,
            _dir_b: dir_b,
            core_b,
            device_id_b: contact_b_seen_by_a.device_id,
        };

        // `LocalIdentity::generate` é aleatória, então sem isso metade das
        // execuções teria "a" como respondedora — que não pode enviar nada
        // antes de processar a primeira mensagem do iniciador (mesmo motivo
        // do `pair()` em `viska_proto::session::tests`). Garantir que "a" é
        // sempre quem inicia deixa os testes que mandam uma mensagem logo
        // após `establish()` determinísticos.
        if !result
            .core_a
            .identity
            .read()
            .unwrap()
            .public()
            .is_before(&result.core_b.identity.read().unwrap().public())
        {
            std::mem::swap(&mut result.core_a, &mut result.core_b);
            std::mem::swap(&mut result.device_id_a, &mut result.device_id_b);
            std::mem::swap(&mut result._dir_a, &mut result._dir_b);
        }

        result
    }

    /// Completa o handshake entre dois `Core` já pareados, trocando os bytes
    /// de sessão diretamente (sem sinalização de verdade) — mesmo caminho
    /// que `webrtc_transport`/`mqtt.dart` vão seguir na Fase 3 completa.
    fn establish(core_a: &Core, device_id_a: Vec<u8>, core_b: &Core, device_id_b: Vec<u8>) {
        let status_a = core_a.ensure_session(device_id_b.clone()).unwrap();
        let status_b = core_b.ensure_session(device_id_a.clone()).unwrap();

        // Exatamente um dos dois é iniciador — `pair()` não garante ordem
        // aqui como em `viska_proto::session::tests`, então descobrimos qual
        // é qual pelo DTO.
        // `initiator_peer`/`responder_peer` são o `device_id` que cada lado
        // usa para se referir à SESSÃO com o outro — nunca o próprio
        // `device_id` (o mapa de sessões de cada `Core` é indexado pelo
        // `device_id` do par, não pelo seu próprio).
        let (initiator_core, initiator_peer, responder_core, responder_peer, init) =
            match (status_a.outgoing_handshake, status_b.outgoing_handshake) {
                (Some(init), None) => (core_a, device_id_b, core_b, device_id_a, init),
                (None, Some(init)) => (core_b, device_id_a, core_a, device_id_b, init),
                other => panic!("exatamente um dos dois deveria ser iniciador: {other:?}"),
            };

        let resp = responder_core
            .feed_handshake(responder_peer, init)
            .unwrap()
            .expect("respondedor sempre devolve a RESP");
        let none = initiator_core.feed_handshake(initiator_peer, resp).unwrap();
        assert!(none.is_none());
    }

    #[test]
    fn ensure_session_is_idempotent_and_never_reopens_handshake() {
        let p = paired_pair();

        let first = p.core_a.ensure_session(p.device_id_b.clone()).unwrap();
        let second = p.core_a.ensure_session(p.device_id_b).unwrap();

        // `paired_pair()` não controla quem é iniciador (ao contrário do
        // `pair()` de `viska_proto::session::tests`), então este teste
        // cobre os dois papéis possíveis: enquanto a RESP não chega,
        // `outgoing_handshake` é estável — sempre `None` para quem
        // responde, sempre os mesmos bytes para quem inicia — nunca uma
        // segunda INIT diferente da primeira.
        assert_eq!(first.outgoing_handshake, second.outgoing_handshake);
        assert_eq!(first.state, second.state);
        // `paired_pair()` garante que `core_a` é sempre quem inicia.
        assert!(first.outgoing_handshake.is_some());
    }

    #[test]
    fn outgoing_handshake_clears_while_pending_and_is_none_after_establishing() {
        let p = paired_pair();

        let before = p.core_a.ensure_session(p.device_id_b.clone()).unwrap();
        assert!(
            before.outgoing_handshake.is_some(),
            "core_a é sempre iniciadora (paired_pair garante a ordem)"
        );

        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );

        let after = p.core_a.ensure_session(p.device_id_b).unwrap();
        assert_eq!(after.state, SessionStateKind::Established);
        assert_eq!(after.outgoing_handshake, None);
    }

    #[test]
    fn ensure_session_for_unknown_contact_fails() {
        let dir = tempfile::tempdir().unwrap();
        let core = open_core(&dir);
        assert_eq!(
            core.ensure_session(vec![0u8; 16]),
            Err(FfiError::ContactNotFound)
        );
    }

    #[test]
    fn feed_handshake_without_open_session_fails() {
        let dir = tempfile::tempdir().unwrap();
        let core = open_core(&dir);
        assert_eq!(
            core.feed_handshake(vec![0u8; 16], vec![0u8; 10]),
            Err(FfiError::NoActiveSession)
        );
    }

    #[test]
    fn full_handshake_establishes_session_on_both_sides() {
        let p = paired_pair();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );

        assert_eq!(
            p.core_a
                .session_status(p.device_id_b)
                .unwrap()
                .unwrap()
                .state,
            SessionStateKind::Established
        );
        assert_eq!(
            p.core_b
                .session_status(p.device_id_a)
                .unwrap()
                .unwrap()
                .state,
            SessionStateKind::Established
        );
    }

    #[test]
    fn ciphertext_from_one_side_decrypts_on_other_and_persists() {
        let p = paired_pair();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );

        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), "oi, bob".to_string())
            .unwrap();
        assert!(
            sealed.bytes.is_some(),
            "sessão já estava Established — deveria cifrar na hora"
        );

        let received = p
            .core_b
            .decrypt_incoming(p.device_id_a, sealed.bytes.unwrap())
            .unwrap()
            .expect("mensagem legítima nunca deveria ser descartada");
        assert_eq!(received.body, "oi, bob");
        assert!(!received.is_typing);
        assert!(received.message_id.is_some());
    }

    #[test]
    fn list_messages_brings_history_from_both_directions_in_order() {
        let p = paired_pair();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );

        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), "de a para b".to_string())
            .unwrap();
        p.core_b
            .decrypt_incoming(p.device_id_a.clone(), sealed.bytes.unwrap())
            .unwrap();

        let history_a = p.core_a.list_messages(p.device_id_b).unwrap();
        assert_eq!(history_a.len(), 1);
        assert_eq!(history_a[0].direction, MessageDirectionDto::Outgoing);
        assert_eq!(history_a[0].body, "de a para b");

        let history_b = p.core_b.list_messages(p.device_id_a).unwrap();
        assert_eq!(history_b.len(), 1);
        assert_eq!(history_b[0].direction, MessageDirectionDto::Incoming);
        assert_eq!(history_b[0].delivery_state, DeliveryStateDto::Delivered);
        assert_eq!(history_b[0].body, "de a para b");
    }

    #[test]
    fn list_messages_for_contact_without_messages_returns_empty() {
        let p = paired_pair();
        let history = p.core_a.list_messages(p.device_id_b).unwrap();
        assert!(history.is_empty());
    }

    #[test]
    fn message_sent_before_session_ready_stays_pending_and_flush_pending_delivers_it() {
        let p = paired_pair();

        // `seal_outgoing_text` antes mesmo de `ensure_session`: nenhuma
        // sessão em memória ainda, então `bytes` tem que vir `None`, mas a
        // mensagem já precisa estar persistida.
        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), "mensagem adiantada".to_string())
            .unwrap();
        assert!(sealed.bytes.is_none());

        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );

        let flushed = p.core_a.flush_pending(p.device_id_b).unwrap();
        assert_eq!(flushed.len(), 1);
        assert_eq!(flushed[0].message_id, sealed.message_id);
        assert!(flushed[0].bytes.is_some());
    }

    #[test]
    fn flush_pending_without_sending_chain_returns_empty_and_keeps_row_pending() {
        let p = paired_pair();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );
        // `core_b` é o respondedor: sem cadeia de envio até ler a primeira
        // mensagem do iniciador.
        let sealed = p
            .core_b
            .seal_outgoing_text(p.device_id_a.clone(), "adiantada".to_string())
            .unwrap();
        assert!(sealed.bytes.is_none());

        let flushed = p.core_b.flush_pending(p.device_id_a.clone()).unwrap();

        assert!(flushed.is_empty());
        let listed = p.core_b.list_messages(p.device_id_a).unwrap();
        assert_eq!(listed[0].delivery_state, DeliveryStateDto::Pending);
    }

    #[test]
    fn responder_pending_flushes_after_first_message_from_initiator() {
        let p = paired_pair();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );
        let sealed = p
            .core_b
            .seal_outgoing_text(p.device_id_a.clone(), "adiantada".to_string())
            .unwrap();
        let first = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), "primeira".to_string())
            .unwrap();
        p.core_b
            .decrypt_incoming(p.device_id_a.clone(), first.bytes.unwrap())
            .unwrap();

        let flushed = p.core_b.flush_pending(p.device_id_a.clone()).unwrap();

        assert_eq!(flushed.len(), 1);
        assert_eq!(flushed[0].message_id, sealed.message_id);
        assert!(flushed[0].bytes.is_some());
    }

    #[test]
    fn flush_pending_does_not_send_a_file_row_as_text() {
        let p = paired_pair();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );
        let id: [u8; 16] = p.device_id_b.clone().try_into().unwrap();
        p.core_a
            .store
            .insert_pending_message(&id, viska_proto::wire::packet_type::PacketType::FileMetadata, "segredo.pdf", 1)
            .unwrap();

        let flushed = p.core_a.flush_pending(p.device_id_b.clone()).unwrap();

        assert!(flushed.is_empty());
        let listed = p.core_a.list_messages(p.device_id_b).unwrap();
        assert_eq!(listed[0].delivery_state, DeliveryStateDto::Pending);
    }

    #[test]
    fn flush_pending_marks_rows_sending_so_a_second_flush_is_empty() {
        let p = paired_pair();
        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), "uma só vez".to_string())
            .unwrap();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );

        let first = p.core_a.flush_pending(p.device_id_b.clone()).unwrap();
        let second = p.core_a.flush_pending(p.device_id_b.clone()).unwrap();

        assert_eq!(first.len(), 1);
        assert_eq!(first[0].message_id, sealed.message_id);
        assert!(second.is_empty());
        let listed = p.core_a.list_messages(p.device_id_b).unwrap();
        assert_eq!(listed[0].delivery_state, DeliveryStateDto::Sending);
    }

    #[test]
    fn seal_outgoing_text_with_ready_chain_marks_row_sending() {
        let p = paired_pair();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );

        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), "direto".to_string())
            .unwrap();

        assert!(sealed.bytes.is_some());
        let listed = p.core_a.list_messages(p.device_id_b).unwrap();
        assert_eq!(listed[0].delivery_state, DeliveryStateDto::Sending);
    }

    #[test]
    fn requeue_message_returns_sending_row_to_the_queue() {
        let p = paired_pair();
        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), "volta".to_string())
            .unwrap();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );
        p.core_a.flush_pending(p.device_id_b.clone()).unwrap();

        p.core_a.requeue_message(sealed.message_id).unwrap();

        let again = p.core_a.flush_pending(p.device_id_b).unwrap();
        assert_eq!(again.len(), 1);
        assert_eq!(again[0].message_id, sealed.message_id);
    }

    #[test]
    fn requeue_message_does_not_demote_a_sent_row() {
        let p = paired_pair();
        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), "já saiu".to_string())
            .unwrap();
        p.core_a.mark_message_sent(sealed.message_id).unwrap();

        p.core_a.requeue_message(sealed.message_id).unwrap();

        let listed = p.core_a.list_messages(p.device_id_b).unwrap();
        assert_eq!(listed[0].delivery_state, DeliveryStateDto::Sent);
    }

    #[test]
    fn reopening_core_requeues_sending_messages() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let core_a = Core::open(dir_a.path().to_str().unwrap().to_string()).unwrap();
        let core_b = Core::open(dir_b.path().to_str().unwrap().to_string()).unwrap();
        let contact = core_a.pair_from_qr(core_b.my_qr_payload(), None).unwrap();
        let device_id: [u8; 16] = contact.device_id.clone().try_into().unwrap();
        let id = core_a
            .store
            .insert_pending_message(&device_id, viska_proto::wire::packet_type::PacketType::MsgText, "oi", 1)
            .unwrap();
        core_a.store.mark_message_sending(id).unwrap();
        drop(core_a);

        let reopened = Core::open(dir_a.path().to_str().unwrap().to_string()).unwrap();

        let listed = reopened.list_messages(contact.device_id).unwrap();
        assert_eq!(listed[0].delivery_state, DeliveryStateDto::Pending);
    }

    #[test]
    fn locking_core_requeues_sending_messages() {
        let p = paired_pair();
        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), "em voo".to_string())
            .unwrap();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );
        p.core_a.flush_pending(p.device_id_b.clone()).unwrap();

        p.core_a.lock().unwrap();
        p.core_a.unlock().unwrap();

        let listed = p.core_a.list_messages(p.device_id_b).unwrap();
        assert_eq!(listed[0].id, sealed.message_id);
        assert_eq!(listed[0].delivery_state, DeliveryStateDto::Pending);
    }

    #[test]
    fn reopening_core_fails_pending_file_sends() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let core_a = Core::open(dir_a.path().to_str().unwrap().to_string()).unwrap();
        let core_b = Core::open(dir_b.path().to_str().unwrap().to_string()).unwrap();
        let contact = core_a.pair_from_qr(core_b.my_qr_payload(), None).unwrap();
        let device_id: [u8; 16] = contact.device_id.clone().try_into().unwrap();
        let arquivo = core_a
            .store
            .insert_pending_message(&device_id, viska_proto::wire::packet_type::PacketType::FileMetadata, "a.bin", 1)
            .unwrap();
        let texto = core_a
            .store
            .insert_pending_message(&device_id, viska_proto::wire::packet_type::PacketType::MsgText, "oi", 2)
            .unwrap();
        drop(core_a);

        let reopened = Core::open(dir_a.path().to_str().unwrap().to_string()).unwrap();

        let states: Vec<_> = reopened
            .list_messages(contact.device_id)
            .unwrap()
            .into_iter()
            .map(|m| (m.id, m.delivery_state))
            .collect();
        assert!(states.contains(&(arquivo, DeliveryStateDto::Failed)));
        assert!(states.contains(&(texto, DeliveryStateDto::Pending)));
    }

    #[test]
    fn mark_message_failed_shows_up_in_listing() {
        let p = paired_pair();
        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), "x".to_string())
            .unwrap();

        p.core_a.mark_message_failed(sealed.message_id).unwrap();

        let listed = p.core_a.list_messages(p.device_id_b).unwrap();
        assert_eq!(listed[0].delivery_state, DeliveryStateDto::Failed);
    }

    #[test]
    fn mark_message_sent_does_not_error_for_existing_id() {
        let p = paired_pair();

        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b, "x".to_string())
            .unwrap();
        p.core_a.mark_message_sent(sealed.message_id).unwrap();
    }

    #[test]
    fn tampered_envelope_is_discarded_as_none_without_persisting() {
        let p = paired_pair();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );

        let mut sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b, "sera adulterada".to_string())
            .unwrap()
            .bytes
            .unwrap();
        let last = sealed.len() - 1;
        sealed[last] ^= 0xff;

        let result = p.core_b.decrypt_incoming(p.device_id_a, sealed).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn view_once_message_is_destroyed_on_mark_message_read() {
        let p = paired_pair();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );

        let view_once_payload = r#"{"v":1,"type":"text","text":"segredo efêmero","viewOnce":true}"#;
        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), view_once_payload.to_string())
            .unwrap();
        let incoming = p
            .core_b
            .decrypt_incoming(p.device_id_a.clone(), sealed.bytes.unwrap())
            .unwrap()
            .expect("mensagem válida deve ser decifrada");

        let msg_id = incoming.message_id.expect("deve ter message_id");

        // Antes de ler: corpo íntegro e flag view_once ativo
        let history = p.core_b.list_messages(p.device_id_a.clone()).unwrap();
        assert_eq!(history.len(), 1);
        assert!(history[0].view_once);
        assert_eq!(history[0].body, view_once_payload);

        // Marca como lida
        p.core_b.mark_message_read(msg_id).unwrap();

        // Após leitura: list_messages devolve o marcador de expirada
        let history_after = p.core_b.list_messages(p.device_id_a).unwrap();
        assert_eq!(history_after.len(), 1);
        assert!(history_after[0].view_once);
        assert_eq!(history_after[0].body, "<mensagem expirada e destruída>");
    }

    #[test]
    fn reactions_target_global_id_across_cores_with_different_message_counts() {
        let p = paired_pair();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );

        let dev_b: [u8; 16] = p.device_id_b.clone().try_into().unwrap();
        let dev_a: [u8; 16] = p.device_id_a.clone().try_into().unwrap();

        // 1. Cria contagens diferentes de mensagens prévias nos dois bancos
        for i in 1..=2 {
            p.core_a.store.insert_pending_message(
                &dev_b,
                PacketType::MsgText,
                &format!("msg prévia A {}", i),
                1000 + i,
            ).unwrap();
        }

        for i in 1..=5 {
            p.core_b.store.insert_pending_message(
                &dev_a,
                PacketType::MsgText,
                &format!("msg prévia B {}", i),
                1000 + i,
            ).unwrap();
        }

        // 2. A envia uma mensagem com identificador global único no corpo
        let global_id = "msg-global-uuid-12345678";
        let message_payload = format!(
            r#"{{"v":1,"type":"text","id":"{}","text":"Mensagem alvo de reação"}}"#,
            global_id
        );

        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), message_payload)
            .unwrap();
        let incoming = p
            .core_b
            .decrypt_incoming(p.device_id_a.clone(), sealed.bytes.unwrap())
            .unwrap()
            .expect("mensagem válida deve ser decifrada");

        let msg_b_id = incoming.message_id.expect("deve ter rowid no receptor");
        let msg_a_id = sealed.message_id;

        // Garante que os rowids locais dos dois bancos são comprovadamente divergentes
        assert_ne!(
            msg_a_id, msg_b_id,
            "rowids locais devem ser diferentes entre os bancos"
        );

        // 3. A envia uma reação apontando para o identificador global da mensagem
        let reaction_payload = format!(
            r#"{{"v":1,"type":"reaction","targetId":"{}","emoji":"❤️"}}"#,
            global_id
        );

        let sealed_reaction = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), reaction_payload)
            .unwrap();

        p.core_b
            .decrypt_incoming(p.device_id_a.clone(), sealed_reaction.bytes.unwrap())
            .unwrap();

        // 4. Critério de aceite: a reação de A aparece na mesma mensagem nos dois bancos
        let history_a = p.core_a.list_messages(p.device_id_b.clone()).unwrap();
        let history_b = p.core_b.list_messages(p.device_id_a.clone()).unwrap();

        let target_in_a = history_a
            .iter()
            .find(|m| m.global_id.as_deref() == Some(global_id))
            .expect("mensagem alvo deve existir no banco de A");
        let target_in_b = history_b
            .iter()
            .find(|m| m.global_id.as_deref() == Some(global_id))
            .expect("mensagem alvo deve existir no banco de B");

        assert_eq!(target_in_a.id, msg_a_id);
        assert_eq!(target_in_b.id, msg_b_id);
        assert_eq!(target_in_a.reactions, vec!["❤️".to_string()]);
        assert_eq!(target_in_b.reactions, vec!["❤️".to_string()]);
    }

    #[test]
    fn resent_message_with_same_global_id_is_stored_once() {
        let p = paired_pair();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );
        let payload = r#"{"v":1,"type":"text","id":"resend-uuid-1","text":"oi"}"#.to_string();

        // O mesmo conteúdo sai duas vezes, cada uma recifrada com novo passo do ratchet.
        let first = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), payload.clone())
            .unwrap();
        let second = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), payload)
            .unwrap();
        let in1 = p
            .core_b
            .decrypt_incoming(p.device_id_a.clone(), first.bytes.unwrap())
            .unwrap()
            .unwrap();
        let in2 = p
            .core_b
            .decrypt_incoming(p.device_id_a.clone(), second.bytes.unwrap())
            .unwrap()
            .expect("duplicata ainda devolve o DTO para reenviar o recibo");

        assert_eq!(in1.message_id, in2.message_id);
        let history = p.core_b.list_messages(p.device_id_a.clone()).unwrap();
        assert_eq!(history.len(), 1);
    }

    #[test]
    fn message_sent_receipt_decrypted_and_sender_list_messages_shows_delivered() {
        let p = paired_pair();
        establish(
            &p.core_a,
            p.device_id_a.clone(),
            &p.core_b,
            p.device_id_b.clone(),
        );

        // 1. Mensagem enviada pelo emissor (A) para B
        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b.clone(), "Mensagem com recibo de entrega".to_string())
            .unwrap();
        p.core_a.mark_message_sent(sealed.message_id).unwrap();

        // Antes do recibo, estado é Sent
        let msgs_before = p.core_a.list_messages(p.device_id_b.clone()).unwrap();
        assert_eq!(msgs_before.len(), 1);
        assert_eq!(msgs_before[0].delivery_state, DeliveryStateDto::Sent);

        // 2. B recebe e decifra a mensagem
        let incoming = p
            .core_b
            .decrypt_incoming(p.device_id_a.clone(), sealed.bytes.unwrap())
            .unwrap()
            .expect("mensagem válida deve ser decifrada por B");
        assert_eq!(incoming.body, "Mensagem com recibo de entrega");

        // 3. B gera recibo de entrega MSG_RECEIPT apontando para o identificador da mensagem
        let target_id = sealed.message_id.to_string();
        let receipt = p
            .core_b
            .seal_outgoing_receipt(p.device_id_a.clone(), target_id)
            .unwrap();
        assert!(receipt.bytes.is_some());

        // 4. A decifra o recibo recebido de B
        let receipt_incoming = p
            .core_a
            .decrypt_incoming(p.device_id_b.clone(), receipt.bytes.unwrap())
            .unwrap();
        assert!(receipt_incoming.is_none(), "MSG_RECEIPT não produz balão de mensagem");

        // 5. Critério de aceite: list_messages do emissor mostra Delivered
        let msgs_after = p.core_a.list_messages(p.device_id_b.clone()).unwrap();
        assert_eq!(msgs_after.len(), 1);
        assert_eq!(msgs_after[0].delivery_state, DeliveryStateDto::Delivered);
    }

    type Seen = std::sync::Arc<std::sync::Mutex<Vec<SessionStateEventDto>>>;

    fn record_events(core: &Core) -> Seen {
        let seen: Seen = Default::default();
        let sink_seen = std::sync::Arc::clone(&seen);
        core.set_session_event_sink(Box::new(move |e| sink_seen.lock().unwrap().push(e)))
            .unwrap();
        seen
    }

    fn last_state(seen: &Seen) -> Option<SessionStateKind> {
        seen.lock().unwrap().last().expect("nenhum evento").state
    }

    /// Leva a sessão de `victim` com `sender` a `Failed` entregando envelopes
    /// adulterados até passar do limiar de §11.1. `sender` precisa já ter
    /// cadeia de envio (ter recebido ao menos uma mensagem do par).
    fn fail_session(sender: &Core, sender_peer: &[u8], victim: &Core, victim_peer: &[u8]) {
        for _ in 0..9 {
            let sealed = sender
                .seal_outgoing_text(sender_peer.to_vec(), "x".to_owned())
                .unwrap();
            let mut bytes = sealed.bytes.expect("sessão do emissor deve cifrar");
            let last = bytes.len() - 1;
            bytes[last] ^= 0xff;
            let _ = victim.decrypt_incoming(victim_peer.to_vec(), bytes);
        }
        let status = victim.session_status(victim_peer.to_vec()).unwrap().unwrap();
        assert_eq!(status.state, SessionStateKind::Failed);
    }

    /// `a` manda uma mensagem a `b` para que `b` ganhe cadeia de envio.
    fn give_b_a_send_chain(p: &PairedCores) -> i64 {
        let first = p.core_a.seal_outgoing_text(p.device_id_b.clone(), "oi".to_owned()).unwrap();
        p.core_b
            .decrypt_incoming(p.device_id_a.clone(), first.bytes.unwrap())
            .unwrap()
            .unwrap();
        first.message_id
    }

    #[test]
    fn session_failing_inside_decrypt_is_pushed_without_being_asked() {
        let p = paired_pair();
        establish(&p.core_a, p.device_id_a.clone(), &p.core_b, p.device_id_b.clone());
        let seen = record_events(&p.core_a);
        give_b_a_send_chain(&p);

        fail_session(&p.core_b, &p.device_id_a, &p.core_a, &p.device_id_b);

        assert_eq!(last_state(&seen), Some(SessionStateKind::Failed));
        assert_eq!(seen.lock().unwrap().last().unwrap().peer_device_id, p.device_id_b);
    }

    #[test]
    fn subscribing_replays_the_current_state() {
        let p = paired_pair();
        establish(&p.core_a, p.device_id_a.clone(), &p.core_b, p.device_id_b.clone());

        let seen = record_events(&p.core_a);

        assert_eq!(seen.lock().unwrap().len(), 1);
        assert_eq!(last_state(&seen), Some(SessionStateKind::Established));
    }

    #[test]
    fn ensure_session_does_not_reopen_a_failed_session() {
        let p = paired_pair();
        establish(&p.core_a, p.device_id_a.clone(), &p.core_b, p.device_id_b.clone());
        give_b_a_send_chain(&p);
        fail_session(&p.core_b, &p.device_id_a, &p.core_a, &p.device_id_b);

        let status = p.core_a.ensure_session(p.device_id_b.clone()).unwrap();

        assert_eq!(status.state, SessionStateKind::Failed);
    }

    #[test]
    fn reset_reopens_a_failed_session_and_announces_it() {
        let p = paired_pair();
        establish(&p.core_a, p.device_id_a.clone(), &p.core_b, p.device_id_b.clone());
        give_b_a_send_chain(&p);
        fail_session(&p.core_b, &p.device_id_a, &p.core_a, &p.device_id_b);
        let seen = record_events(&p.core_a);
        assert_eq!(last_state(&seen), Some(SessionStateKind::Failed));

        let status = p.core_a.reset_session(p.device_id_b.clone()).unwrap();

        assert_eq!(status.state, SessionStateKind::Handshaking);
        // `core_a` inicia: a INIT nova é entregue no mesmo status.
        assert!(status.outgoing_handshake.is_some());
        assert_eq!(last_state(&seen), Some(SessionStateKind::Handshaking));
    }

    #[test]
    fn reset_leaves_a_healthy_session_alone() {
        let p = paired_pair();
        establish(&p.core_a, p.device_id_a.clone(), &p.core_b, p.device_id_b.clone());
        let seen = record_events(&p.core_a);

        let status = p.core_a.reset_session(p.device_id_b.clone()).unwrap();

        assert_eq!(status.state, SessionStateKind::Established);
        assert_eq!(seen.lock().unwrap().len(), 1, "só o replay da assinatura");
    }

    #[test]
    fn reset_returns_in_flight_text_to_the_queue() {
        let p = paired_pair();
        establish(&p.core_a, p.device_id_a.clone(), &p.core_b, p.device_id_b.clone());
        // "oi" fica `Sending` em `core_a`: cifrada, nunca marcada como enviada.
        let in_flight = give_b_a_send_chain(&p);
        fail_session(&p.core_b, &p.device_id_a, &p.core_a, &p.device_id_b);
        let state_of = |core: &Core| {
            core.list_messages(p.device_id_b.clone())
                .unwrap()
                .into_iter()
                .find(|m| m.id == in_flight)
                .unwrap()
                .delivery_state
        };
        assert_eq!(state_of(&p.core_a), DeliveryStateDto::Sending);

        p.core_a.reset_session(p.device_id_b.clone()).unwrap();

        assert_eq!(state_of(&p.core_a), DeliveryStateDto::Pending);
    }

    #[test]
    fn locking_announces_that_sessions_are_gone() {
        let p = paired_pair();
        establish(&p.core_a, p.device_id_a.clone(), &p.core_b, p.device_id_b.clone());
        let seen = record_events(&p.core_a);

        p.core_a.lock().unwrap();

        assert_eq!(last_state(&seen), None);
        assert_eq!(seen.lock().unwrap().len(), 2);
    }
}
