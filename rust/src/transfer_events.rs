//! Eventos de transferência de arquivo, empurrados do Rust para o Dart.
//!
//! Segue o mesmo desenho de `session_events`: o emissor é um `Fn` comum, não o
//! `StreamSink` do codegen, para que ordem e replay sejam testáveis em
//! `cargo test` sem subir a ponte; e o módulo fica fora de `ffi/` para o codegen
//! não tentar expor este detalhe interno.
//!
//! Antes, o Dart relia a lista de ofertas a cada mensagem recebida, só porque
//! não havia como saber que uma oferta nova tinha chegado. Quem sabe é o Rust.
//!
//! O evento é só um aviso de "releia": identificador do contato e `file_id`.
//! Nome e tamanho do arquivo ficam de fora de propósito, o Dart os pede a
//! `unconfirmed_file_offers`. Este é o ponto de extensão para os demais eventos
//! de transferência: novos casos entram como variantes de `TransferEventKind`,
//! sem mudar o stream nem a assinatura.
//!
//! Diferente do estado de sessão, não há deduplicação: um evento de oferta é um
//! fato que aconteceu, não um estado que possa repetir.

use crate::ffi::types::TransferEventDto;

pub(crate) type TransferEventSink = Box<dyn Fn(TransferEventDto) + Send>;

#[derive(Default)]
pub(crate) struct TransferEvents {
    sink: Option<TransferEventSink>,
}

impl std::fmt::Debug for TransferEvents {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("TransferEvents(<opaco>)")
    }
}

impl TransferEvents {
    /// Troca o destinatário e reenvia `current`, o retrato do que já existe.
    /// Um evento emitido antes da assinatura se perderia; o replay poupa o Dart
    /// de combinar a assinatura com uma leitura avulsa.
    pub(crate) fn set_sink(
        &mut self,
        sink: TransferEventSink,
        current: impl IntoIterator<Item = TransferEventDto>,
    ) {
        for event in current {
            sink(event);
        }
        self.sink = Some(sink);
    }

    /// Sem destinatário o evento é descartado: o replay da assinatura cobre.
    pub(crate) fn emit(&self, event: TransferEventDto) {
        if let Some(sink) = &self.sink {
            sink(event);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::types::TransferEventKind;
    use std::sync::{Arc, Mutex};

    fn event(file: u8, kind: TransferEventKind) -> TransferEventDto {
        TransferEventDto { peer_device_id: vec![1; 16], file_id: vec![file; 16], kind }
    }

    fn recording_sink() -> (TransferEventSink, Arc<Mutex<Vec<TransferEventDto>>>) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink_seen = Arc::clone(&seen);
        (Box::new(move |e| sink_seen.lock().unwrap().push(e)), seen)
    }

    #[test]
    fn emits_in_order_without_deduplicating() {
        let (sink, seen) = recording_sink();
        let mut events = TransferEvents::default();
        events.set_sink(sink, std::iter::empty());
        events.emit(event(1, TransferEventKind::OfferAppeared));
        events.emit(event(1, TransferEventKind::OfferAppeared));
        events.emit(event(1, TransferEventKind::OfferGone));

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 3);
        assert_eq!(seen[2].kind, TransferEventKind::OfferGone);
    }

    #[test]
    fn emitting_without_a_sink_is_silent() {
        let events = TransferEvents::default();
        events.emit(event(1, TransferEventKind::OfferAppeared));
    }

    #[test]
    fn subscribing_replays_the_snapshot_before_new_events() {
        let mut events = TransferEvents::default();
        events.emit(event(9, TransferEventKind::OfferAppeared));

        let (sink, seen) = recording_sink();
        events.set_sink(sink, [event(1, TransferEventKind::OfferAppeared)]);
        events.emit(event(2, TransferEventKind::OfferAppeared));

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert_eq!(seen[0].file_id, vec![1; 16]);
        assert_eq!(seen[1].file_id, vec![2; 16]);
    }

    #[test]
    fn resubscribing_moves_events_to_the_new_sink() {
        let (old_sink, old_seen) = recording_sink();
        let mut events = TransferEvents::default();
        events.set_sink(old_sink, std::iter::empty());

        let (sink, seen) = recording_sink();
        events.set_sink(sink, std::iter::empty());
        events.emit(event(1, TransferEventKind::OfferGone));

        assert!(old_seen.lock().unwrap().is_empty());
        assert_eq!(seen.lock().unwrap().len(), 1);
    }
}
