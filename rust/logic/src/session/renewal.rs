//! Entrada dos bytes do par e reabertura de sessão — `docs/protocol.md` §11.4, D27.
//!
//! As sessões vivem só em memória, então um lado pode perder a sua (reinício,
//! cofre trancado, reset) enquanto o outro segue `Established`. Este módulo é
//! o que faz o outro lado acompanhar sem que nenhum byte em claro diga "isto é
//! handshake" (D4) e sem assinatura (D1):
//!
//! - [`Session::receive`] decide pelo estado e pelo tamanho o que os bytes são;
//! - o lado que não reabriu negocia uma **candidata** ao lado da sessão atual e
//!   só a promove quando o primeiro AEAD sob ela abre;
//! - quem reabre como respondedor pede a reabertura com um `REOPEN`
//!   (`super::reopen`).
//!
//! Regra que atravessa tudo: nenhum byte recebido derruba a sessão viva. Uma
//! INIT ou RESP forjada custa no máximo um handshake e um atraso de fila.

use super::{reopen, seal_with, try_decrypt, Session, SessionState};
use crate::crypto::handshake::{respond, Initiator, INIT_LEN, RESP_LEN};
use crate::crypto::identity::LocalIdentity;
use crate::crypto::ratchet::RatchetState;
use crate::crypto::suite::Suite;
use crate::signaling::topic;
use crate::wire::packet_type::PacketType;
use crate::wire::plaintext::InnerPlaintext;
use crate::wire::transport::Transport;
use crate::Result;

/// Segundos que uma sessão candidata segura a fila de envio esperando a
/// confirmação de chave. Uma INIT forjada, que nunca confirma, atrasa a fila
/// por no máximo isso.
pub const CANDIDATE_TIMEOUT_SECS: u64 = 30;

/// Intervalo mínimo entre dois sinais disparados por tráfego recebido (`REOPEN`,
/// ou a INIT reenviada em resposta a um) e entre duas candidatas de
/// respondedor. Sem isso, cada pacote ilegível geraria um sinal de volta, e
/// cada INIT diferente custaria um encapsulamento ML-KEM.
pub const SIGNAL_INTERVAL_SECS: u64 = 10;

/// `now` cai em `[since, since + window)`. Um relógio que volta para antes de
/// `since` não estende nada: conta como fora da janela.
fn within(since: u64, now: u64, window: u64) -> bool {
    now >= since && now - since < window
}

/// Sessão nova negociada sem derrubar a atual.
#[derive(Debug)]
pub(super) struct Candidate {
    stage: CandidateStage,
    opened_at: u64,
}

#[derive(Debug)]
enum CandidateStage {
    /// Somos iniciador: INIT enviada em resposta a um `REOPEN`.
    AwaitingResponse { initiator: Box<Initiator>, init: Vec<u8>, suite: u8 },
    /// Handshake concluído, aguardando o primeiro AEAD válido do par.
    Established { ratchet: Box<RatchetState>, suite: u8, suites_sent: bool },
}

/// A última INIT respondida: o resumo dela e a RESP dada. Os dois são públicos.
#[derive(Debug)]
pub(super) struct AnsweredInit {
    digest: [u8; 32],
    resp: Vec<u8>,
}

/// Resultado de [`Session::receive`].
#[derive(Debug, Default)]
pub struct Received {
    /// Mensagem de aplicação decifrada, se houver.
    pub message: Option<InnerPlaintext>,
    /// Bytes a mandar de volta ao par: RESP, INIT, `REOPEN` ou um
    /// `CONTROL_SUITES` já cifrado. Nunca segredo.
    pub reply: Option<Vec<u8>>,
    /// Uma sessão candidata nova foi aberta nesta chamada: o par muito
    /// provavelmente perdeu a sessão atual.
    pub candidate_opened: bool,
}

impl Received {
    fn reply(bytes: Vec<u8>) -> Self {
        Self {
            reply: Some(bytes),
            ..Self::default()
        }
    }
}

impl Session {
    /// Geração desta sessão: muda a cada promoção de candidata.
    pub fn generation(&self) -> u32 {
        self.generation
    }

    /// Define a geração de uma sessão aberta no lugar de outra, para que a
    /// troca seja visível mesmo quando o estado novo é igual ao antigo.
    pub fn set_generation(&mut self, generation: u32) {
        self.generation = generation;
    }

    /// `true` enquanto há uma candidata recente esperando confirmação: nada de
    /// aplicação é cifrado até ela ser promovida ou passar do prazo.
    pub fn is_renewing(&self) -> bool {
        self.is_renewing_at(crate::util::time::unix_seconds())
    }

    /// Como [`Self::is_renewing`], com o instante explícito.
    pub fn is_renewing_at(&self, now: u64) -> bool {
        self.candidate
            .as_ref()
            .is_some_and(|c| within(c.opened_at, now, CANDIDATE_TIMEOUT_SECS))
    }

    fn we_initiate(&self) -> bool {
        self.direction == topic::Direction::A2B
    }

    /// Respondedor cuja sessão nasceu de uma INIT e ainda não decifrou nada do
    /// par. Se ele só recebe coisa ilegível, o iniciador está em outra sessão
    /// (a RESP se perdeu, ou uma RESP forjada matou a candidata dele), e só um
    /// `REOPEN` resolve: o iniciador nunca repete a INIT sozinho.
    fn unconfirmed_responder(&self) -> bool {
        !self.we_initiate() && !self.peer_confirmed
    }

    /// Bytes a publicar quando o canal com o par conecta: a INIT se formos
    /// iniciador esperando a RESP (da sessão ou da candidata), um `REOPEN` novo
    /// se formos respondedor esperando a INIT ou ainda sem confirmação, `None`
    /// nos demais casos. Cada `REOPEN` tem nonce e carimbo próprios.
    pub fn connect_signal(&mut self) -> Result<Option<Vec<u8>>> {
        self.connect_signal_at(crate::util::time::unix_seconds())
    }

    /// Como [`Self::connect_signal`], com o instante explícito.
    pub fn connect_signal_at(&mut self, now: u64) -> Result<Option<Vec<u8>>> {
        match &self.state {
            SessionState::AwaitingResponse(_) => Ok(self.pending_outgoing_handshake.clone()),
            SessionState::AwaitingPeerInit => self.reopen_signal(now).map(Some),
            SessionState::Established(_) | SessionState::Failed => {
                if let Some(Candidate {
                    stage: CandidateStage::AwaitingResponse { init, .. },
                    ..
                }) = &self.candidate
                {
                    return Ok(Some(init.clone()));
                }
                if self.is_established() && self.unconfirmed_responder() {
                    return self.reopen_signal(now).map(Some);
                }
                Ok(None)
            }
        }
    }

    /// Ponto único de entrada de bytes vindos do par.
    ///
    /// Decide sozinho, pelo estado local e pelo tamanho, se os bytes são INIT,
    /// RESP, `REOPEN` ou envelope: nenhum marcador no fio (D4). INIT (1218 B) e
    /// RESP (1122 B) nunca têm o tamanho de um envelope (1076 ou 16436 B), e o
    /// `REOPEN` tem o de um envelope, então só é testado depois que nem a
    /// sessão atual nem a candidata abriram os bytes.
    ///
    /// Bytes que não servem para nada devolvem `Received::default()`, sem
    /// distinguir a causa por fora.
    pub fn receive(
        &mut self,
        local: &LocalIdentity,
        bytes: &[u8],
        transport: Transport,
    ) -> Result<Received> {
        self.receive_at(local, bytes, transport, crate::util::time::unix_seconds())
    }

    /// Como [`Self::receive`], com o instante explícito.
    pub fn receive_at(
        &mut self,
        local: &LocalIdentity,
        bytes: &[u8],
        transport: Transport,
        now: u64,
    ) -> Result<Received> {
        match self.state {
            SessionState::AwaitingPeerInit => self.receive_awaiting_init(local, bytes, now),
            SessionState::AwaitingResponse(_) => {
                self.receive_awaiting_response(local, bytes, transport, now)
            }
            SessionState::Established(_) | SessionState::Failed => {
                self.receive_live(local, bytes, transport, now)
            }
        }
    }

    fn receive_awaiting_init(
        &mut self,
        local: &LocalIdentity,
        bytes: &[u8],
        now: u64,
    ) -> Result<Received> {
        if bytes.len() == INIT_LEN {
            // Erro de INIT não muda o estado (§11.1): o par tenta de novo.
            return Ok(match self.process_handshake_message(local, bytes) {
                Ok(Some(resp)) => {
                    self.remember_answer(bytes, &resp);
                    Received::reply(resp)
                }
                _ => Received::default(),
            });
        }
        // Tráfego de uma sessão que não temos mais: o par não sabe que
        // reabrimos. Lembramos a ele, sem inundar.
        if self.signal_allowed(now) {
            return self.reopen_signal(now).map(Received::reply);
        }
        Ok(Received::default())
    }

    fn receive_awaiting_response(
        &mut self,
        local: &LocalIdentity,
        bytes: &[u8],
        transport: Transport,
        now: u64,
    ) -> Result<Received> {
        if bytes.len() == RESP_LEN {
            if self.process_handshake_message(local, bytes).is_err() {
                return Ok(Received::default());
            }
            // Primeira mensagem da sessão nova: confirma a chave para o
            // respondedor e lhe dá cadeia de envio (§4.4, §5.1, §10.2).
            return Ok(match self.build_control_suites(transport) {
                Ok(suites) => Received::reply(suites),
                Err(_) => Received::default(),
            });
        }
        // Qualquer outra coisa é ignorada sem consumir o `Initiator`: um
        // envelope de uma sessão anterior do par levaria a `Failed` à toa. Mas
        // ela prova que o par não está respondendo à nossa INIT (perdeu-a,
        // reabriu depois dela, ou a recusou pelo limite de taxa): reenviamos a
        // mesma, sem inundar. Um `REOPEN` cai aqui também.
        if self.signal_allowed(now) {
            if let Some(init) = self.pending_outgoing_handshake.clone() {
                return Ok(Received::reply(init));
            }
        }
        Ok(Received::default())
    }

    /// Sessão `Established` ou `Failed`: a atual, a candidata, ou um sinal.
    fn receive_live(
        &mut self,
        local: &LocalIdentity,
        bytes: &[u8],
        transport: Transport,
        now: u64,
    ) -> Result<Received> {
        let we_initiate = self.we_initiate();
        if bytes.len() == INIT_LEN && !we_initiate {
            return Ok(self.receive_init(local, bytes, now));
        }
        if bytes.len() == INIT_LEN || bytes.len() == RESP_LEN {
            // Nunca é envelope, então não diz nada sobre o ratchet: uma RESP
            // repetida pelo par (ou fora de hora) não conta como falha.
            if bytes.len() == RESP_LEN && we_initiate && self.candidate_awaits_response() {
                return Ok(match self.finish_initiator_candidate(local, bytes, transport) {
                    Some(suites) => Received::reply(suites),
                    None => Received::default(),
                });
            }
            return Ok(Received::default());
        }

        if let SessionState::Established(ratchet) = &mut self.state {
            if let Ok(inner) = try_decrypt(ratchet, bytes, transport) {
                return Ok(self.accept(inner, transport));
            }
        }

        if let Some(inner) = self.try_candidate(bytes, transport) {
            self.promote_candidate();
            return Ok(self.accept(inner, transport));
        }

        if bytes.len() == reopen::REOPEN_LEN && we_initiate && self.admit_reopen(bytes, now) {
            let (init, opened) = self.open_initiator_candidate(local, now)?;
            // A INIT que sai agora conta para o limite: o tráfego ilegível logo
            // em seguida não deve repeti-la.
            self.last_signal_at = Some(now);
            return Ok(Received {
                reply: Some(init),
                candidate_opened: opened,
                ..Received::default()
            });
        }

        self.count_failure();
        // Tráfego ilegível com handshake pendente: o outro lado não está na
        // sessão que estamos negociando. Repetir o que nos cabe (a INIT da
        // candidata, ou o `REOPEN` do respondedor sem confirmação) é o que
        // destrava; nenhum dos dois responde a INIT ou RESP com um sinal, então
        // não há pingue-pongue.
        if self.candidate_awaits_response() && self.signal_allowed(now) {
            if let Some(Candidate {
                stage: CandidateStage::AwaitingResponse { init, .. },
                ..
            }) = &self.candidate
            {
                return Ok(Received::reply(init.clone()));
            }
        }
        if self.unconfirmed_responder() && self.signal_allowed(now) {
            return self.reopen_signal(now).map(Received::reply);
        }
        Ok(Received::default())
    }

    /// INIT recebida com uma sessão já existente (somos respondedor).
    fn receive_init(&mut self, local: &LocalIdentity, init: &[u8], now: u64) -> Received {
        // A mesma INIT de novo: o par republicou (canal reconectado, `REOPEN`
        // cruzado) e ainda espera a RESP que já demos. Responder com efêmeras
        // novas faria os dois lados divergirem.
        if let Some(resp) = self.cached_resp(init) {
            return Received::reply(resp);
        }
        if self
            .last_candidate_at
            .is_some_and(|at| within(at, now, SIGNAL_INTERVAL_SECS))
        {
            return Received::default();
        }
        match self.open_responder_candidate(local, init, now) {
            Some(resp) => {
                self.last_candidate_at = Some(now);
                Received {
                    reply: Some(resp),
                    candidate_opened: true,
                    ..Received::default()
                }
            }
            None => {
                self.count_failure();
                Received::default()
            }
        }
    }

    /// Aplica uma mensagem decifrada pela sessão atual.
    fn accept(&mut self, inner: InnerPlaintext, transport: Transport) -> Received {
        self.on_decrypted(&inner);
        // O respondedor só consegue cifrar depois da primeira mensagem do
        // iniciador; é aqui que manda o seu anúncio (§10.2), o que também
        // confirma a chave para o iniciador.
        let reply = if self.suites_sent {
            None
        } else {
            self.build_control_suites(transport).ok()
        };
        Received {
            message: Some(inner),
            reply,
            candidate_opened: false,
        }
    }

    fn signal_allowed(&mut self, now: u64) -> bool {
        if self
            .last_signal_at
            .is_some_and(|at| within(at, now, SIGNAL_INTERVAL_SECS))
        {
            return false;
        }
        self.last_signal_at = Some(now);
        true
    }

    /// Sela um `REOPEN` e conta para o limite de taxa: um gatilho local (canal
    /// conectou) não passa pelo limite, mas o primeiro pacote ilegível logo
    /// depois não deve gerar um segundo sinal.
    fn reopen_signal(&mut self, now: u64) -> Result<Vec<u8>> {
        self.last_signal_at = Some(now);
        reopen::seal_at(&self.reopen_key, self.direction, now)
    }

    fn admit_reopen(&mut self, bytes: &[u8], now: u64) -> bool {
        match reopen::open_at(&self.reopen_key, self.direction.flip(), now, bytes) {
            Ok(nonce) => self.reopen_seen.admit(nonce, now),
            Err(_) => false,
        }
    }

    fn cached_resp(&self, init: &[u8]) -> Option<Vec<u8>> {
        let digest = blake3::hash(init);
        self.answered_init
            .as_ref()
            .filter(|answered| crate::util::encoding::ct_eq(&answered.digest, digest.as_bytes()))
            .map(|answered| answered.resp.clone())
    }

    fn remember_answer(&mut self, init: &[u8], resp: &[u8]) {
        self.answered_init = Some(AnsweredInit {
            digest: *blake3::hash(init).as_bytes(),
            resp: resp.to_vec(),
        });
    }

    fn candidate_awaits_response(&self) -> bool {
        matches!(
            self.candidate,
            Some(Candidate { stage: CandidateStage::AwaitingResponse { .. }, .. })
        )
    }

    /// Responde a uma INIT nova sem tocar na sessão atual. A candidata nova
    /// substitui qualquer anterior: só a INIT mais recente do par pode estar
    /// viva do lado dele.
    fn open_responder_candidate(
        &mut self,
        local: &LocalIdentity,
        init: &[u8],
        now: u64,
    ) -> Option<Vec<u8>> {
        let suite = *init.first()?;
        if suite < self.min_suite {
            return None;
        }
        let (outcome, resp) = respond(local, &self.peer, init).ok()?;
        let ratchet = RatchetState::initialize(outcome).ok()?;
        self.candidate = Some(Candidate {
            stage: CandidateStage::Established {
                ratchet: Box::new(ratchet),
                suite,
                suites_sent: false,
            },
            opened_at: now,
        });
        let resp = resp.to_vec();
        self.remember_answer(init, &resp);
        Some(resp)
    }

    /// Abre a candidata como iniciador, em resposta a um `REOPEN` válido, e
    /// diz se ela é nova. Com uma INIT ainda sem resposta, devolve a mesma:
    /// abrir outra invalidaria a RESP que talvez já esteja a caminho, e o par
    /// responde a uma INIT repetida com a RESP de antes.
    fn open_initiator_candidate(
        &mut self,
        local: &LocalIdentity,
        now: u64,
    ) -> Result<(Vec<u8>, bool)> {
        if let Some(Candidate {
            stage: CandidateStage::AwaitingResponse { init, .. },
            ..
        }) = &self.candidate
        {
            return Ok((init.clone(), false));
        }
        let suite_id = self
            .agreed_upgrade_suite
            .unwrap_or(self.current_suite)
            .max(self.min_suite);
        let suite = Suite::from_id(suite_id)?;
        let (initiator, init) = Initiator::start_with_suite(local, &self.peer, suite)?;
        let init = init.to_vec();
        self.candidate = Some(Candidate {
            stage: CandidateStage::AwaitingResponse {
                initiator: Box::new(initiator),
                init: init.clone(),
                suite: suite_id,
            },
            opened_at: now,
        });
        Ok((init, true))
    }

    /// Conclui a candidata de iniciador com a RESP e devolve o primeiro
    /// envelope dela (`CONTROL_SUITES`), que é o que o par usa para confirmar.
    /// A candidata segue não promovida até o par responder sob ela.
    fn finish_initiator_candidate(
        &mut self,
        local: &LocalIdentity,
        resp: &[u8],
        transport: Transport,
    ) -> Option<Vec<u8>> {
        let Candidate { stage, opened_at } = self.candidate.take()?;
        let CandidateStage::AwaitingResponse { initiator, suite, .. } = stage else {
            return None;
        };
        // Em erro, a candidata é descartada: `finish` consome o `Initiator`
        // (mesma razão de §11.1). O respondedor, sem confirmação, repete o
        // `REOPEN` ao receber tráfego que não lê, e isso abre outra.
        let outcome = initiator.finish(local, resp).ok()?;
        let mut ratchet = RatchetState::initialize(outcome).ok()?;
        let suites = seal_with(
            &mut ratchet,
            PacketType::ControlSuites,
            Self::control_suites_payload(),
            transport,
        )
        .ok()
        .map(|(bytes, _)| bytes);
        self.candidate = Some(Candidate {
            stage: CandidateStage::Established {
                ratchet: Box::new(ratchet),
                suite,
                suites_sent: suites.is_some(),
            },
            opened_at,
        });
        suites
    }

    fn try_candidate(&mut self, bytes: &[u8], transport: Transport) -> Option<InnerPlaintext> {
        match &mut self.candidate {
            Some(Candidate {
                stage: CandidateStage::Established { ratchet, .. },
                ..
            }) => try_decrypt(ratchet, bytes, transport).ok(),
            _ => None,
        }
    }

    /// Troca a sessão atual pela candidata, que acabou de provar a chave.
    /// Vale mesmo depois do prazo de [`CANDIDATE_TIMEOUT_SECS`]: o prazo só
    /// libera a fila, e uma confirmação tardia continua sendo prova de chave.
    ///
    /// Campo novo em `Session` precisa de decisão aqui. Ficam de propósito:
    /// `peer`, `min_suite`, `reopen_key`, `direction`, `reopen_seen` (o par e o
    /// guarda não mudam), `last_signal_at` e `last_candidate_at` (limites de
    /// taxa valem através da troca), `answered_init` (é a INIT desta
    /// candidata) e `peer_confirmed`, que quem chama (`accept`) acerta.
    fn promote_candidate(&mut self) {
        let Some(Candidate {
            stage: CandidateStage::Established { ratchet, suite, suites_sent },
            ..
        }) = self.candidate.take()
        else {
            return;
        };
        self.state = SessionState::Established(ratchet);
        self.current_suite = suite;
        self.suites_sent = suites_sent;
        self.agreed_upgrade_suite = None;
        self.consecutive_aead_failures = 0;
        self.needs_rehandshake = false;
        self.pending_outgoing_handshake = None;
        self.generation = self.generation.wrapping_add(1);
    }
}

#[cfg(test)]
mod tests {
    use super::super::MAX_CONSECUTIVE_AEAD_FAILURES;
    use super::*;

    fn pair() -> (LocalIdentity, LocalIdentity) {
        let a = LocalIdentity::generate().unwrap();
        let b = LocalIdentity::generate().unwrap();
        if a.public().is_before(&b.public()) {
            (a, b)
        } else {
            (b, a)
        }
    }

    fn now() -> u64 {
        crate::util::time::unix_seconds()
    }

    fn text(session: &mut Session, body: &[u8]) -> Vec<u8> {
        session
            .encrypt_outgoing(PacketType::MsgText, body.to_vec(), Transport::DataChannel)
            .unwrap()
    }

    fn recv(session: &mut Session, local: &LocalIdentity, bytes: &[u8]) -> Received {
        session.receive(local, bytes, Transport::DataChannel).unwrap()
    }

    fn recv_at(session: &mut Session, local: &LocalIdentity, bytes: &[u8], at: u64) -> Received {
        session
            .receive_at(local, bytes, Transport::DataChannel, at)
            .unwrap()
    }

    fn body_of(received: &Received) -> Option<&[u8]> {
        received.message.as_ref().map(|m| m.body.as_slice())
    }

    /// Alice inicia, Bob responde; os dois já trocaram os anúncios de suíte.
    fn established_pair() -> (LocalIdentity, Session, LocalIdentity, Session) {
        let (alice, bob) = pair();
        let (mut alice_session, init) = Session::open(&alice, bob.public(), 1).unwrap();
        let (mut bob_session, none) = Session::open(&bob, alice.public(), 1).unwrap();
        assert!(none.is_none());
        let resp = recv(&mut bob_session, &bob, &init.unwrap()).reply.unwrap();
        let suites = recv(&mut alice_session, &alice, &resp).reply.unwrap();
        let back = recv(&mut bob_session, &bob, &suites).reply.unwrap();
        recv(&mut alice_session, &alice, &back);
        (alice, alice_session, bob, bob_session)
    }

    /// Os dois lados conversam nas duas direções.
    fn assert_talks(
        alice: &LocalIdentity,
        alice_session: &mut Session,
        bob: &LocalIdentity,
        bob_session: &mut Session,
    ) {
        let a = text(alice_session, b"oi bob");
        assert_eq!(body_of(&recv(bob_session, bob, &a)), Some(&b"oi bob"[..]));
        let b = text(bob_session, b"oi alice");
        assert_eq!(body_of(&recv(alice_session, alice, &b)), Some(&b"oi alice"[..]));
    }

    #[test]
    fn first_handshake_through_receive_announces_suites_both_ways() {
        let (alice, bob) = pair();
        let (mut alice_session, init) = Session::open(&alice, bob.public(), 1).unwrap();
        let (mut bob_session, _) = Session::open(&bob, alice.public(), 1).unwrap();

        let resp = recv(&mut bob_session, &bob, &init.unwrap()).reply.unwrap();
        let alice_suites = recv(&mut alice_session, &alice, &resp).reply.unwrap();
        let got = recv(&mut bob_session, &bob, &alice_suites);
        assert_eq!(got.message.unwrap().packet_type, PacketType::ControlSuites);
        let bob_suites = got.reply.expect("o respondedor anuncia ao ganhar cadeia de envio");
        let back = recv(&mut alice_session, &alice, &bob_suites);
        assert_eq!(back.message.unwrap().packet_type, PacketType::ControlSuites);
        assert!(back.reply.is_none(), "cada lado anuncia uma vez só");

        assert_talks(&alice, &mut alice_session, &bob, &mut bob_session);
    }

    #[test]
    fn initiator_reopens_and_established_responder_follows_without_action() {
        let (alice, _old_alice, bob, mut bob_session) = established_pair();

        let (mut alice_session, init) = Session::open(&alice, bob.public(), 1).unwrap();
        let opened = recv(&mut bob_session, &bob, &init.unwrap());
        assert!(opened.candidate_opened);
        assert!(bob_session.is_renewing());

        let suites = recv(&mut alice_session, &alice, &opened.reply.unwrap()).reply.unwrap();
        let confirmed = recv(&mut bob_session, &bob, &suites);
        assert!(confirmed.message.is_some());
        assert_eq!(bob_session.generation(), 1);
        assert!(!bob_session.is_renewing());
        recv(&mut alice_session, &alice, &confirmed.reply.unwrap());

        assert_talks(&alice, &mut alice_session, &bob, &mut bob_session);
    }

    #[test]
    fn responder_reopens_with_signal_and_established_initiator_follows() {
        let (alice, mut alice_session, bob, _old_bob) = established_pair();

        let (mut bob_session, none) = Session::open(&bob, alice.public(), 1).unwrap();
        assert!(none.is_none());
        let signal = bob_session.connect_signal().unwrap().unwrap();
        assert_eq!(signal.len(), reopen::REOPEN_LEN);

        let opened = recv(&mut alice_session, &alice, &signal);
        assert!(opened.candidate_opened);
        let init = opened.reply.unwrap();
        assert_eq!(init.len(), INIT_LEN);
        // Reconectar o canal agora republica a mesma INIT.
        assert_eq!(alice_session.connect_signal().unwrap(), Some(init.clone()));

        let resp = recv(&mut bob_session, &bob, &init).reply.unwrap();
        let suites = recv(&mut alice_session, &alice, &resp).reply.unwrap();
        // RESP sozinha não prova nada: a sessão de Alice continua a antiga.
        assert_eq!(alice_session.generation(), 0);
        assert!(alice_session.is_renewing());

        let bob_suites = recv(&mut bob_session, &bob, &suites).reply.unwrap();
        recv(&mut alice_session, &alice, &bob_suites);
        assert_eq!(alice_session.generation(), 1);
        assert!(!alice_session.is_renewing());

        assert_talks(&alice, &mut alice_session, &bob, &mut bob_session);
    }

    #[test]
    fn repeated_init_gets_the_same_resp_and_both_sides_converge() {
        let (alice, _old_alice, bob, mut bob_session) = established_pair();
        let (mut alice_session, init) = Session::open(&alice, bob.public(), 1).unwrap();
        let init = init.unwrap();

        let first = recv(&mut bob_session, &bob, &init);
        // O canal oscilou e Alice republicou a mesma INIT.
        let again = recv(&mut bob_session, &bob, &init);
        assert!(!again.candidate_opened);
        assert_eq!(again.reply, first.reply);

        let suites = recv(&mut alice_session, &alice, &first.reply.unwrap()).reply.unwrap();
        let back = recv(&mut bob_session, &bob, &suites).reply.unwrap();
        recv(&mut alice_session, &alice, &back);
        assert_talks(&alice, &mut alice_session, &bob, &mut bob_session);
    }

    #[test]
    fn crossed_restart_does_not_open_a_pointless_candidate() {
        let (alice, bob) = pair();
        let (mut alice_session, _) = Session::open(&alice, bob.public(), 1).unwrap();
        let (mut bob_session, _) = Session::open(&bob, alice.public(), 1).unwrap();

        // Os dois reiniciaram: o `REOPEN` de Bob e a INIT de Alice se cruzam.
        let init = alice_session.connect_signal().unwrap().unwrap();
        let signal = bob_session.connect_signal().unwrap().unwrap();
        let resp = recv(&mut bob_session, &bob, &init).reply.unwrap();
        let init_again = recv(&mut alice_session, &alice, &signal).reply.unwrap();
        assert_eq!(init_again, init);

        let repeated = recv(&mut bob_session, &bob, &init_again);
        assert!(!repeated.candidate_opened);
        assert_eq!(repeated.reply.as_deref(), Some(resp.as_slice()));
        assert!(!bob_session.is_renewing());

        let suites = recv(&mut alice_session, &alice, &resp).reply.unwrap();
        // A RESP repetida chega depois que Alice já estabeleceu: ignorada.
        let late = recv(&mut alice_session, &alice, &resp);
        assert!(late.reply.is_none() && late.message.is_none());
        let back = recv(&mut bob_session, &bob, &suites).reply.unwrap();
        recv(&mut alice_session, &alice, &back);
        assert_talks(&alice, &mut alice_session, &bob, &mut bob_session);
    }

    #[test]
    fn junk_resp_kills_the_candidate_but_the_unconfirmed_responder_asks_again() {
        let (alice, mut alice_session, bob, _old_bob) = established_pair();
        let t = now();
        let (mut bob_session, _) = Session::open(&bob, alice.public(), 1).unwrap();
        let signal = bob_session.connect_signal_at(t).unwrap().unwrap();
        let init = recv_at(&mut alice_session, &alice, &signal, t).reply.unwrap();
        let real_resp = recv_at(&mut bob_session, &bob, &init, t).reply.unwrap();

        // Alguém injeta 1122 B de lixo antes da RESP verdadeira.
        let junk = crate::util::rng::array::<RESP_LEN>().unwrap();
        recv_at(&mut alice_session, &alice, &junk, t);
        assert!(recv_at(&mut alice_session, &alice, &real_resp, t).reply.is_none());

        // Alice segue na sessão antiga; Bob não a lê e pede de novo.
        let stale = text(&mut alice_session, b"perdida");
        let later = t + SIGNAL_INTERVAL_SECS;
        let again = recv_at(&mut bob_session, &bob, &stale, later).reply.unwrap();
        assert_eq!(again.len(), reopen::REOPEN_LEN);

        let init2 = recv_at(&mut alice_session, &alice, &again, later).reply.unwrap();
        let resp2 = recv_at(&mut bob_session, &bob, &init2, later).reply.unwrap();
        let suites = recv_at(&mut alice_session, &alice, &resp2, later).reply.unwrap();
        let back = recv_at(&mut bob_session, &bob, &suites, later).reply.unwrap();
        recv_at(&mut alice_session, &alice, &back, later);
        assert_talks(&alice, &mut alice_session, &bob, &mut bob_session);
    }

    #[test]
    fn late_reopen_reuses_the_init_still_waiting_for_resp() {
        let (alice, mut alice_session, bob, _old_bob) = established_pair();
        let t = now();
        let (mut bob_session, _) = Session::open(&bob, alice.public(), 1).unwrap();
        let first = bob_session.connect_signal_at(t).unwrap().unwrap();
        let init = recv_at(&mut alice_session, &alice, &first, t).reply.unwrap();

        let later = t + SIGNAL_INTERVAL_SECS + 1;
        let second = bob_session.connect_signal_at(later).unwrap().unwrap();
        let got = recv_at(&mut alice_session, &alice, &second, later);
        assert_eq!(got.reply, Some(init));
        assert!(!got.candidate_opened);
    }

    #[test]
    fn newer_init_replaces_the_candidate_and_only_it_confirms() {
        let (alice, _old_alice, bob, mut bob_session) = established_pair();
        let t = now();
        let (_first_alice, init1) = Session::open(&alice, bob.public(), 1).unwrap();
        recv_at(&mut bob_session, &bob, &init1.unwrap(), t);

        // Alice reabriu de novo antes de concluir.
        let later = t + SIGNAL_INTERVAL_SECS;
        let (mut alice_session, init2) = Session::open(&alice, bob.public(), 1).unwrap();
        let opened = recv_at(&mut bob_session, &bob, &init2.unwrap(), later);
        assert!(opened.candidate_opened);
        let suites = recv(&mut alice_session, &alice, &opened.reply.unwrap()).reply.unwrap();
        let back = recv(&mut bob_session, &bob, &suites).reply.unwrap();
        recv(&mut alice_session, &alice, &back);
        assert_talks(&alice, &mut alice_session, &bob, &mut bob_session);
    }

    #[test]
    fn init_dropped_by_the_rate_limit_is_sent_again_on_stale_traffic() {
        let (alice, _old_alice, bob, mut bob_session) = established_pair();
        // Antigo o bastante para a retenção já ter passado no relógio real.
        let t = now() - CANDIDATE_TIMEOUT_SECS - SIGNAL_INTERVAL_SECS - 5;
        let (_first_alice, init1) = Session::open(&alice, bob.public(), 1).unwrap();
        recv_at(&mut bob_session, &bob, &init1.unwrap(), t);

        // Alice reabre de novo 5 s depois: a INIT nova cai no limite de taxa.
        let (mut alice_session, init2) = Session::open(&alice, bob.public(), 1).unwrap();
        let init2 = init2.unwrap();
        assert!(recv_at(&mut bob_session, &bob, &init2, t + 5).reply.is_none());

        // Bob escreve pela sessão antiga; Alice não lê e repete a INIT.
        let stale = text(&mut bob_session, b"pela sessao velha");
        let later = t + SIGNAL_INTERVAL_SECS + 5;
        let again = recv_at(&mut alice_session, &alice, &stale, later).reply.unwrap();
        assert_eq!(again, init2);

        let resp = recv_at(&mut bob_session, &bob, &again, later).reply.unwrap();
        let suites = recv(&mut alice_session, &alice, &resp).reply.unwrap();
        let back = recv(&mut bob_session, &bob, &suites).reply.unwrap();
        recv(&mut alice_session, &alice, &back);
        assert_talks(&alice, &mut alice_session, &bob, &mut bob_session);
    }

    #[test]
    fn candidate_creation_is_rate_limited() {
        let (_alice, _alice_session, bob, mut bob_session) = established_pair();
        let t = now();
        let forge = || {
            let mallory = LocalIdentity::generate().unwrap();
            Initiator::start(&mallory, &bob.public()).unwrap().1
        };
        assert!(recv_at(&mut bob_session, &bob, &forge(), t).candidate_opened);
        let second = recv_at(&mut bob_session, &bob, &forge(), t + 1);
        assert!(!second.candidate_opened && second.reply.is_none());
        assert!(recv_at(&mut bob_session, &bob, &forge(), t + SIGNAL_INTERVAL_SECS).candidate_opened);
    }

    #[test]
    fn failed_responder_recovers_when_initiator_reopens() {
        let (alice, _old_alice, bob, mut bob_session) = established_pair();
        for _ in 0..MAX_CONSECUTIVE_AEAD_FAILURES {
            let garbage = crate::util::rng::array::<{ reopen::REOPEN_LEN }>().unwrap();
            recv(&mut bob_session, &bob, &garbage);
        }
        assert!(bob_session.is_failed());

        let (mut alice_session, init) = Session::open(&alice, bob.public(), 1).unwrap();
        let resp = recv(&mut bob_session, &bob, &init.unwrap()).reply.unwrap();
        let suites = recv(&mut alice_session, &alice, &resp).reply.unwrap();
        let reply = recv(&mut bob_session, &bob, &suites).reply.unwrap();
        recv(&mut alice_session, &alice, &reply);

        assert!(bob_session.is_established());
        assert_talks(&alice, &mut alice_session, &bob, &mut bob_session);
    }

    #[test]
    fn failed_initiator_recovers_when_responder_reopens() {
        let (alice, mut alice_session, bob, _old_bob) = established_pair();
        for _ in 0..MAX_CONSECUTIVE_AEAD_FAILURES {
            let garbage = crate::util::rng::array::<{ reopen::REOPEN_LEN }>().unwrap();
            recv(&mut alice_session, &alice, &garbage);
        }
        assert!(alice_session.is_failed());

        let (mut bob_session, _) = Session::open(&bob, alice.public(), 1).unwrap();
        let signal = bob_session.connect_signal().unwrap().unwrap();
        let init = recv(&mut alice_session, &alice, &signal).reply.unwrap();
        let resp = recv(&mut bob_session, &bob, &init).reply.unwrap();
        let suites = recv(&mut alice_session, &alice, &resp).reply.unwrap();
        let reply = recv(&mut bob_session, &bob, &suites).reply.unwrap();
        recv(&mut alice_session, &alice, &reply);

        assert!(alice_session.is_established());
        assert_talks(&alice, &mut alice_session, &bob, &mut bob_session);
    }

    #[test]
    fn forged_init_never_breaks_the_live_session() {
        let (_alice, mut alice_session, bob, mut bob_session) = established_pair();
        let mallory = LocalIdentity::generate().unwrap();
        let (_, forged) = Initiator::start(&mallory, &bob.public()).unwrap();

        let opened = recv(&mut bob_session, &bob, &forged);
        assert!(opened.candidate_opened);
        assert!(opened.reply.is_some(), "INIT não é autenticada: a RESP sai mesmo assim");

        let a = text(&mut alice_session, b"ainda aqui");
        assert_eq!(body_of(&recv(&mut bob_session, &bob, &a)), Some(&b"ainda aqui"[..]));
        assert_eq!(bob_session.generation(), 0);
    }

    #[test]
    fn sends_are_held_while_renewing_and_resume_after_timeout() {
        let (_alice, _alice_session, bob, mut bob_session) = established_pair();
        let mallory = LocalIdentity::generate().unwrap();
        let (_, forged) = Initiator::start(&mallory, &bob.public()).unwrap();

        let stale = now() - CANDIDATE_TIMEOUT_SECS - 1;
        recv_at(&mut bob_session, &bob, &forged, stale);
        assert!(!bob_session.is_renewing());
        assert!(bob_session
            .encrypt_outgoing(PacketType::MsgText, b"x".to_vec(), Transport::DataChannel)
            .is_ok());

        let (_, forged2) = Initiator::start(&mallory, &bob.public()).unwrap();
        recv(&mut bob_session, &bob, &forged2);
        assert!(bob_session
            .encrypt_outgoing(PacketType::MsgText, b"x".to_vec(), Transport::DataChannel)
            .is_err());
    }

    #[test]
    fn clock_moving_back_does_not_extend_the_hold() {
        let (_alice, _alice_session, bob, mut bob_session) = established_pair();
        let mallory = LocalIdentity::generate().unwrap();
        let (_, forged) = Initiator::start(&mallory, &bob.public()).unwrap();
        let t = now();
        recv_at(&mut bob_session, &bob, &forged, t);
        assert!(bob_session.is_renewing_at(t));
        assert!(!bob_session.is_renewing_at(t - 100));
    }

    #[test]
    fn expired_candidate_is_still_promoted_by_a_late_confirmation() {
        let (alice, _old_alice, bob, mut bob_session) = established_pair();
        let (mut alice_session, init) = Session::open(&alice, bob.public(), 1).unwrap();
        let stale = now() - CANDIDATE_TIMEOUT_SECS - 1;
        let resp = recv_at(&mut bob_session, &bob, &init.unwrap(), stale).reply.unwrap();
        assert!(!bob_session.is_renewing());

        let suites = recv(&mut alice_session, &alice, &resp).reply.unwrap();
        recv(&mut bob_session, &bob, &suites);
        assert_eq!(bob_session.generation(), 1);
    }

    #[test]
    fn replayed_reopen_is_rejected() {
        let (alice, mut alice_session, bob, _bob_session) = established_pair();
        let (mut bob_session, _) = Session::open(&bob, alice.public(), 1).unwrap();
        let signal = bob_session.connect_signal().unwrap().unwrap();

        assert!(recv(&mut alice_session, &alice, &signal).candidate_opened);
        let again = recv(&mut alice_session, &alice, &signal);
        assert!(!again.candidate_opened);
        assert!(again.reply.is_none());
    }

    #[test]
    fn own_reopen_reflected_back_is_rejected() {
        let (alice, mut alice_session, _bob, _bob_session) = established_pair();
        let reflected =
            reopen::seal_at(&alice_session.reopen_key, alice_session.direction, now()).unwrap();
        assert!(!recv(&mut alice_session, &alice, &reflected).candidate_opened);
    }

    #[test]
    fn confirmed_responder_never_answers_a_reopen() {
        let (_alice, alice_session, bob, mut bob_session) = established_pair();
        let signal =
            reopen::seal_at(&alice_session.reopen_key, alice_session.direction, now()).unwrap();
        let got = recv(&mut bob_session, &bob, &signal);
        assert!(!got.candidate_opened);
        assert!(got.reply.is_none());
    }

    #[test]
    fn awaiting_response_answers_stale_envelopes_with_its_init_instead_of_failing() {
        let (alice, _old_alice, bob, mut bob_session) = established_pair();
        let stale = text(&mut bob_session, b"da sessao velha");

        let (mut alice_session, init) = Session::open(&alice, bob.public(), 1).unwrap();
        let got = recv(&mut alice_session, &alice, &stale);
        assert!(got.message.is_none());
        assert_eq!(got.reply, init, "o par não está na nossa sessão: repete a INIT");
        assert!(!alice_session.is_failed());
        assert_eq!(alice_session.pending_outgoing_handshake(), init.as_deref());
    }

    #[test]
    fn awaiting_response_resends_init_on_reopen_at_most_every_interval() {
        let (alice, bob) = pair();
        let (mut alice_session, init) = Session::open(&alice, bob.public(), 1).unwrap();
        let (mut bob_session, _) = Session::open(&bob, alice.public(), 1).unwrap();

        let t = now();
        let first = bob_session.connect_signal_at(t).unwrap().unwrap();
        assert_eq!(recv_at(&mut alice_session, &alice, &first, t).reply, init);

        let second = bob_session.connect_signal_at(t + 1).unwrap().unwrap();
        assert!(recv_at(&mut alice_session, &alice, &second, t + 1).reply.is_none());

        let later = t + SIGNAL_INTERVAL_SECS + 1;
        let third = bob_session.connect_signal_at(later).unwrap().unwrap();
        assert_eq!(recv_at(&mut alice_session, &alice, &third, later).reply, init);
    }

    #[test]
    fn awaiting_init_answers_unreadable_traffic_with_rate_limited_reopen() {
        let (alice, mut alice_session, bob, _old_bob) = established_pair();
        let (mut bob_session, _) = Session::open(&bob, alice.public(), 1).unwrap();
        let t = now();

        let stale = text(&mut alice_session, b"para a sessao que sumiu");
        let signal = recv_at(&mut bob_session, &bob, &stale, t)
            .reply
            .expect("o respondedor lembra o par de que reabriu");
        assert_eq!(signal.len(), reopen::REOPEN_LEN);
        assert!(recv_at(&mut bob_session, &bob, &stale, t + 1).reply.is_none());

        assert!(recv(&mut alice_session, &alice, &signal).candidate_opened);
    }

    #[test]
    fn connect_signal_is_none_for_a_confirmed_session() {
        let (_alice, mut alice_session, _bob, mut bob_session) = established_pair();
        assert!(alice_session.connect_signal().unwrap().is_none());
        assert!(bob_session.connect_signal().unwrap().is_none());
    }

    #[test]
    fn valid_reopen_and_stray_resp_do_not_count_as_aead_failures() {
        let (alice, mut alice_session, bob, _bob_session) = established_pair();
        for _ in 0..MAX_CONSECUTIVE_AEAD_FAILURES - 1 {
            let garbage = crate::util::rng::array::<{ reopen::REOPEN_LEN }>().unwrap();
            recv(&mut alice_session, &alice, &garbage);
        }
        let stray = crate::util::rng::array::<RESP_LEN>().unwrap();
        recv(&mut alice_session, &alice, &stray);
        let (mut bob_session, _) = Session::open(&bob, alice.public(), 1).unwrap();
        let signal = bob_session.connect_signal().unwrap().unwrap();
        recv(&mut alice_session, &alice, &signal);
        assert!(!alice_session.is_failed());
    }
}
