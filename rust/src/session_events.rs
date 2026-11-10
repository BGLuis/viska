//! Eventos de mudança de estado de sessão, empurrados do Rust para o Dart.
//!
//! O Rust é o único dono do estado de cada sessão: ela pode virar `Failed`
//! dentro de `decrypt_incoming` (limiar de falhas de AEAD, `docs/protocol.md`
//! §11.1) ou passar do limiar de §11.2 dentro de um envio, sem que nenhuma
//! chamada do Dart tenha perguntado nada. Inferir isso do lado Dart foi o que
//! deixou `Failed` sem aviso para a pessoa.
//!
//! O emissor é um `Fn` comum, não o `StreamSink` do codegen: só assim o
//! comportamento (deduplicação, ordem, replay) é testável em `cargo test` sem
//! subir a ponte. O `StreamSink` entra apenas na borda, em
//! `Core::subscribe_session_events`.
//!
//! Fica fora de `ffi/` de propósito: o codegen varre `crate::ffi` e tentaria
//! expor ao Dart estes tipos, que são detalhe interno do `Core`.
//!
//! O payload é só o que a UI já pode consultar por `session_status`:
//! identificador público do contato e o enum de estado. Nenhum segredo.

use std::collections::HashMap;

use crate::ffi::core::Core;
use crate::ffi::types::{SessionStateEventDto, SessionStateKind};

pub(crate) type SessionEventSink = Box<dyn Fn(SessionStateEventDto) + Send>;

/// Estado observável de uma sessão; `None` quando ela não existe (descartada
/// por `lock`, re-pareamento ou reset).
pub(crate) type SessionSnapshot = Option<(SessionStateKind, bool)>;

#[derive(Default)]
pub(crate) struct SessionEvents {
    sink: Option<SessionEventSink>,
    /// Último estado entregue por contato. Sem isso, toda chamada que apenas
    /// consulta a sessão emitiria um evento repetido.
    ///
    /// Chave `Vec<u8>`, não `[u8; 16]`: o codegen percorre os campos de
    /// `Core` e, ao ver o array aqui, passaria a emitir `U8Array16` num
    /// arquivo à parte, mudando a ponte inteira por um detalhe interno.
    published: HashMap<Vec<u8>, (SessionStateKind, bool)>,
}

impl std::fmt::Debug for SessionEvents {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SessionEvents(<opaco>)")
    }
}

impl SessionEvents {
    /// Troca o destinatário e reenvia o estado atual de cada sessão. Eventos
    /// emitidos antes da assinatura se perderiam; o replay evita que o Dart
    /// precise combinar a assinatura com uma leitura avulsa.
    pub(crate) fn set_sink(
        &mut self,
        sink: SessionEventSink,
        current: impl IntoIterator<Item = ([u8; 16], SessionSnapshot)>,
    ) {
        self.published.clear();
        self.sink = Some(sink);
        for (id, snapshot) in current {
            self.publish(&id, snapshot);
        }
    }

    /// Emite um evento se o estado de `id` difere do último entregue.
    pub(crate) fn publish(&mut self, id: &[u8; 16], current: SessionSnapshot) {
        let Some(sink) = &self.sink else {
            return;
        };
        let previous = self.published.get(id.as_slice()).copied();
        if previous == current {
            return;
        }
        match current {
            Some(value) => {
                self.published.insert(id.to_vec(), value);
            }
            None => {
                self.published.remove(id.as_slice());
            }
        }
        sink(SessionStateEventDto {
            peer_device_id: id.to_vec(),
            state: current.map(|(state, _)| state),
            needs_rehandshake: current.is_some_and(|(_, needs)| needs),
        });
    }

    /// Contatos para os quais já foi entregue algum estado: `lock` precisa
    /// avisar o fim de cada um deles.
    pub(crate) fn published_ids(&self) -> Vec<[u8; 16]> {
        // Toda chave entra por `publish`, que recebe `[u8; 16]`.
        self.published
            .keys()
            .filter_map(|id| <[u8; 16]>::try_from(id.as_slice()).ok())
            .collect()
    }
}

/// Solta o aviso de estado ao sair do escopo; ver `Core::publish_on_exit`.
pub(crate) struct PublishOnExit<'a> {
    pub(crate) core: &'a Core,
    pub(crate) device_id: [u8; 16],
}

impl std::fmt::Debug for PublishOnExit<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PublishOnExit")
    }
}

impl Drop for PublishOnExit<'_> {
    fn drop(&mut self) {
        self.core.publish_session(&self.device_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    const A: [u8; 16] = [1; 16];
    const B: [u8; 16] = [2; 16];

    fn recording() -> (SessionEvents, Arc<Mutex<Vec<SessionStateEventDto>>>) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink_seen = Arc::clone(&seen);
        let mut events = SessionEvents::default();
        events.set_sink(
            Box::new(move |e| sink_seen.lock().unwrap().push(e)),
            std::iter::empty(),
        );
        (events, seen)
    }

    #[test]
    fn emits_on_change_and_skips_repeats() {
        let (mut events, seen) = recording();
        events.publish(&A, Some((SessionStateKind::Handshaking, false)));
        events.publish(&A, Some((SessionStateKind::Handshaking, false)));
        events.publish(&A, Some((SessionStateKind::Failed, false)));

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert_eq!(seen[1].state, Some(SessionStateKind::Failed));
        assert_eq!(seen[1].peer_device_id, A.to_vec());
    }

    #[test]
    fn needs_rehandshake_flip_is_its_own_event() {
        let (mut events, seen) = recording();
        events.publish(&A, Some((SessionStateKind::Established, false)));
        events.publish(&A, Some((SessionStateKind::Established, true)));

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert!(seen[1].needs_rehandshake);
    }

    #[test]
    fn discarded_session_emits_none_once() {
        let (mut events, seen) = recording();
        events.publish(&A, Some((SessionStateKind::Established, false)));
        events.publish(&A, None);
        events.publish(&A, None);

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert_eq!(seen[1].state, None);
    }

    #[test]
    fn never_seen_missing_session_emits_nothing() {
        let (mut events, seen) = recording();
        events.publish(&A, None);
        assert!(seen.lock().unwrap().is_empty());
    }

    #[test]
    fn contacts_are_tracked_independently() {
        let (mut events, seen) = recording();
        events.publish(&A, Some((SessionStateKind::Failed, false)));
        events.publish(&B, Some((SessionStateKind::Failed, false)));
        assert_eq!(seen.lock().unwrap().len(), 2);
    }

    #[test]
    fn publishing_without_a_sink_is_silent_and_replayed_on_subscribe() {
        let mut events = SessionEvents::default();
        events.publish(&A, Some((SessionStateKind::Failed, false)));
        assert!(events.published_ids().is_empty());

        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink_seen = Arc::clone(&seen);
        events.set_sink(
            Box::new(move |e| sink_seen.lock().unwrap().push(e)),
            [(A, Some((SessionStateKind::Failed, false)))],
        );

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].state, Some(SessionStateKind::Failed));
    }

    #[test]
    fn resubscribing_replays_current_state_to_the_new_sink() {
        let (mut events, _old) = recording();
        events.publish(&A, Some((SessionStateKind::Established, false)));

        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink_seen = Arc::clone(&seen);
        events.set_sink(
            Box::new(move |e| sink_seen.lock().unwrap().push(e)),
            [(A, Some((SessionStateKind::Established, false)))],
        );
        assert_eq!(seen.lock().unwrap().len(), 1);
    }
}
