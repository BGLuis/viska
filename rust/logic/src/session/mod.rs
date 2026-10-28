//! Camada de sessão — `docs/protocol.md` §11 (conteúdo novo, não existia na
//! spec original: `crypto::handshake`, `crypto::ratchet`, `wire` e
//! `crypto::aead` já existiam isolados, mas nada os costurava numa sessão
//! viva). Ver `docs/reports/FASE-3-TRANSPORTE-REMOTO-E-CHAT.md` para o
//! histórico da decisão.
//!
//! `Session` decide o papel (iniciador/respondedor) via
//! `PublicIdentity::is_before` (§4), encaminha bytes de handshake enquanto a
//! sessão não está estabelecida, e depois cifra/decifra envelopes encadeando
//! `crypto::ratchet` → `wire` → `crypto::aead`, exatamente na ordem descrita
//! em `wire::mod` (D14: o `dh_pub` do cabeçalho do ratchet sai em claro no
//! envelope, não mais dentro do plaintext cifrado).
//!
//! ## A segunda circularidade: `pn`, `kem_ek`, `kem_ct`
//!
//! Só `dh_pub` foi movido para claro (D14) — `pn`, `kem_ek` e `kem_ct`
//! continuam dentro do plaintext cifrado, como `docs/protocol.md` §6.1 já
//! descrevia. Isso é seguro porque, rastreando `crypto::ratchet::receiving_key`
//! a fundo: esses três campos só influenciam a reconciliação de `RK` e do
//! cache de mensagens puladas (aplicada em `pending`, só efetiva depois de
//! `commit_receive`) — nunca a derivação da `message_key` da mensagem atual,
//! que depende só de `dh_pub` e do `counter` (ambos já em claro). Por isso
//! `decrypt_incoming` chama `receiving_key` duas vezes: a primeira com
//! `pn: 0, kem_ek: None, kem_ct: None` (o suficiente para abrir o AEAD), e —
//! só depois que o AEAD confirma a mensagem — uma segunda vez com os valores
//! reais, agora conhecidos, para que `commit_receive` aplique o estado
//! correto. `receiving_key` é idempotente em relação ao estado de confiança
//! (não muda nada até `commit_receive`), então repetir a chamada é seguro por
//! desenho do próprio módulo `ratchet`, não uma suposição nova daqui.

use crate::crypto::aead;
use crate::crypto::handshake::{respond, Initiator};
use crate::crypto::identity::{LocalIdentity, PublicIdentity};
use crate::crypto::ratchet::{RatchetHeader, RatchetState};
use crate::crypto::suite::Suite;
use crate::wire::envelope;
use crate::wire::packet_type::PacketType;
use crate::wire::plaintext::InnerPlaintext;
use crate::wire::transport::Transport;
use crate::{Error, Result};

/// Limiar de segurança do contador de envio (`Ns`), bem abaixo de `u32::MAX`
/// — várias ordens de grandeza acima do gatilho de re-KEM de 256 mensagens
/// (§5.4), que na prática já reseta a cadeia bem antes disso. Existe para o
/// caso que a spec original nunca cobriu: um "monólogo" unidirecional em que
/// o par nunca responde, e portanto a cadeia de envio nunca passa por um
/// passo DH que zeraria `Ns` de novo. Cruzá-lo marca a sessão para renovação
/// sem quebrar a mensagem que já está saindo — `docs/protocol.md` §11.3.
#[cfg(not(test))]
const COUNTER_REHANDSHAKE_THRESHOLD: u32 = 1 << 24;
/// Em teste, um limiar bem menor — testar o valor de produção exigiria
/// enviar 16 milhões de mensagens. `RatchetState` não expõe um jeito de
/// forjar `Ns` fora do próprio módulo `crypto::ratchet` (o auxiliar
/// `force_ns_for_test` de lá é privado ao módulo dele), então este é o único
/// jeito de exercitar a transição sem depender de tempo de execução absurdo.
/// Precisa ficar acima da maior contagem de mensagens que qualquer outro
/// teste deste módulo envia numa única direção (hoje, 500 em
/// `dois_pares_completam_handshake_e_trocam_mil_mensagens_alternadas`) —
/// senão este limiar dispara no meio de um teste que não é sobre ele.
#[cfg(test)]
const COUNTER_REHANDSHAKE_THRESHOLD: u32 = 600;

/// Falhas de AEAD consecutivas (contadas só em memória, nunca persistidas)
/// que fazem a sessão desistir e exigir handshake novo. Acima disso, assume-se
/// dessincronia irrecuperável — por exemplo, o par perdeu o estado do ratchet
/// e reiniciou do zero — em vez de continuar tentando indefinidamente. Não é
/// um valor normativo da spec (que não cobre isso); é uma política nova,
/// registrada em `docs/protocol.md` §11.1.
const MAX_CONSECUTIVE_AEAD_FAILURES: u32 = 8;

/// Estado de uma sessão — `docs/protocol.md` §11.1.
///
/// Só dois estados guardam dado: `AwaitingResponse` (somos iniciador, INIT já
/// enviado) e `Established` (handshake concluído). Não existe um estado
/// separado para "respondedor que ainda não pode enviar": `RatchetState` já
/// erra sozinho (`Error::InvalidState`) se `encrypt_outgoing` for chamado
/// antes da primeira mensagem do iniciador ser processada — duplicar essa
/// checagem aqui só criaria dois lugares para ela divergir.
#[derive(Debug)]
enum SessionState {
    /// Somos respondedor; nada foi enviado ainda, aguardando a INIT do par.
    AwaitingPeerInit,
    /// Somos iniciador; a INIT já foi enviada, aguardando a RESP.
    ///
    /// Em `Box`: `Initiator` carrega uma chave secreta ML-KEM-768 inteira, o
    /// que tornaria toda instância de `SessionState` do tamanho da maior
    /// variante mesmo nas outras — inclusive `AwaitingPeerInit`, que não
    /// deveria custar quase nada.
    AwaitingResponse(Box<Initiator>),
    /// Handshake concluído; ratchet vivo. Também em `Box` pelo mesmo motivo
    /// (`RatchetState` guarda material ML-KEM do ciclo de re-KEM em aberto).
    Established(Box<RatchetState>),
    /// Violação de protocolo ou contador esgotado — exige `Session::open` novo.
    Failed,
}

/// Uma sessão de mensagens com um contato já pareado.
///
/// Não guarda `LocalIdentity` nem uma referência a ela — cada método que
/// precisa da identidade de longo prazo a recebe como parâmetro. Isso não é
/// só estilo: `crypto::handshake::Initiator` não tem mais lifetime nenhum
/// desde que deixou de guardar essa referência (a mudança que tornou este
/// módulo possível — uma `Session` que vivesse entre duas chamadas de FFI
/// separadas com um `Initiator<'a>` dentro seria uma struct autorreferencial,
/// inviável sem `unsafe`, proibido neste crate).
#[derive(Debug)]
pub struct Session {
    peer: PublicIdentity,
    current_suite: u8,
    min_suite: u8,
    agreed_upgrade_suite: Option<u8>,
    peer_confirmed: bool,
    state: SessionState,
    consecutive_aead_failures: u32,
    needs_rehandshake: bool,
    /// Bytes da INIT, guardados enquanto somos iniciador e ainda não
    /// recebemos a RESP — `Some` só nesse intervalo. Existe porque mais de
    /// um consumidor da camada FFI precisa desses bytes em momentos
    /// diferentes (por exemplo: quem decide a oferta SDP do transporte
    /// WebRTC só precisa saber que existem; quem efetivamente publica a
    /// mensagem de handshake no canal, mais tarde, precisa dos bytes em si).
    /// Um único retorno "de uso único" no momento de `open` não serve para
    /// os dois; isto torna a pergunta "sou eu quem inicia, e com que
    /// bytes?" respondível quantas vezes for preciso enquanto a resposta
    /// continuar sendo a mesma.
    pending_outgoing_handshake: Option<Vec<u8>>,
}

impl Session {
    /// Abre uma sessão com `peer`, decidindo o papel por `is_before` (§4).
    ///
    /// `recorded_suite` indica a suíte em que o contato está registrado.
    pub fn open(
        local: &LocalIdentity,
        peer: PublicIdentity,
        recorded_suite: u8,
    ) -> Result<(Self, Option<Vec<u8>>)> {
        Self::open_with_upgrade(local, peer, recorded_suite, None)
    }

    /// Abre uma sessão com `peer`, usando uma suíte negociada previamente em memória (`upgrade_suite`), se houver.
    ///
    /// Se o banco contiver uma suíte que o build não conhece, retorna `Error::UnsupportedVersion`.
    /// Se formos iniciador e houver uma suíte maior em memória suportada pelo build, inicia nela.
    /// Se formos respondedor, aceita INIT na suíte gravada ou maior (D24).
    pub fn open_with_upgrade(
        local: &LocalIdentity,
        peer: PublicIdentity,
        recorded_suite: u8,
        upgrade_suite: Option<u8>,
    ) -> Result<(Self, Option<Vec<u8>>)> {
        let base_suite = Suite::from_id(recorded_suite)?;

        let init_suite = match upgrade_suite {
            Some(target) if target > recorded_suite => Suite::from_id(target)?,
            _ => base_suite,
        };

        if local.public().is_before(&peer) {
            let (initiator, init_bytes) = Initiator::start_with_suite(local, &peer, init_suite)?;
            let init_bytes = init_bytes.to_vec();
            Ok((
                Self {
                    peer,
                    current_suite: init_suite.id(),
                    min_suite: recorded_suite,
                    agreed_upgrade_suite: None,
                    peer_confirmed: false,
                    state: SessionState::AwaitingResponse(Box::new(initiator)),
                    consecutive_aead_failures: 0,
                    needs_rehandshake: false,
                    pending_outgoing_handshake: Some(init_bytes.clone()),
                },
                Some(init_bytes),
            ))
        } else {
            Ok((
                Self {
                    peer,
                    current_suite: recorded_suite,
                    min_suite: recorded_suite,
                    agreed_upgrade_suite: None,
                    peer_confirmed: false,
                    state: SessionState::AwaitingPeerInit,
                    consecutive_aead_failures: 0,
                    needs_rehandshake: false,
                    pending_outgoing_handshake: None,
                },
                None,
            ))
        }
    }

    /// Os bytes da INIT, se ainda estivermos esperando a RESP do par —
    /// `None` em qualquer outro estado (respondedor, sessão já
    /// estabelecida, ou falha). Ao contrário do `Option<Vec<u8>>` que
    /// [`Self::open`] devolve uma única vez, este método pode ser chamado
    /// quantas vezes for preciso enquanto a sessão estiver nesse estado —
    /// sempre com a mesma resposta, porque os bytes ficam guardados até a
    /// RESP chegar (ou a sessão falhar).
    pub fn pending_outgoing_handshake(&self) -> Option<&[u8]> {
        self.pending_outgoing_handshake.as_deref()
    }

    /// `true` assim que o handshake concluiu e a sessão pode cifrar/decifrar.
    pub fn is_established(&self) -> bool {
        matches!(self.state, SessionState::Established(_))
    }

    /// `true` quando a sessão desistiu (RESP inválida, ou falhas de AEAD
    /// consecutivas acima do limiar) — só uma sessão nova (`Session::open`)
    /// resolve. Usado pela camada FFI para reportar o estado à UI.
    pub fn is_failed(&self) -> bool {
        matches!(self.state, SessionState::Failed)
    }

    /// `true` quando o contador de envio cruzou o limiar de segurança —
    /// `encrypt_outgoing` vai recusar novas mensagens até uma sessão nova.
    pub fn needs_rehandshake(&self) -> bool {
        self.needs_rehandshake
    }

    /// Retorna a suíte atualmente em uso nesta sessão.
    pub fn current_suite(&self) -> u8 {
        self.current_suite
    }

    /// Retorna a suíte acordada em memória para upgrade na próxima sessão, se houver.
    pub fn agreed_upgrade_suite(&self) -> Option<u8> {
        self.agreed_upgrade_suite
    }

    /// Retorna se a sessão já foi confirmada por ambos os pares.
    pub fn is_confirmed(&self) -> bool {
        self.peer_confirmed
    }

    /// Retorna se o contato deve ter sua `suite_id` elevada no banco local (D24).
    pub fn should_upgrade_contact(&self, recorded_suite: u8) -> bool {
        self.is_established() && self.peer_confirmed && self.current_suite > recorded_suite
    }

    /// Processa uma mensagem de handshake recebida (INIT ou RESP, conforme o
    /// estado atual) e devolve os bytes de resposta a enviar, se houver.
    ///
    /// A distinção entre "isto é handshake" e "isto é um envelope de sessão"
    /// nunca é um marcador no fio — isso contradiria D4 (nada além do
    /// contador e do `dh_pub` em claro). É puramente o estado local: enquanto
    /// não `Established`, todo byte recebido é handshake.
    pub fn process_handshake_message(
        &mut self,
        local: &LocalIdentity,
        bytes: &[u8],
    ) -> Result<Option<Vec<u8>>> {
        match std::mem::replace(&mut self.state, SessionState::Failed) {
            SessionState::AwaitingPeerInit => {
                let init_version = match bytes.first() {
                    Some(&v) => v,
                    None => {
                        self.state = SessionState::AwaitingPeerInit;
                        return Err(Error::BadLength {
                            expected: 1,
                            actual: 0,
                        });
                    }
                };
                if init_version < self.min_suite {
                    self.state = SessionState::AwaitingPeerInit;
                    return Err(Error::UnsupportedVersion(init_version));
                }
                match respond(local, &self.peer, bytes) {
                    Ok((outcome, resp_bytes)) => {
                        self.current_suite = init_version;
                        self.state =
                            SessionState::Established(Box::new(RatchetState::initialize(outcome)?));
                        Ok(Some(resp_bytes.to_vec()))
                    }
                    Err(err) => {
                        // `respond` é uma função livre — não consome nenhum
                        // estado nosso. Uma INIT malformada ou de tipo errado
                        // (por exemplo, uma RESP chegando aqui por engano) não
                        // custa nada tentar de novo quando a mensagem certa
                        // chegar, então o estado volta exatamente para onde
                        // estava, em vez de ficar em `Failed`.
                        self.state = SessionState::AwaitingPeerInit;
                        Err(err)
                    }
                }
            }
            SessionState::AwaitingResponse(initiator) => match initiator.finish(local, bytes) {
                Ok(outcome) => {
                    self.state =
                        SessionState::Established(Box::new(RatchetState::initialize(outcome)?));
                    self.peer_confirmed = true;
                    self.pending_outgoing_handshake = None;
                    Ok(None)
                }
                Err(err) => {
                    // A sessão vai para `Failed` neste ramo (ver comentário
                    // abaixo) — os bytes pendentes não servem mais para
                    // nada, mesma razão de limpar no caminho de sucesso.
                    self.pending_outgoing_handshake = None;
                    // Ao contrário de `respond`, `finish` consome o
                    // `Initiator` mesmo quando falha — o material efêmero já
                    // foi movido para dentro da chamada. Recuperá-lo exigiria
                    // clonar `ek_secret`/`kem_secret`, uma cópia extra de
                    // segredo só para permitir uma segunda tentativa. Preferimos
                    // abandonar esta tentativa: o estado já foi trocado para
                    // `Failed` pelo `mem::replace` acima, e quem chama abre
                    // uma sessão nova (`Session::open`) com efêmeras frescas.
                    Err(err)
                }
            },
            SessionState::Established(ratchet) => {
                self.state = SessionState::Established(ratchet);
                Err(Error::InvalidState(
                    "mensagem de handshake recebida após a sessão já estar estabelecida",
                ))
            }
            SessionState::Failed => Err(Error::InvalidState(
                "sessão falhou; abra uma sessão nova com Session::open",
            )),
        }
    }

    /// Cifra `body` como `packet_type` e devolve o envelope pronto para o
    /// transporte. Erra se a sessão ainda não está estabelecida, já falhou,
    /// ou já cruzou o limiar de segurança do contador ([`Self::needs_rehandshake`]).
    pub fn encrypt_outgoing(
        &mut self,
        packet_type: PacketType,
        body: Vec<u8>,
        transport: Transport,
    ) -> Result<Vec<u8>> {
        if self.needs_rehandshake {
            return Err(Error::NeedsRehandshake);
        }

        let ratchet = match &mut self.state {
            SessionState::Established(ratchet) => ratchet,
            SessionState::Failed => {
                return Err(Error::InvalidState(
                    "sessão falhou; abra uma sessão nova com Session::open",
                ))
            }
            _ => return Err(Error::InvalidState("sessão ainda não estabelecida")),
        };

        let (header, message_key) = ratchet.next_sending_key()?;
        let counter = header.counter;
        let dh_pub = header.dh_pub;

        let mut buffer = InnerPlaintext {
            packet_type,
            pn: header.pn,
            kem_ek: header.kem_ek,
            kem_ct: header.kem_ct,
            body,
        }
        .encode(transport)?;

        let aad = envelope::aad(counter, &dh_pub);
        aead::seal(&message_key, counter, &aad, &mut buffer)?;
        let envelope_bytes = envelope::encode(counter, &dh_pub, &buffer);

        if counter >= COUNTER_REHANDSHAKE_THRESHOLD {
            self.needs_rehandshake = true;
        }

        Ok(envelope_bytes)
    }

    /// Decifra um envelope recebido contra uma sessão estabelecida.
    ///
    /// `Ok(None)` cobre toda falha de decifragem — envelope malformado,
    /// `dh_pub` de ordem baixa, contador repetido, tag do AEAD inválida,
    /// plaintext decodificado que não bate com o bucket. Nenhuma dessas
    /// causas é diferenciada por fora: distinguir abriria exatamente o tipo
    /// de oráculo que `crypto::aead` já evita para a falha do próprio AEAD
    /// (ver `crypto/aead.rs`), e aqui a mesma regra vale para qualquer falha
    /// anterior a ele. Só o uso indevido da API — chamar isto antes da
    /// sessão estar `Established`, ou depois dela ter falhado — devolve
    /// `Err`.
    pub fn decrypt_incoming(
        &mut self,
        bytes: &[u8],
        transport: Transport,
    ) -> Result<Option<InnerPlaintext>> {
        let ratchet = match &mut self.state {
            SessionState::Established(ratchet) => ratchet,
            SessionState::Failed => {
                return Err(Error::InvalidState(
                    "sessão falhou; abra uma sessão nova com Session::open",
                ))
            }
            _ => return Err(Error::InvalidState("sessão ainda não estabelecida")),
        };

        match try_decrypt(ratchet, bytes, transport) {
            Ok(inner) => {
                self.consecutive_aead_failures = 0;
                self.peer_confirmed = true;
                if inner.packet_type == PacketType::ControlSuites {
                    self.handle_control_suites(&inner.body);
                }
                Ok(Some(inner))
            }
            Err(_) => {
                self.consecutive_aead_failures = self.consecutive_aead_failures.saturating_add(1);
                if self.consecutive_aead_failures >= MAX_CONSECUTIVE_AEAD_FAILURES {
                    self.state = SessionState::Failed;
                }
                Ok(None)
            }
        }
    }

    /// Monta o payload do pacote `CONTROL_SUITES` (§6.2, `0x42`).
    pub fn control_suites_payload() -> Vec<u8> {
        let supported = Suite::supported();
        let mut payload = Vec::with_capacity(1 + supported.len());
        payload.push(supported.len() as u8);
        for s in supported {
            payload.push(s.id());
        }
        payload
    }

    /// Cifra o pacote `CONTROL_SUITES` para envio imediato após estabelecer sessão.
    pub fn build_control_suites(&mut self, transport: Transport) -> Result<Vec<u8>> {
        let payload = Self::control_suites_payload();
        self.encrypt_outgoing(PacketType::ControlSuites, payload, transport)
    }

    fn handle_control_suites(&mut self, body: &[u8]) {
        if body.is_empty() {
            return;
        }
        let count = body[0] as usize;
        if body.len() < 1 + count {
            return;
        }
        let peer_suites = &body[1..=count];
        let local_supported = Suite::supported();
        let mut max_common: Option<u8> = None;
        for s in local_supported {
            let id = s.id();
            if peer_suites.contains(&id) {
                max_common = Some(match max_common {
                    Some(curr) => curr.max(id),
                    None => id,
                });
            }
        }
        if let Some(target) = max_common {
            if target > self.min_suite {
                self.agreed_upgrade_suite = Some(target);
            }
        }
    }
}

/// Mecânica de uma tentativa de decifragem, separada de `decrypt_incoming`
/// para manter a política de sessão (contagem de falhas, transição para
/// `Failed`) longe de onde o `dh_pub`/`pn`/`kem_ek`/`kem_ct` são resolvidos —
/// ver a documentação de módulo para o porquê das duas chamadas a
/// `receiving_key`.
fn try_decrypt(
    ratchet: &mut RatchetState,
    bytes: &[u8],
    transport: Transport,
) -> Result<InnerPlaintext> {
    let (counter, dh_pub, sealed) = envelope::decode(bytes)?;

    let provisional = RatchetHeader {
        dh_pub,
        pn: 0,
        counter,
        kem_ek: None,
        kem_ct: None,
    };
    let message_key = match ratchet.receiving_key(&provisional) {
        Ok(key) => key,
        Err(err) => {
            ratchet.discard_receive();
            return Err(err);
        }
    };

    let mut buffer = sealed.to_vec();
    let aad = envelope::aad(counter, &dh_pub);
    if aead::open(&message_key, counter, &aad, &mut buffer).is_err() {
        ratchet.discard_receive();
        return Err(Error::AeadFailure);
    }

    let inner = match InnerPlaintext::decode(&buffer, transport) {
        Ok(inner) => inner,
        Err(err) => {
            ratchet.discard_receive();
            return Err(err);
        }
    };

    let real_header = RatchetHeader {
        dh_pub,
        pn: inner.pn,
        counter,
        kem_ek: inner.kem_ek.clone(),
        kem_ct: inner.kem_ct.clone(),
    };
    // Idempotente e sem custo de segurança: repete a mesma derivação com os
    // valores reais, agora conhecidos, de pn/kem_ek/kem_ct — eles só afetam a
    // reconciliação de RK e do cache de puladas (aplicada só depois de
    // `commit_receive`), nunca a chave desta mensagem, que já foi confirmada
    // pelo AEAD acima. Ver a documentação de módulo.
    match ratchet.receiving_key(&real_header) {
        Ok(confirmed) => debug_assert_eq!(
            confirmed.as_bytes(),
            message_key.as_bytes(),
            "pn/kem_ek/kem_ct nunca deveriam mudar a chave de uma mensagem já autenticada"
        ),
        Err(err) => {
            ratchet.discard_receive();
            return Err(err);
        }
    }

    ratchet.commit_receive();
    Ok(inner)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::packet_type::PacketType;

    /// Gera duas identidades e devolve sempre na ordem (futura iniciadora,
    /// futura respondedora) — `LocalIdentity::generate` é aleatória, então
    /// sem isso os testes ficariam reféns de qual das duas o CSPRNG produziu
    /// primeiro (metade das execuções teria a primeira como respondedora).
    fn pair() -> (LocalIdentity, LocalIdentity) {
        let a = LocalIdentity::generate().unwrap();
        let b = LocalIdentity::generate().unwrap();
        if a.public().is_before(&b.public()) {
            (a, b)
        } else {
            (b, a)
        }
    }

    /// Estabelece uma sessão completa entre duas identidades reais, trocando
    /// os bytes de handshake por conta própria (sem rede) — o mesmo caminho
    /// que o transporte de verdade vai seguir, só que em processo.
    fn established_pair() -> (LocalIdentity, Session, LocalIdentity, Session) {
        let (alice, bob) = pair();

        let (mut alice_session, init) = Session::open(&alice, bob.public(), 1).unwrap();
        let (mut bob_session, none) = Session::open(&bob, alice.public(), 1).unwrap();
        assert!(none.is_none(), "bob é sempre respondedor — pair() garante essa ordem");

        let init = init.expect("alice é sempre iniciadora — pair() garante essa ordem");
        let resp = bob_session
            .process_handshake_message(&bob, &init)
            .unwrap()
            .expect("respondedor sempre devolve a RESP");
        let none_again = alice_session
            .process_handshake_message(&alice, &resp)
            .unwrap();
        assert!(none_again.is_none(), "iniciador não devolve nada ao concluir");

        assert!(alice_session.is_established());
        assert!(bob_session.is_established());

        (alice, alice_session, bob, bob_session)
    }

    #[test]
    fn pending_outgoing_handshake_is_stable_until_resp_arrives_and_disappears_after() {
        let (alice, bob) = pair();
        let (mut alice_session, init) = Session::open(&alice, bob.public(), 1).unwrap();
        let init = init.unwrap();

        // Chamar de novo antes da RESP chegar sempre devolve os mesmos
        // bytes — é exatamente essa estabilidade que permite mais de um
        // consumidor (o transporte WebRTC decidindo quem oferta; o
        // controlador de chat publicando a mensagem de fato) perguntar em
        // momentos diferentes sem coordenar entre si.
        assert_eq!(alice_session.pending_outgoing_handshake(), Some(init.as_slice()));
        assert_eq!(alice_session.pending_outgoing_handshake(), Some(init.as_slice()));

        let (mut bob_session, none) = Session::open(&bob, alice.public(), 1).unwrap();
        assert!(none.is_none());
        assert_eq!(bob_session.pending_outgoing_handshake(), None);

        let resp = bob_session
            .process_handshake_message(&bob, &init)
            .unwrap()
            .unwrap();
        alice_session
            .process_handshake_message(&alice, &resp)
            .unwrap();

        assert!(alice_session.is_established());
        assert_eq!(alice_session.pending_outgoing_handshake(), None);
    }

    #[test]
    fn two_peers_complete_handshake_and_exchange_thousand_alternating_messages() {
        let (_alice, mut alice_session, _bob, mut bob_session) = established_pair();

        for i in 0..1000 {
            let body = format!("mensagem {i}").into_bytes();
            if i % 2 == 0 {
                let envelope = alice_session
                    .encrypt_outgoing(PacketType::MsgText, body.clone(), Transport::DataChannel)
                    .unwrap();
                let inner = bob_session
                    .decrypt_incoming(&envelope, Transport::DataChannel)
                    .unwrap()
                    .expect("mensagem legítima nunca deveria ser descartada");
                assert_eq!(inner.body, body);
                assert_eq!(inner.packet_type, PacketType::MsgText);
            } else {
                let envelope = bob_session
                    .encrypt_outgoing(PacketType::MsgText, body.clone(), Transport::DataChannel)
                    .unwrap();
                let inner = alice_session
                    .decrypt_incoming(&envelope, Transport::DataChannel)
                    .unwrap()
                    .expect("mensagem legítima nunca deveria ser descartada");
                assert_eq!(inner.body, body);
            }
        }
    }

    #[test]
    fn concurrently_opened_sessions_converge_to_single_root() {
        // "Ao mesmo tempo" aqui significa: os dois lados chamam `Session::open`
        // antes de qualquer um ver o byte do outro — não há negociação
        // nenhuma, `is_before` já decide os dois papéis de forma determinística
        // e concordante. O teste em si é `established_pair`; a garantia real é
        // que uma mensagem de cada lado decifra do outro depois disso.
        let (_alice, mut alice_session, _bob, mut bob_session) = established_pair();

        let from_alice = alice_session
            .encrypt_outgoing(PacketType::MsgText, b"oi de alice".to_vec(), Transport::DataChannel)
            .unwrap();
        let received = bob_session
            .decrypt_incoming(&from_alice, Transport::DataChannel)
            .unwrap()
            .unwrap();
        assert_eq!(received.body, b"oi de alice");
    }

    #[test]
    fn unexpected_message_type_as_responder_does_not_corrupt_state() {
        let (alice, bob) = pair();
        let (_alice_session, init) = Session::open(&alice, bob.public(), 1).unwrap();
        let init = init.unwrap();

        let (mut bob_session, _) = Session::open(&bob, alice.public(), 1).unwrap();

        // Uma mensagem de tipo errado (aqui, lixo do tamanho de uma RESP, que
        // `respond` rejeita por comprimento/tipo) não deveria mudar o estado:
        // Bob continua esperando a INIT de verdade.
        let lixo = vec![0u8; 1122];
        assert!(bob_session.process_handshake_message(&bob, &lixo).is_err());
        assert!(!bob_session.is_established());
        assert!(!bob_session.is_failed(), "erro em AwaitingPeerInit não deveria levar a Failed");

        // A INIT de verdade, chegando depois, ainda funciona normalmente.
        let resp = bob_session
            .process_handshake_message(&bob, &init)
            .unwrap();
        assert!(resp.is_some());
        assert!(bob_session.is_established());
    }

    #[test]
    fn invalid_resp_moves_session_to_failed_without_panic() {
        // Uma RESP com um bit trocado no material de chave não é o teste
        // certo aqui: por desenho (D1, §4.4), adulterar `EK_R` não produz erro
        // explícito nenhum — as duas raízes só divergem em silêncio, e é
        // exatamente isso que faz o handshake deniável (confirmado pelos
        // testes de `crypto::handshake`, `adulterar_um_byte_da_resp_diverge_a_raiz_ou_falha`).
        // O caso que realmente produz `Err` de `Initiator::finish` é um
        // comprimento ou `msg_type` errado — o que este teste usa.
        let (alice, bob) = pair();
        let (mut alice_session, init) = Session::open(&alice, bob.public(), 1).unwrap();
        let init = init.unwrap();

        let (mut bob_session, _) = Session::open(&bob, alice.public(), 1).unwrap();
        let resp = bob_session
            .process_handshake_message(&bob, &init)
            .unwrap()
            .unwrap();

        let resp_truncada = &resp[..resp.len() - 1];
        assert!(alice_session
            .process_handshake_message(&alice, resp_truncada)
            .is_err());
        assert!(!alice_session.is_established());
        assert!(alice_session.is_failed());

        // `finish` consome o `Initiator` mesmo em erro — a sessão vai para
        // `Failed` e nem a RESP correta, chegando depois, ressuscita esta
        // tentativa.
        assert!(alice_session
            .process_handshake_message(&alice, &resp)
            .is_err());
    }

    #[test]
    fn isolated_aead_failure_does_not_block_subsequent_messages() {
        let (_alice, mut alice_session, _bob, mut bob_session) = established_pair();

        let mut tampered = alice_session
            .encrypt_outgoing(PacketType::MsgText, b"primeira".to_vec(), Transport::DataChannel)
            .unwrap();
        let last = tampered.len() - 1;
        tampered[last] ^= 0xff;

        assert_eq!(
            bob_session
                .decrypt_incoming(&tampered, Transport::DataChannel)
                .unwrap(),
            None
        );

        let seguinte = alice_session
            .encrypt_outgoing(PacketType::MsgText, b"segunda".to_vec(), Transport::DataChannel)
            .unwrap();
        let inner = bob_session
            .decrypt_incoming(&seguinte, Transport::DataChannel)
            .unwrap()
            .expect("uma falha isolada não deveria impedir a próxima mensagem");
        assert_eq!(inner.body, b"segunda");
    }

    #[test]
    fn consecutive_aead_failures_above_threshold_move_to_failed() {
        let (_alice, mut alice_session, _bob, mut bob_session) = established_pair();

        for _ in 0..MAX_CONSECUTIVE_AEAD_FAILURES {
            let mut tampered = alice_session
                .encrypt_outgoing(PacketType::MsgText, b"x".to_vec(), Transport::DataChannel)
                .unwrap();
            let last = tampered.len() - 1;
            tampered[last] ^= 0xff;
            assert_eq!(
                bob_session
                    .decrypt_incoming(&tampered, Transport::DataChannel)
                    .unwrap(),
                None
            );
        }

        // Depois do limiar, a sessão se recusa a continuar tentando.
        let legitima = alice_session
            .encrypt_outgoing(PacketType::MsgText, b"tarde demais".to_vec(), Transport::DataChannel)
            .unwrap();
        assert!(bob_session
            .decrypt_incoming(&legitima, Transport::DataChannel)
            .is_err());
    }

    #[test]
    fn counter_near_threshold_signals_needs_rehandshake_without_breaking_current_message() {
        let (_alice, mut alice_session, _bob, mut bob_session) = established_pair();

        // O limiar de teste (`COUNTER_REHANDSHAKE_THRESHOLD`) fica bem antes
        // do gatilho de re-KEM (256 msgs por padrão, mas aqui é maior só para
        // não colidir com outros testes deste módulo) — mesmo assim nenhuma
        // mensagem aqui carrega KEM_ek/KEM_ct, o que manteria o teste simples
        // de qualquer forma.
        for i in 0..=COUNTER_REHANDSHAKE_THRESHOLD {
            assert!(!alice_session.needs_rehandshake(), "não deveria sinalizar antes do limiar (i={i})");
            let envelope = alice_session
                .encrypt_outgoing(PacketType::MsgText, b"x".to_vec(), Transport::DataChannel)
                .unwrap();
            let inner = bob_session
                .decrypt_incoming(&envelope, Transport::DataChannel)
                .unwrap();
            assert!(inner.is_some(), "a mensagem que cruza o limiar ainda deveria sair e decifrar normalmente");
        }

        assert!(alice_session.needs_rehandshake());
        assert!(matches!(
            alice_session.encrypt_outgoing(PacketType::MsgText, b"y".to_vec(), Transport::DataChannel),
            Err(Error::NeedsRehandshake)
        ));
    }

    #[test]
    fn decrypt_incoming_on_unestablished_session_fails_without_panic() {
        let (alice, bob) = pair();
        let (mut alice_session, _init) = Session::open(&alice, bob.public(), 1).unwrap();

        assert!(matches!(
            alice_session.decrypt_incoming(&[0u8; 200], Transport::DataChannel),
            Err(Error::InvalidState(_))
        ));
    }

    /// Reexecuta a conversa alternada com uma perda ocasional (mensagem
    /// descartada em vez de entregue) para garantir que o encadeamento
    /// ratchet → wire → aead da sessão nunca panica nem diverge quando o
    /// transporte real perder pacotes — o mesmo espírito dos property tests
    /// de `wire::plaintext`, adaptado ao nível de sessão.
    #[test]
    fn long_conversation_with_occasional_losses_never_panics_and_decrypts_arriving_messages() {
        let (_alice, mut alice_session, _bob, mut bob_session) = established_pair();

        for i in 0..300u32 {
            let body = format!("msg {i}").into_bytes();
            let envelope = alice_session
                .encrypt_outgoing(PacketType::MsgText, body.clone(), Transport::DataChannel)
                .unwrap();

            // Descarta uma em cada sete mensagens antes de entregar — Bob
            // nunca deveria panicar, só deixar de decifrar aquela específica.
            if i % 7 == 0 {
                continue;
            }

            let inner = bob_session
                .decrypt_incoming(&envelope, Transport::DataChannel)
                .unwrap()
                .expect("mensagem entregue e não adulterada deveria sempre decifrar");
            assert_eq!(inner.body, body);
        }
    }

    #[test]
    fn twenty_unknown_packets_followed_by_msg_text_does_not_fail_session() {
        let (_alice, mut alice_session, _bob, mut bob_session) = established_pair();

        for i in 0..20 {
            let body = format!("unknown-payload-{i}").into_bytes();
            let envelope = alice_session
                .encrypt_outgoing(PacketType::Unknown(0x7F), body, Transport::DataChannel)
                .unwrap();
            let inner = bob_session
                .decrypt_incoming(&envelope, Transport::DataChannel)
                .unwrap()
                .expect("pacote Unknown com tag válida não deve ser descartado como erro");
            assert_eq!(inner.packet_type, PacketType::Unknown(0x7F));
        }

        assert!(bob_session.is_established());

        let legitima = alice_session
            .encrypt_outgoing(
                PacketType::MsgText,
                b"mensagem legitima".to_vec(),
                Transport::DataChannel,
            )
            .unwrap();
        let inner = bob_session
            .decrypt_incoming(&legitima, Transport::DataChannel)
            .unwrap()
            .expect("MsgText subsequente deve decifrar normalmente");
        assert_eq!(inner.packet_type, PacketType::MsgText);
        assert_eq!(inner.body, b"mensagem legitima");
        assert!(bob_session.is_established());
    }

    #[test]
    fn unknown_packet_with_kem_ct_applies_kem_step_and_subsequent_message_decrypts() {
        let (_alice, mut alice_session, _bob, mut bob_session) = established_pair();

        // Estabelece a cadeia inicial
        let env0 = alice_session
            .encrypt_outgoing(PacketType::MsgText, b"inicio".to_vec(), Transport::DataChannel)
            .unwrap();
        bob_session
            .decrypt_incoming(&env0, Transport::DataChannel)
            .unwrap()
            .unwrap();

        let mut saw_kem_ct = false;

        // Avança até o gatilho de re-KEM (256 mensagens). Bob responde sempre com Unknown(0x7F).
        for i in 0..300 {
            let env_a = alice_session
                .encrypt_outgoing(
                    PacketType::MsgText,
                    format!("msg-alice-{i}").into_bytes(),
                    Transport::DataChannel,
                )
                .unwrap();
            bob_session
                .decrypt_incoming(&env_a, Transport::DataChannel)
                .unwrap()
                .unwrap();

            let env_b = bob_session
                .encrypt_outgoing(
                    PacketType::Unknown(0x7F),
                    format!("msg-bob-{i}").into_bytes(),
                    Transport::DataChannel,
                )
                .unwrap();
            let inner_b = alice_session
                .decrypt_incoming(&env_b, Transport::DataChannel)
                .unwrap()
                .unwrap();

            if inner_b.kem_ct.is_some() {
                saw_kem_ct = true;
                assert_eq!(inner_b.packet_type, PacketType::Unknown(0x7F));
                // Alice recebeu o KEM_ct em um pacote Unknown e aplicou o passo KEM.
                // Agora envia uma MsgText na cadeia nova derivada da nova root key.
                let next_env = alice_session
                    .encrypt_outgoing(
                        PacketType::MsgText,
                        b"pos-re-kem".to_vec(),
                        Transport::DataChannel,
                    )
                    .unwrap();
                let next_inner = bob_session
                    .decrypt_incoming(&next_env, Transport::DataChannel)
                    .unwrap()
                    .expect("mensagem na cadeia nova deve decifrar com sucesso");
                assert_eq!(next_inner.body, b"pos-re-kem");
                break;
            }
        }

        assert!(saw_kem_ct, "Bob deveria ter enviado um pacote com KEM_ct");
    }

    #[test]
    fn tampered_unknown_packet_counts_as_aead_failure() {
        let (_alice, mut alice_session, _bob, mut bob_session) = established_pair();

        for _ in 0..MAX_CONSECUTIVE_AEAD_FAILURES {
            let mut tampered = alice_session
                .encrypt_outgoing(
                    PacketType::Unknown(0x7F),
                    b"payload".to_vec(),
                    Transport::DataChannel,
                )
                .unwrap();
            let last = tampered.len() - 1;
            tampered[last] ^= 0xff;
            assert_eq!(
                bob_session
                    .decrypt_incoming(&tampered, Transport::DataChannel)
                    .unwrap(),
                None
            );
        }

        // Após o limiar de falhas de AEAD, a sessão entra em Failed
        let legitima = alice_session
            .encrypt_outgoing(
                PacketType::MsgText,
                b"tarde demais".to_vec(),
                Transport::DataChannel,
            )
            .unwrap();
        assert!(bob_session
            .decrypt_incoming(&legitima, Transport::DataChannel)
            .is_err());
    }

    #[test]
    fn responder_with_contact_in_suite_2_rejects_init_in_suite_1_without_state_change() {
        use crate::crypto::suite::set_test_suite_v2_enabled;
        set_test_suite_v2_enabled(true);

        let (alice, bob) = pair();
        // Alice inicia em suite 1 (com contato gravado em suite 1)
        let (_alice_session, init_v1) = Session::open(&alice, bob.public(), 1).unwrap();
        let init_v1 = init_v1.unwrap();

        // Bob tem o contato gravado na suíte 2
        let (mut bob_session, _) = Session::open(&bob, alice.public(), 2).unwrap();

        // Bob recebe INIT na suíte 1: deve recusar com UnsupportedVersion(1)
        let res = bob_session.process_handshake_message(&bob, &init_v1);
        assert!(matches!(res, Err(Error::UnsupportedVersion(1))));

        // O estado não deve ser corrompido nem ir para Failed
        assert!(!bob_session.is_established());
        assert!(!bob_session.is_failed());

        // Se Bob receber agora uma INIT na suíte 2, deve aceitar normalmente
        let (_alice_session_v2, init_v2) = Session::open(&alice, bob.public(), 2).unwrap();
        let init_v2 = init_v2.unwrap();
        let resp = bob_session
            .process_handshake_message(&bob, &init_v2)
            .unwrap();
        assert!(resp.is_some());
        assert!(bob_session.is_established());

        set_test_suite_v2_enabled(false);
    }

    #[test]
    fn responder_with_contact_in_suite_1_accepts_init_in_suite_2_when_supported() {
        use crate::crypto::suite::set_test_suite_v2_enabled;
        set_test_suite_v2_enabled(true);

        let (alice, bob) = pair();
        // Alice inicia na suíte 2 (já atualizou)
        let (mut alice_session, init_v2) = Session::open(&alice, bob.public(), 2).unwrap();
        let init_v2 = init_v2.unwrap();

        // Bob tem o contato gravado ainda na suíte 1
        let (mut bob_session, _) = Session::open(&bob, alice.public(), 1).unwrap();

        // Bob aceita INIT na suíte 2 porque 2 >= 1 e build suporta {1, 2}
        let resp = bob_session
            .process_handshake_message(&bob, &init_v2)
            .unwrap()
            .expect("respondedor gera RESP");
        assert!(bob_session.is_established());

        // Alice conclui o handshake na suíte 2
        alice_session
            .process_handshake_message(&alice, &resp)
            .unwrap();
        assert!(alice_session.is_established());

        set_test_suite_v2_enabled(false);
    }

    #[test]
    fn upgrade_to_highest_common_suite_preserves_history_and_records_2() {
        use crate::crypto::kdf;
        use crate::crypto::suite::set_test_suite_v2_enabled;
        use crate::store::Store;

        let (alice, bob) = pair();

        // Bancos locais persistentes para Alice e Bob
        let dir_a = tempfile::tempdir().unwrap();
        let store_a = Store::open(&dir_a.path().join("a.db"), &kdf::Key::from_bytes([1u8; 32])).unwrap();
        store_a.insert_contact(&bob.public(), 1, Some("Bob")).unwrap();
        let msg_a1 = store_a
            .insert_pending_message(&bob.public().device_id, PacketType::MsgText, "antiga de alice", 10)
            .unwrap();

        let dir_b = tempfile::tempdir().unwrap();
        let store_b = Store::open(&dir_b.path().join("b.db"), &kdf::Key::from_bytes([2u8; 32])).unwrap();
        store_b.insert_contact(&alice.public(), 1, Some("Alice")).unwrap();
        let msg_b1 = store_b
            .insert_incoming_message(&alice.public().device_id, PacketType::MsgText, "antiga de alice para b", 10)
            .unwrap();

        // 1. Primeira conexão: Alice suporta {1, 2}, Bob só {1}
        set_test_suite_v2_enabled(false); // Bob só conhece {1}
        let (mut alice_s1, init1) = Session::open(&alice, bob.public(), 1).unwrap();
        let (mut bob_s1, _) = Session::open(&bob, alice.public(), 1).unwrap();
        let resp1 = bob_s1.process_handshake_message(&bob, &init1.unwrap()).unwrap().unwrap();
        alice_s1.process_handshake_message(&alice, &resp1).unwrap();

        // Alice envia anúncio com {1, 2} manualmente construído para simular Alice atualizada
        let control_payload_a = vec![2, 1, 2]; // 2 suítes: 1 e 2
        let env_a = alice_s1.encrypt_outgoing(PacketType::ControlSuites, control_payload_a, Transport::DataChannel).unwrap();
        bob_s1.decrypt_incoming(&env_a, Transport::DataChannel).unwrap().unwrap();
        // Bob só suporta {1}, então não acorda upgrade para 2
        assert_eq!(bob_s1.agreed_upgrade_suite(), None);

        // Bob envia anúncio com {1}
        let control_payload_b = vec![1, 1];
        let env_b = bob_s1.encrypt_outgoing(PacketType::ControlSuites, control_payload_b, Transport::DataChannel).unwrap();
        alice_s1.decrypt_incoming(&env_b, Transport::DataChannel).unwrap().unwrap();
        // Alice tem interseção {1}, que não é > min_suite 1
        assert_eq!(alice_s1.agreed_upgrade_suite(), None);
        assert_eq!(store_a.get_contact_suite_id(&bob.public().device_id).unwrap(), 1);
        assert_eq!(store_b.get_contact_suite_id(&alice.public().device_id).unwrap(), 1);

        // 2. Bob atualiza o app para {1, 2} com o mesmo banco
        set_test_suite_v2_enabled(true);

        // Conexão seguinte: ambos ainda com suíte gravada 1
        let (mut alice_s2, init2) = Session::open(&alice, bob.public(), 1).unwrap();
        let (mut bob_s2, _) = Session::open(&bob, alice.public(), 1).unwrap();
        let resp2 = bob_s2.process_handshake_message(&bob, &init2.unwrap()).unwrap().unwrap();
        alice_s2.process_handshake_message(&alice, &resp2).unwrap();

        // Ambos trocam anúncios agora que os dois têm {1, 2}
        let env_a2 = alice_s2.build_control_suites(Transport::DataChannel).unwrap();
        bob_s2.decrypt_incoming(&env_a2, Transport::DataChannel).unwrap().unwrap();
        assert_eq!(bob_s2.agreed_upgrade_suite(), Some(2));

        let env_b2 = bob_s2.build_control_suites(Transport::DataChannel).unwrap();
        alice_s2.decrypt_incoming(&env_b2, Transport::DataChannel).unwrap().unwrap();
        assert_eq!(alice_s2.agreed_upgrade_suite(), Some(2));

        // Ninguém grava 2 no banco ainda
        assert_eq!(store_a.get_contact_suite_id(&bob.public().device_id).unwrap(), 1);
        assert_eq!(store_b.get_contact_suite_id(&alice.public().device_id).unwrap(), 1);

        // 3. Na conexão seguinte, o handshake é na suíte 2
        let (mut alice_s3, init3) = Session::open_with_upgrade(
            &alice,
            bob.public(),
            store_a.get_contact_suite_id(&bob.public().device_id).unwrap(),
            alice_s2.agreed_upgrade_suite(),
        ).unwrap();
        let init3 = init3.unwrap();
        assert_eq!(init3[0], 2, "handshake deve iniciar na suíte 2");

        let (mut bob_s3, _) = Session::open_with_upgrade(
            &bob,
            alice.public(),
            store_b.get_contact_suite_id(&alice.public().device_id).unwrap(),
            bob_s2.agreed_upgrade_suite(),
        ).unwrap();

        let resp3 = bob_s3.process_handshake_message(&bob, &init3).unwrap().unwrap();
        assert_eq!(resp3[0], 2, "resposta deve ser na suíte 2");

        alice_s3.process_handshake_message(&alice, &resp3).unwrap();
        assert!(alice_s3.is_established());
        assert!(alice_s3.should_upgrade_contact(1));
        store_a.set_contact_suite_id(&bob.public().device_id, alice_s3.current_suite()).unwrap();

        // Bob recebe a primeira mensagem autenticada da sessão na suíte 2
        let env_a3 = alice_s3.build_control_suites(Transport::DataChannel).unwrap();
        bob_s3.decrypt_incoming(&env_a3, Transport::DataChannel).unwrap().unwrap();
        assert!(bob_s3.should_upgrade_contact(1));
        store_b.set_contact_suite_id(&alice.public().device_id, bob_s3.current_suite()).unwrap();

        // Ambos agora gravaram 2
        assert_eq!(store_a.get_contact_suite_id(&bob.public().device_id).unwrap(), 2);
        assert_eq!(store_b.get_contact_suite_id(&alice.public().device_id).unwrap(), 2);

        // Histórico de mensagens intacto nos dois bancos
        assert!(store_a.list_pending_messages(&bob.public().device_id).unwrap().iter().any(|m| m.id == msg_a1));
        let msgs_b = store_b.list_messages(&alice.public().device_id).unwrap();
        assert!(msgs_b.iter().any(|m| m.id == msg_b1));

        set_test_suite_v2_enabled(false);
    }

    #[test]
    fn announcement_dropped_in_one_direction_nobody_records_2_and_next_session_opens_on_1() {
        use crate::crypto::kdf;
        use crate::crypto::suite::set_test_suite_v2_enabled;
        use crate::store::Store;

        set_test_suite_v2_enabled(true);
        let (alice, bob) = pair();

        let dir_a = tempfile::tempdir().unwrap();
        let store_a = Store::open(&dir_a.path().join("a.db"), &kdf::Key::from_bytes([1u8; 32])).unwrap();
        store_a.insert_contact(&bob.public(), 1, None).unwrap();

        let dir_b = tempfile::tempdir().unwrap();
        let store_b = Store::open(&dir_b.path().join("b.db"), &kdf::Key::from_bytes([2u8; 32])).unwrap();
        store_b.insert_contact(&alice.public(), 1, None).unwrap();

        let (mut alice_s1, init1) = Session::open(&alice, bob.public(), 1).unwrap();
        let (mut bob_s1, _) = Session::open(&bob, alice.public(), 1).unwrap();
        let resp1 = bob_s1.process_handshake_message(&bob, &init1.unwrap()).unwrap().unwrap();
        alice_s1.process_handshake_message(&alice, &resp1).unwrap();

        // Alice envia anúncio para Bob, mas o anúncio de Bob para Alice é descartado na rede
        let env_a = alice_s1.build_control_suites(Transport::DataChannel).unwrap();
        bob_s1.decrypt_incoming(&env_a, Transport::DataChannel).unwrap().unwrap();
        // Alice nunca recebeu anúncio de Bob:
        assert_eq!(alice_s1.agreed_upgrade_suite(), None);

        // Nenhum dos dois grava 2 no banco
        assert_eq!(store_a.get_contact_suite_id(&bob.public().device_id).unwrap(), 1);
        assert_eq!(store_b.get_contact_suite_id(&alice.public().device_id).unwrap(), 1);

        // Próxima sessão: Alice (iniciadora) abre com upgrade_suite = None (porque não recebeu anúncio)
        let (mut alice_s2, init2) = Session::open_with_upgrade(
            &alice,
            bob.public(),
            store_a.get_contact_suite_id(&bob.public().device_id).unwrap(),
            alice_s1.agreed_upgrade_suite(),
        ).unwrap();
        let init2 = init2.unwrap();
        assert_eq!(init2[0], 1, "iniciadora deve abrir na suíte 1");

        let (mut bob_s2, _) = Session::open_with_upgrade(
            &bob,
            alice.public(),
            store_b.get_contact_suite_id(&alice.public().device_id).unwrap(),
            bob_s1.agreed_upgrade_suite(),
        ).unwrap();

        let resp2 = bob_s2.process_handshake_message(&bob, &init2).unwrap().unwrap();
        assert_eq!(resp2[0], 1, "respondedor deve aceitar e responder na 1");
        alice_s2.process_handshake_message(&alice, &resp2).unwrap();
        assert!(alice_s2.is_established());
        assert_eq!(alice_s2.current_suite(), 1);
        assert_eq!(bob_s2.current_suite(), 1);

        set_test_suite_v2_enabled(false);
    }

    #[test]
    fn handshake_on_2_fails_in_middle_suite_id_remains_1_in_both_dbs() {
        use crate::crypto::kdf;
        use crate::crypto::suite::set_test_suite_v2_enabled;
        use crate::store::Store;

        set_test_suite_v2_enabled(true);
        let (alice, bob) = pair();

        let dir_a = tempfile::tempdir().unwrap();
        let store_a = Store::open(&dir_a.path().join("a.db"), &kdf::Key::from_bytes([1u8; 32])).unwrap();
        store_a.insert_contact(&bob.public(), 1, None).unwrap();

        let dir_b = tempfile::tempdir().unwrap();
        let store_b = Store::open(&dir_b.path().join("b.db"), &kdf::Key::from_bytes([2u8; 32])).unwrap();
        store_b.insert_contact(&alice.public(), 1, None).unwrap();

        // Ambos tentam upgrade para 2
        let (mut alice_s2, init2) = Session::open_with_upgrade(&alice, bob.public(), 1, Some(2)).unwrap();
        let init2 = init2.unwrap();
        assert_eq!(init2[0], 2);

        let (mut bob_s2, _) = Session::open_with_upgrade(&bob, alice.public(), 1, Some(2)).unwrap();
        let resp2 = bob_s2.process_handshake_message(&bob, &init2).unwrap().unwrap();
        assert_eq!(resp2[0], 2);

        // A resposta é corrompida / truncada na rede (falha no meio do handshake)
        let mut tampered_resp = resp2.clone();
        tampered_resp.truncate(100);
        assert!(alice_s2.process_handshake_message(&alice, &tampered_resp).is_err());
        assert!(!alice_s2.is_established());

        // Alice falhou: não eleva banco
        assert!(!alice_s2.should_upgrade_contact(1));
        // Bob não recebeu mensagem confirmada de Alice: não eleva banco
        assert!(!bob_s2.should_upgrade_contact(1));

        assert_eq!(store_a.get_contact_suite_id(&bob.public().device_id).unwrap(), 1);
        assert_eq!(store_b.get_contact_suite_id(&alice.public().device_id).unwrap(), 1);

        // A sessão seguinte abre na 1
        let (mut alice_s3, init3) = Session::open(&alice, bob.public(), 1).unwrap();
        let init3 = init3.unwrap();
        assert_eq!(init3[0], 1);

        let (mut bob_s3, _) = Session::open(&bob, alice.public(), 1).unwrap();
        let resp3 = bob_s3.process_handshake_message(&bob, &init3).unwrap().unwrap();
        assert_eq!(resp3[0], 1);
        alice_s3.process_handshake_message(&alice, &resp3).unwrap();
        assert!(alice_s3.is_established());

        set_test_suite_v2_enabled(false);
    }

    #[test]
    fn contact_in_suite_2_with_build_only_1_returns_unsupported_version_and_data_intact() {
        use crate::crypto::kdf;
        use crate::crypto::suite::set_test_suite_v2_enabled;
        use crate::store::Store;

        // Build atual só conhece {1}
        set_test_suite_v2_enabled(false);
        let (alice, bob) = pair();

        let dir_a = tempfile::tempdir().unwrap();
        let store_a = Store::open(&dir_a.path().join("a.db"), &kdf::Key::from_bytes([1u8; 32])).unwrap();
        store_a.insert_contact(&bob.public(), 1, Some("Bob")).unwrap();
        store_a.set_contact_suite_id(&bob.public().device_id, 2).unwrap();
        let msg_id = store_a
            .insert_pending_message(&bob.public().device_id, PacketType::MsgText, "msg salva", 1)
            .unwrap();

        // Tentar abrir sessão com contato em suíte 2 devolve UnsupportedVersion(2)
        let recorded_suite = store_a.get_contact_suite_id(&bob.public().device_id).unwrap();
        assert_eq!(recorded_suite, 2);
        let res = Session::open(&alice, bob.public(), recorded_suite);
        assert!(matches!(res, Err(Error::UnsupportedVersion(2))));

        // Contato e mensagens continuam intactos no banco
        let contact = store_a.find_contact(&bob.public().device_id).unwrap().unwrap();
        assert_eq!(contact.2.as_deref(), Some("Bob"));
        assert_eq!(store_a.get_contact_suite_id(&bob.public().device_id).unwrap(), 2);
        let pending = store_a.list_pending_messages(&bob.public().device_id).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].id, msg_id);
    }

    #[test]
    fn announcement_with_only_1_from_contact_recorded_in_2_does_not_downgrade() {
        use crate::crypto::suite::set_test_suite_v2_enabled;
        set_test_suite_v2_enabled(true);

        let (alice, bob) = pair();
        // Alice e Bob conversando na suíte 2 (contato gravado em 2)
        let (mut alice_session, init) = Session::open(&alice, bob.public(), 2).unwrap();
        let (mut bob_session, _) = Session::open(&bob, alice.public(), 2).unwrap();
        let resp = bob_session.process_handshake_message(&bob, &init.unwrap()).unwrap().unwrap();
        alice_session.process_handshake_message(&alice, &resp).unwrap();

        // Alice (iniciadora) envia a primeira mensagem para estabelecer a cadeia de envio de Bob
        let env_a = alice_session
            .encrypt_outgoing(PacketType::MsgText, b"inicio".to_vec(), Transport::DataChannel)
            .unwrap();
        bob_session.decrypt_incoming(&env_a, Transport::DataChannel).unwrap().unwrap();

        // Bob envia anúncio contendo apenas suíte {1}
        let env_b = bob_session.encrypt_outgoing(
            PacketType::ControlSuites,
            vec![1, 1],
            Transport::DataChannel,
        ).unwrap();

        alice_session.decrypt_incoming(&env_b, Transport::DataChannel).unwrap().unwrap();

        // Alice não rebaixa nada: agreed_upgrade_suite continua None e suíte atual continua 2
        assert_eq!(alice_session.agreed_upgrade_suite(), None);
        assert_eq!(alice_session.current_suite(), 2);

        set_test_suite_v2_enabled(false);
    }

    #[test]
    fn endpoint_with_only_suite_1_receives_control_suites_and_session_continues_on_1() {
        use crate::crypto::suite::set_test_suite_v2_enabled;

        // Alice só suporta {1}
        set_test_suite_v2_enabled(false);
        let (alice, bob) = pair();
        let (mut alice_session, init) = Session::open(&alice, bob.public(), 1).unwrap();

        // Bob suporta {1, 2}
        let (mut bob_session, _) = Session::open(&bob, alice.public(), 1).unwrap();
        let resp = bob_session.process_handshake_message(&bob, &init.unwrap()).unwrap().unwrap();
        alice_session.process_handshake_message(&alice, &resp).unwrap();

        // Alice (iniciadora) envia a primeira mensagem para estabelecer a cadeia de envio de Bob
        let env_a = alice_session
            .encrypt_outgoing(PacketType::MsgText, b"inicio".to_vec(), Transport::DataChannel)
            .unwrap();
        bob_session.decrypt_incoming(&env_a, Transport::DataChannel).unwrap().unwrap();

        // Bob envia CONTROL_SUITES com {1, 2}
        let payload = vec![2, 1, 2];
        let env = bob_session.encrypt_outgoing(
            PacketType::ControlSuites,
            payload,
            Transport::DataChannel,
        ).unwrap();

        // Alice decifra sem erro e descarta/não atualiza
        let inner = alice_session.decrypt_incoming(&env, Transport::DataChannel).unwrap().unwrap();
        assert_eq!(inner.packet_type, PacketType::ControlSuites);
        assert_eq!(alice_session.agreed_upgrade_suite(), None);
        assert_eq!(alice_session.current_suite(), 1);

        // Sessão continua normalmente na suíte 1
        let text_env = alice_session.encrypt_outgoing(
            PacketType::MsgText,
            b"sessao continua".to_vec(),
            Transport::DataChannel,
        ).unwrap();
        let received = bob_session.decrypt_incoming(&text_env, Transport::DataChannel).unwrap().unwrap();
        assert_eq!(received.body, b"sessao continua");
    }

    #[test]
    fn session_open_with_retired_suite_returns_suite_retired_error_and_no_init() {
        use crate::crypto::suite::set_suite_retired;

        let (alice, bob) = pair();
        // Marca suíte 1 como desativada
        set_suite_retired(1, true);

        // Alice tenta abrir sessão com Bob (gravado na suíte 1)
        let res = Session::open(&alice, bob.public(), 1);
        assert!(matches!(res, Err(Error::SuiteRetired(1))));

        // Restaura
        set_suite_retired(1, false);
    }
}

