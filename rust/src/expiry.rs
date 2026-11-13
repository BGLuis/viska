//! Varredura das chaves de mensagens efêmeras, dirigida pelo vencimento.
//!
//! Antes, um `Timer.periodic` de 60 s no Dart chamava a varredura: uma
//! mensagem podia ficar até um minuto além do prazo na tela, e o aparelho
//! acordava a cada minuto mesmo sem nada a vencer. Aqui uma thread dorme até o
//! menor `expires_at` do banco e só então varre.
//!
//! Desvio D29 (`docs/deviations.md`).
//!
//! A thread só enxerga o `Store`, nunca a `Core`, para que largar a `Core`
//! (o Dart descartar o handle) a encerre sem ciclo de referências.
//!
//! O que acorda a thread antes da hora é qualquer coisa que possa ter mudado o
//! menor vencimento: mensagem nova, leitura (que arma o prazo), desbloqueio.
//! Trancado, o banco não responde e a thread espera, sem girar à toa.

use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use viska_proto::store::Store;

/// Teto de cada sono, só para relógio que salta para trás não deixar a thread
/// dormindo além do que deveria.
const MAX_SLEEP: Duration = Duration::from_secs(3600);

#[derive(Default)]
struct State {
    stop: bool,
    /// Alguém avisou que o vencimento pode ter mudado desde a última conta.
    poked: bool,
}

/// Ponto de acordar a thread, compartilhado com quem emite os avisos. Existe
/// antes da thread: os avisos de uma `Core` ainda sem assinante só marcam o
/// estado, e a primeira conta da thread já os considera.
#[derive(Default)]
pub(crate) struct ExpiryWake {
    state: Mutex<State>,
    wake: Condvar,
}

impl ExpiryWake {
    pub(crate) fn poke(&self) {
        // Trava envenenada só vem de pânico da própria thread; nesse caso não há
        // quem acordar.
        if let Ok(mut state) = self.state.lock() {
            state.poked = true;
            self.wake.notify_all();
        }
    }

    pub(crate) fn stop(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.stop = true;
            self.wake.notify_all();
        }
    }
}

/// Sobe a thread de varredura. Os eventos de `KeyExpired` saem do próprio
/// `Store::sweep_expired_ephemeral_messages`.
pub(crate) fn spawn(store: Arc<Store>, wake: Arc<ExpiryWake>) {
    // Falha ao criar a thread (limite do sistema) deixa só a expiração em
    // tempo real de fora; a mensagem continua expirando na próxima varredura
    // de quem a lê. Sem `expect`: nada aqui justifica derrubar o app.
    let _ = std::thread::Builder::new()
        .name("viska-expiry".into())
        .spawn(move || run(&store, &wake));
}

fn run(store: &Store, wake: &ExpiryWake) {
    loop {
        match wake.state.lock() {
            Ok(mut state) => {
                if state.stop {
                    return;
                }
                state.poked = false;
            }
            Err(_) => return,
        }

        let now = now();
        // `None` cobre "sem chave nenhuma" e "banco trancado": nos dois casos só
        // um aviso muda alguma coisa.
        let sleep = match store.next_ephemeral_expiry() {
            Ok(Some(at)) if at <= now => {
                if store.sweep_expired_ephemeral_messages(now).is_ok() {
                    continue;
                }
                // A varredura falhou (trancou no meio): esperar o aviso, em vez
                // de repetir a conta no mesmo instante.
                None
            }
            Ok(Some(at)) => Some(Duration::from_secs((at - now) as u64).min(MAX_SLEEP)),
            _ => None,
        };

        let Ok(state) = wake.state.lock() else {
            return;
        };
        if state.stop {
            return;
        }
        // Um aviso que chegou entre a conta e este ponto não se perde: refaz.
        if state.poked {
            continue;
        }
        // Acordar por aviso, por prazo ou por trava envenenada: nos três casos o
        // laço recomeça e refaz a conta (o último é tratado no topo).
        match sleep {
            Some(timeout) => drop(wake.wake.wait_timeout(state, timeout)),
            None => drop(wake.wake.wait(state)),
        }
    }
}

fn now() -> i64 {
    viska_proto::util::time::unix_seconds() as i64
}
