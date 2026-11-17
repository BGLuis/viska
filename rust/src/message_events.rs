//! Eventos de mudança em mensagens, empurrados do Rust para o Dart.
//!
//! Mesmo desenho de `transfer_events`: o emissor é um `Fn` comum, não o
//! `StreamSink` do codegen, para que ordem e entrega sejam testáveis em
//! `cargo test`; e o módulo fica fora de `ffi/` para o codegen não expor este
//! detalhe interno.
//!
//! Antes, o Dart relia a timeline inteira depois de cada ação e a cada minuto,
//! porque só ele "sabia" que algo podia ter mudado. Quem sabe é o `Store`, que
//! avisa em todo caminho de escrita (ver `Store::announce`); aqui só se
//! converte o aviso no DTO e se entrega.
//!
//! Desvio D29 (`docs/deviations.md`).
//!
//! O evento carrega só identificadores. O conteúdo da linha o Dart pede por
//! `Core::get_message`: assim nada de mensagem, nem emoji, atravessa o stream.
//!
//! Não há replay na assinatura. O retrato é a própria carga inicial da
//! timeline, que o Dart faz depois de assinar: o que mudar entre as duas coisas
//! chega como evento e é aplicado por id, sem duplicar.

use viska_proto::store::{MessageChange, MessageChangeKind};

use crate::ffi::types::{MessageEventDto, MessageEventKind};

pub(crate) type MessageEventSink = Box<dyn Fn(MessageEventDto) + Send>;

#[derive(Default)]
pub(crate) struct MessageEvents {
    sink: Option<MessageEventSink>,
}

impl std::fmt::Debug for MessageEvents {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("MessageEvents(<opaco>)")
    }
}

impl MessageEvents {
    /// Troca o destinatário; uma nova assinatura substitui a anterior.
    pub(crate) fn set_sink(&mut self, sink: MessageEventSink) {
        self.sink = Some(sink);
    }

    /// Sem destinatário o evento é descartado: a carga inicial da timeline,
    /// feita depois de assinar, já traz o estado corrente.
    pub(crate) fn emit(&self, change: MessageChange) {
        if let Some(sink) = &self.sink {
            sink(to_dto(change));
        }
    }
}

fn to_dto(change: MessageChange) -> MessageEventDto {
    MessageEventDto {
        peer_device_id: change.contact_device_id.to_vec(),
        message_id: change.message_id,
        kind: match change.kind {
            MessageChangeKind::Added => MessageEventKind::Added,
            MessageChangeKind::Updated => MessageEventKind::Updated,
            MessageChangeKind::KeyExpired => MessageEventKind::KeyExpired,
            MessageChangeKind::ReactionsChanged => MessageEventKind::ReactionsChanged,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    fn change(id: i64, kind: MessageChangeKind) -> MessageChange {
        MessageChange { contact_device_id: [7; 16], message_id: id, kind }
    }

    fn recording_sink() -> (MessageEventSink, Arc<Mutex<Vec<MessageEventDto>>>) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink_seen = Arc::clone(&seen);
        (Box::new(move |e| sink_seen.lock().unwrap().push(e)), seen)
    }

    #[test]
    fn emits_in_order_with_only_identifiers() {
        let (sink, seen) = recording_sink();
        let mut events = MessageEvents::default();
        events.set_sink(sink);
        events.emit(change(1, MessageChangeKind::Added));
        events.emit(change(1, MessageChangeKind::Updated));
        events.emit(change(2, MessageChangeKind::KeyExpired));

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 3);
        assert_eq!(seen[0].peer_device_id, vec![7; 16]);
        assert_eq!(seen[1].kind, MessageEventKind::Updated);
        assert_eq!(seen[2].message_id, 2);
    }

    #[test]
    fn emitting_without_a_sink_is_silent() {
        MessageEvents::default().emit(change(1, MessageChangeKind::Added));
    }

    #[test]
    fn resubscribing_moves_events_to_the_new_sink() {
        let (old_sink, old_seen) = recording_sink();
        let mut events = MessageEvents::default();
        events.set_sink(old_sink);
        let (sink, seen) = recording_sink();
        events.set_sink(sink);
        events.emit(change(1, MessageChangeKind::ReactionsChanged));

        assert!(old_seen.lock().unwrap().is_empty());
        assert_eq!(seen.lock().unwrap().len(), 1);
    }
}
