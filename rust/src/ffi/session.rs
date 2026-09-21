//! Superfície FFI de sessão e mensagem — Fase 3, F2.
//!
//! Sem `StreamSink`/callback assíncrono: o núcleo Rust é síncrono por
//! desenho (`viska_proto` não depende de nenhum runtime assíncrono). Todo
//! evento de rede — canal abriu, bytes chegaram — nasce do lado Dart
//! (`flutter_webrtc`/`mqtt_client`, Fase 3 F3/F4), que então chama estes
//! métodos de forma síncrona; não há nada que o Rust precise empurrar por
//! conta própria, então os métodos abaixo são só request/response comuns,
//! que o `flutter_rust_bridge` já despacha em thread própria e devolve como
//! `Future` ao Dart automaticamente.

use std::collections::HashMap;
use std::sync::MutexGuard;

use crate::ffi::core::Core;
use crate::ffi::error::FfiError;
use crate::ffi::types::{
    DeliveryStateDto, IncomingMessageDto, MessageDirectionDto, MessageDto, MessageKindDto,
    SealedMessageDto, SessionStateKind, SessionStatusDto,
};
use viska_proto::crypto::identity::DEVICE_ID_LEN;
use viska_proto::session::Session;
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
        let mut sessions = self.lock_sessions()?;

        if let Some(session) = sessions.get(&device_id) {
            return Ok(status_dto(session));
        }

        let (peer, _) = self
            .store
            .find_contact(&device_id)?
            .ok_or(FfiError::ContactNotFound)?;
        let (session, _) = Session::open(&self.identity, peer)?;
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
        let mut sessions = self.lock_sessions()?;
        let session = sessions
            .get_mut(&device_id)
            .ok_or(FfiError::NoActiveSession)?;

        Ok(session.process_handshake_message(&self.identity, &bytes)?)
    }

    /// Cifra `body` como `MSG_TEXT` e persiste como `pending` antes de
    /// qualquer tentativa de envio — eco otimista: a UI mostra a mensagem
    /// mesmo que o transporte esteja indisponível no momento da chamada.
    ///
    /// `bytes` do DTO devolvido vem `None` quando a sessão ainda não está
    /// `Established`: a mensagem já está persistida, e `flush_pending` a
    /// entrega assim que a sessão ficar pronta.
    pub fn seal_outgoing_text(
        &self,
        peer_device_id: Vec<u8>,
        body: String,
    ) -> Result<SealedMessageDto, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        let created_at = viska_proto::util::time::unix_seconds() as i64;
        let message_id = self.store.insert_pending_message(
            &device_id,
            PacketType::MsgText,
            &body,
            created_at,
        )?;

        let mut sessions = self.lock_sessions()?;
        let bytes = match sessions.get_mut(&device_id) {
            Some(session) if session.is_established() => session
                .encrypt_outgoing(PacketType::MsgText, body.into_bytes(), Transport::DataChannel)
                .ok(),
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
        let mut sessions = self.lock_sessions()?;
        let session = sessions
            .get_mut(&device_id)
            .ok_or(FfiError::NoActiveSession)?;

        let inner = session.decrypt_incoming(&envelope, Transport::DataChannel)?;
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
                let message_id = self.store.insert_incoming_message(
                    &device_id,
                    PacketType::MsgText,
                    &body,
                    received_at,
                )?;
                Ok(Some(IncomingMessageDto {
                    message_id: Some(message_id),
                    body,
                    is_typing: false,
                    received_at_unix_secs: received_at,
                }))
            }
            PacketType::MsgTyping => Ok(Some(IncomingMessageDto {
                message_id: None,
                body: String::new(),
                is_typing: true,
                received_at_unix_secs: received_at,
            })),
            PacketType::FileMetadata => {
                let _ = self.handle_incoming_file_metadata(device_id, inner.body);
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
            _ => Ok(None),
        }
    }

    /// Marca uma mensagem de saída como entregue ao transporte — chamar só
    /// depois que o envio de rede (`RTCDataChannel.send` ou equivalente) não
    /// lançar erro.
    pub fn mark_message_sent(&self, message_id: i64) -> Result<(), FfiError> {
        self.store.mark_message_sent(message_id)?;
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
        let pending = self.store.list_pending_messages(&device_id)?;
        if pending.is_empty() {
            return Ok(Vec::new());
        }

        let mut sessions = self.lock_sessions()?;
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
                Ok(bytes) => sealed.push(SealedMessageDto {
                    message_id: message.id,
                    bytes: Some(bytes),
                }),
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

    /// Todas as mensagens já trocadas com um contato, mais antigas primeiro
    /// — histórico completo para a tela de chat abrir com.
    pub fn list_messages(&self, peer_device_id: Vec<u8>) -> Result<Vec<MessageDto>, FfiError> {
        self.ensure_not_locked()?;
        let device_id = to_device_id(peer_device_id)?;
        let stored = self.store.list_messages(&device_id)?;
        Ok(stored.into_iter().map(message_dto).collect())
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
    };

    let (kind, body, audio_file_id) =
        if message.packet_type == viska_proto::wire::packet_type::PacketType::AudioChunk {
            (MessageKindDto::VoiceNote, String::new(), hex::decode(&message.body).ok())
        } else {
            (MessageKindDto::Text, message.body, None)
        };

    MessageDto {
        id: message.id,
        direction,
        kind,
        body,
        audio_file_id,
        delivery_state,
        created_at_unix_secs: message.created_at_unix_secs,
        is_ephemeral: message.is_ephemeral,
    }
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
        let contact_a_seen_by_b = core_b.pair_from_qr(core_a.my_qr_payload()).unwrap();
        let contact_b_seen_by_a = core_a.pair_from_qr(core_b.my_qr_payload()).unwrap();

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
            .public()
            .is_before(&result.core_b.identity.public())
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
    fn ensure_session_e_idempotente_e_nunca_reabre_o_handshake() {
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
    fn outgoing_handshake_some_enquanto_pendente_e_none_apos_estabelecer() {
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
    fn ensure_session_de_contato_desconhecido_erra() {
        let dir = tempfile::tempdir().unwrap();
        let core = open_core(&dir);
        assert_eq!(
            core.ensure_session(vec![0u8; 16]),
            Err(FfiError::ContactNotFound)
        );
    }

    #[test]
    fn feed_handshake_sem_sessao_aberta_erra() {
        let dir = tempfile::tempdir().unwrap();
        let core = open_core(&dir);
        assert_eq!(
            core.feed_handshake(vec![0u8; 16], vec![0u8; 10]),
            Err(FfiError::NoActiveSession)
        );
    }

    #[test]
    fn handshake_completo_estabelece_sessao_nos_dois_lados() {
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
    fn texto_cifrado_de_um_lado_decifra_do_outro_e_persiste() {
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
    fn list_messages_traz_o_historico_dos_dois_sentidos_em_ordem() {
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
    fn list_messages_de_contato_sem_mensagens_devolve_vazio() {
        let p = paired_pair();
        let history = p.core_a.list_messages(p.device_id_b).unwrap();
        assert!(history.is_empty());
    }

    #[test]
    fn mensagem_enviada_antes_da_sessao_pronta_fica_pending_e_flush_pending_a_entrega() {
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
    fn mark_message_sent_nao_erra_para_id_existente() {
        let p = paired_pair();

        let sealed = p
            .core_a
            .seal_outgoing_text(p.device_id_b, "x".to_string())
            .unwrap();
        p.core_a.mark_message_sent(sealed.message_id).unwrap();
    }

    #[test]
    fn envelope_adulterado_e_descartado_como_none_sem_persistir() {
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
}
