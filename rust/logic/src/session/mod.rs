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
    /// Quando este lado é o iniciador, devolve os bytes da INIT prontos para
    /// enviar (`Some`); quando é o respondedor, devolve `None` — nada é
    /// enviado até a INIT do par chegar via [`Self::process_handshake_message`].
    /// A regra é 100% determinística nas duas pontas (mesma comparação
    /// lexicográfica de `IK_dh`), então não existe handshake "simultâneo" de
    /// verdade no sentido de ambos tentarem iniciar: no máximo um dos dois
    /// lados chama `Session::open` antes do outro, mas os dois concordam
    /// sobre quem é quem assim que os dois chamarem.
    pub fn open(local: &LocalIdentity, peer: PublicIdentity) -> Result<(Self, Option<Vec<u8>>)> {
        if local.public().is_before(&peer) {
            let (initiator, init_bytes) = Initiator::start(local, &peer)?;
            let init_bytes = init_bytes.to_vec();
            Ok((
                Self {
                    peer,
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
            SessionState::AwaitingPeerInit => match respond(local, &self.peer, bytes) {
                Ok((outcome, resp_bytes)) => {
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
            },
            SessionState::AwaitingResponse(initiator) => match initiator.finish(local, bytes) {
                Ok(outcome) => {
                    self.state =
                        SessionState::Established(Box::new(RatchetState::initialize(outcome)?));
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

        let (mut alice_session, init) = Session::open(&alice, bob.public()).unwrap();
        let (mut bob_session, none) = Session::open(&bob, alice.public()).unwrap();
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
        let (mut alice_session, init) = Session::open(&alice, bob.public()).unwrap();
        let init = init.unwrap();

        // Chamar de novo antes da RESP chegar sempre devolve os mesmos
        // bytes — é exatamente essa estabilidade que permite mais de um
        // consumidor (o transporte WebRTC decidindo quem oferta; o
        // controlador de chat publicando a mensagem de fato) perguntar em
        // momentos diferentes sem coordenar entre si.
        assert_eq!(alice_session.pending_outgoing_handshake(), Some(init.as_slice()));
        assert_eq!(alice_session.pending_outgoing_handshake(), Some(init.as_slice()));

        let (mut bob_session, none) = Session::open(&bob, alice.public()).unwrap();
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
        let (_alice_session, init) = Session::open(&alice, bob.public()).unwrap();
        let init = init.unwrap();

        let (mut bob_session, _) = Session::open(&bob, alice.public()).unwrap();

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
        let (mut alice_session, init) = Session::open(&alice, bob.public()).unwrap();
        let init = init.unwrap();

        let (mut bob_session, _) = Session::open(&bob, alice.public()).unwrap();
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
        let (mut alice_session, _init) = Session::open(&alice, bob.public()).unwrap();

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
}
