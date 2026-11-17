//! Tipos de dados que atravessam a fronteira FFI.
//!
//! Tudo aqui é dado público: chaves que já saíram no QR Code e foram
//! verificadas por `crypto::pairing::decode_qr`, ou valores derivados delas
//! (dígitos e palavras do safety number). Nenhum campo carrega material
//! privado — `LocalIdentity` nunca aparece nesta lista.

use viska_proto::crypto::identity::PublicIdentity;

/// Um contato pareado, como a UI precisa exibi-lo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContactDto {
    pub device_id: Vec<u8>,
    pub signing_pubkey: Vec<u8>,
    pub dh_pubkey: Vec<u8>,
    pub paired_at_unix_secs: i64,
    pub nickname: Option<String>,
    pub is_verified: bool,
}

impl ContactDto {
    pub(crate) fn from_identity(
        identity: &PublicIdentity,
        paired_at_unix_secs: i64,
        nickname: Option<String>,
        is_verified: bool,
    ) -> Self {
        Self {
            device_id: identity.device_id.to_vec(),
            signing_pubkey: identity.signing.to_vec(),
            dh_pubkey: identity.dh.as_bytes().to_vec(),
            paired_at_unix_secs,
            nickname,
            is_verified,
        }
    }
}

/// O safety number entre a identidade local e um contato, nas duas
/// representações da spec §3.3.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SafetyNumberDto {
    /// 12 grupos de 5 dígitos, separados por espaço.
    pub digits: String,
    /// 6 palavras da lista BIP-39 PT-BR, separadas por espaço.
    pub words: String,
}

/// Estado de uma sessão, sem nenhum dos campos criptográficos de
/// `viska_proto::session::Session` — só o que a UI precisa para decidir o que
/// mostrar (indicador de conexão, botão de retry).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionStateKind {
    /// Handshake em andamento — nem INIT nem RESP concluídos ainda.
    Handshaking,
    /// Pronta para cifrar/decifrar mensagens.
    Established,
    /// Precisa de uma sessão nova: `Core::reset_session` (`ensure_session`
    /// devolve a sessão falha como está, nunca a reabre).
    Failed,
}

/// Status de uma sessão, devolvido por `Core::ensure_session`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionStatusDto {
    pub state: SessionStateKind,
    /// `true` quando o contador de envio já cruzou o limiar de segurança —
    /// a sessão ainda funciona para decifrar, mas `encrypt_outgoing` vai
    /// recusar mensagens novas.
    pub needs_rehandshake: bool,
    /// Bytes de handshake a publicar via sinalização — presente sempre que
    /// formos iniciador e ainda não tivermos recebido a RESP, `None` em
    /// qualquer outro caso (respondedor, sessão já estabelecida, ou
    /// falhada). Chamar `ensure_session` várias vezes nesse intervalo
    /// devolve os mesmos bytes todas as vezes, nunca uma INIT nova — mais
    /// de uma parte do app pode precisar deles em momentos diferentes (ver
    /// `Session::pending_outgoing_handshake`).
    pub outgoing_handshake: Option<Vec<u8>>,
}

/// Mudança de estado de uma sessão, empurrada pelo stream de
/// `Core::subscribe_session_events`. Só dado público: o mesmo que
/// `Core::session_status` já devolve.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionStateEventDto {
    pub peer_device_id: Vec<u8>,
    /// `None` quando a sessão deixou de existir (bloqueio do cofre,
    /// re-pareamento ou reset): a UI não deve tratá-la como estabelecida.
    pub state: Option<SessionStateKind>,
    pub needs_rehandshake: bool,
    /// Muda quando a sessão com o par é trocada por outra, inclusive quando o
    /// par reabriu e a nossa continuou `Established` (§11.4). Quem precisa
    /// refazer algo que dependia da sessão anterior compara este valor. É só
    /// um contador local, sem relação com nenhuma chave.
    pub generation: u32,
    /// Há uma sessão candidata segurando a fila de envio (§11.4). Quando ela
    /// passa do prazo (30 s, `viska_proto::session::CANDIDATE_TIMEOUT_SECS`)
    /// nada no Rust avisa, porque o Rust não tem relógio próprio: quem vê
    /// `true` drena a fila depois do prazo, e a drenagem publica o estado novo.
    pub renewing: bool,
}

/// Resultado de `Core::receive_incoming`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IncomingResultDto {
    /// A mensagem de aplicação decifrada, quando os bytes eram uma.
    pub message: Option<IncomingMessageDto>,
    /// Bytes a enviar de volta ao par, sem tocar: RESP, INIT, `REOPEN` ou um
    /// `CONTROL_SUITES` já cifrado. Material público de handshake ou
    /// ciphertext, nunca segredo.
    pub reply: Option<Vec<u8>>,
}

/// Evento de transferência, empurrado pelo stream de
/// `Core::subscribe_transfer_events`. Só avisa que algo mudou: nome, tamanho e
/// qualquer segredo da oferta ficam no Rust, o Dart os lê pelas consultas.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferEventDto {
    pub peer_device_id: Vec<u8>,
    pub file_id: Vec<u8>,
    pub kind: TransferEventKind,
}

/// O que aconteceu. Novos eventos de transferência entram aqui como variantes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferEventKind {
    /// Oferta retida aguardando confirmação (`unconfirmed_file_offers`).
    OfferAppeared,
    /// A oferta deixou de estar pendente: aceita, recusada, cancelada ou
    /// descartada no bloqueio do cofre.
    OfferGone,
    /// O estado de um envio mudou e vale pedir o próximo bloco: chegou um
    /// `FILE_FEEDBACK`, ou a transferência acabou (concluída, recusada,
    /// cancelada ou largada no bloqueio). Quem bombeia o envio acorda e
    /// reconsulta, em vez de dormir um tempo fixo.
    ChunkReleased,
}

/// Evento de mensagem, empurrado pelo stream de `Core::subscribe_message_events`.
/// Só identificadores: o conteúdo o Dart lê com `Core::get_message`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageEventDto {
    pub peer_device_id: Vec<u8>,
    pub message_id: i64,
    pub kind: MessageEventKind,
}

/// O que aconteceu com a mensagem.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageEventKind {
    /// Linha nova na timeline. Repetida para a mesma linha é inofensiva.
    Added,
    /// Estado de entrega ou ligação com o arquivo mudou.
    Updated,
    /// A chave efêmera foi destruída: a linha continua, mas sem o conteúdo.
    KeyExpired,
    /// As reações da mensagem mudaram.
    ReactionsChanged,
}

/// Uma mensagem de saída já persistida como `pending`, e cifrada se a sessão
/// já estava pronta na hora da chamada.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SealedMessageDto {
    /// `id` na tabela `messages` — usado depois em `Core::mark_message_sent`.
    pub message_id: i64,
    /// `None` quando a sessão ainda não está `Established`: a mensagem já
    /// está persistida como `pending`, mas não há nada para enviar ainda —
    /// o outbox (Fase 3, F6) tenta de novo via `Core::flush_pending` assim
    /// que a sessão ficar pronta.
    pub bytes: Option<Vec<u8>>,
}

/// Uma mensagem recebida e decifrada, pronta para a UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IncomingMessageDto {
    /// `None` só para `MSG_TYPING` — indicador efêmero, nunca persistido
    /// (`docs/protocol.md` §6.2).
    pub message_id: Option<i64>,
    pub body: String,
    pub is_typing: bool,
    pub received_at_unix_secs: i64,
}

/// Direção de uma mensagem persistida — espelha `store::messages::Direction`,
/// sem reexportar o tipo interno diretamente na fronteira FFI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageDirectionDto {
    Outgoing,
    Incoming,
}

/// Estado de entrega de uma mensagem de saída — espelha
/// `store::messages::DeliveryState`. `Delivered`/`Failed` ainda não são
/// produzidos por nenhum código desta fase (reservados para quando
/// `MSG_RECEIPT` e relato de falha de transporte existirem).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeliveryStateDto {
    Pending,
    Sent,
    Delivered,
    Failed,
    Sending,
    Rejected,
    Expired,
    /// Texto cujos bytes saíram do Rust sem que se saiba se chegaram (a Core
    /// abriu ou foi trancada com ele em `Sending`). Nunca é reenviado sozinho;
    /// ver `Core::resend_unknown_message`.
    Unknown,
}

/// Distingue uma mensagem de texto de uma nota de voz na timeline única —
/// Fase 5. Espelha os tipos de pacote que entram em `messages` (`MSG_TEXT`/
/// `AUDIO_CHUNK`/`FILE_METADATA` — arquivo genérico adicionado na Fase 4
/// para timeline unificada); qualquer outro `packet_type` nunca é persistido
/// nesta tabela (`store::messages::reject_typing` e o resto do desenho da
/// Fase 3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageKindDto {
    Text,
    VoiceNote,
    File,
}

/// Uma mensagem já persistida, pronta para a tela de chat renderizar — texto
/// e nota de voz na mesma timeline (Fase 5: unificar as duas era decisão do
/// usuário, não escolha técnica deste código).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageDto {
    pub id: i64,
    pub global_id: Option<String>,
    pub direction: MessageDirectionDto,
    pub kind: MessageKindDto,
    /// Corpo de texto — só significa algo quando `kind == Text`. Vazio para
    /// `VoiceNote` (o conteúdo real é `audio_file_id`, resolvido à parte
    /// via `Core::pending_audio_offers`/`Core::received_voice_notes`).
    pub body: String,
    /// `file_id` da transferência de áudio — só preenchido quando
    /// `kind == VoiceNote`.
    pub audio_file_id: Option<Vec<u8>>,
    pub delivery_state: DeliveryStateDto,
    pub created_at_unix_secs: i64,
    pub is_ephemeral: bool,
    pub reply_to_id: Option<i64>,
    pub view_once: bool,
    pub reactions: Vec<String>,
}

/// Pacote já selado que o Dart precisa enviar a um contato depois que a Core
/// foi trancada, quando a sessão que o selou já não existe mais.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SealedNoticeDto {
    pub peer_device_id: Vec<u8>,
    pub bytes: Vec<u8>,
}

/// Uma transferência de envio recém-iniciada — `Core::start_send_file`.
/// Carrega o `message_id` da linha `Pending` já inserida na timeline
/// (para exibição imediata no chat enquanto os chunks são enviados), para
/// quem chama poder marcá-la `Sent` depois (`Core::mark_message_sent`) —
/// mesmo padrão de `SendAudioStartedDto`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendFileStartedDto {
    /// Identifica a transferência nas chamadas seguintes
    /// (`next_outgoing_wire_chunk`, `transfer_progress`).
    pub file_id: Vec<u8>,
    /// Corpo do `FILE_METADATA` já selado — mandar pelo canal `control`.
    pub sealed_metadata: Vec<u8>,
    /// `id` na tabela `messages` — usado depois em `Core::mark_message_sent`.
    pub message_id: i64,
}

/// Envio enfileirado sem sessão (`Core::queue_send_file`/`queue_send_audio`,
/// D30): só o que a UI precisa para ligar a linha da timeline. A oferta sai
/// depois, por `Core::resume_transfers`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueuedTransferDto {
    pub file_id: Vec<u8>,
    /// `id` na tabela `messages`, já `Pending`.
    pub message_id: i64,
}

/// O que fazer com uma transferência devolvida por `Core::resume_transfers`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResumedDirectionDto {
    /// Quem chama volta a bombear `next_outgoing_wire_chunk`.
    Send,
    /// Quem chama volta a mandar `file_feedback` a cada 500 ms (§7.4).
    Receive,
    /// O recebimento não tinha como continuar e foi encerrado aqui; quem chama
    /// só entrega `sealed_notice` (um `FILE_REJECT`) ao par, para o emissor
    /// parar de tentar.
    Abandoned,
}

/// Uma transferência retomada com o contato — `Core::resume_transfers` (§7.5).
/// Nada aqui é segredo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumedTransferDto {
    pub file_id: Vec<u8>,
    pub direction: ResumedDirectionDto,
    /// Envio cuja oferta ainda não teve resposta e pode ter se perdido com a
    /// sessão anterior: quem chama pede o `FILE_METADATA` a
    /// `Core::seal_resumed_offer` logo antes de mandá-lo. Selar só então evita
    /// gastar um contador do ratchet numa oferta que não vai sair.
    pub needs_offer: bool,
    /// Pacote de controle já selado a entregar ao par: o `FILE_REJECT` de um
    /// recebimento `Abandoned`.
    pub sealed_notice: Option<Vec<u8>>,
    /// A linha da timeline do envio, para `Core::mark_message_sent` quando o
    /// bombeamento terminar. `None` no recebimento.
    pub message_id: Option<i64>,
}

/// Como [`SendFileStartedDto`], para `Core::start_send_audio` — carrega
/// também o `message_id` da linha `Pending` já inserida na timeline única
/// (Fase 5), para quem chama poder marcá-la `Sent` depois
/// (`Core::mark_message_sent`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendAudioStartedDto {
    pub file_id: Vec<u8>,
    pub sealed_metadata: Vec<u8>,
    pub message_id: i64,
}

/// Resultado de alimentar um pacote do canal `file` — Fase 5, D17:
/// `Core::ingest_incoming_wire_bytes` já descobre sozinho a qual
/// transferência o pacote pertence (o `file_id` vem em claro no próprio
/// pacote), então devolve qual foi para quem chama saber que progresso
/// atualizar.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IngestedChunkDto {
    pub file_id: Vec<u8>,
    pub progress: TransferProgressDto,
}

/// Uma oferta de arquivo recebida, pronta para a UI perguntar "aceitar?" —
/// hoje sempre aceita automaticamente (sem fluxo de aceite/recusa ainda,
/// ver relatório da Fase 4).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileOfferDto {
    pub file_id: Vec<u8>,
    pub name: String,
    pub file_size: u64,
}

/// Progresso de uma transferência em andamento, de qualquer lado.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TransferProgressDto {
    pub blocks_done: u32,
    pub total_blocks: u32,
    pub bytes_done: u64,
    pub is_complete: bool,
    /// Envio cuja oferta ainda não teve resposta: o emissor espera o aceite
    /// (que pode levar horas, §7.6) e não deve ser dado como parado. Sempre
    /// falso no recebimento.
    pub awaiting_answer: bool,
}

/// Tópicos de sinalização para um contato — `docs/protocol.md` §8.1.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignalingTopicsDto {
    /// Tópico para publicar agora — só a época corrente, nossa direção.
    pub publish_topic: String,
    /// Os três tópicos para assinar — épocas anterior/atual/seguinte, na
    /// direção do par (a oposta da nossa).
    pub subscribe_topics: Vec<String>,
}

/// `BeaconID`s e identificadores de preâmbulo TCP de descoberta local para um contato —
/// `docs/protocol.md` §9.1 e §9.3. Direcionais (`a2b`/`b2a`), como os tópicos de sinalização.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveryBeaconsDto {
    /// Beacon para anunciar agora — só a época corrente, nossa direção.
    pub advertise_beacon: Vec<u8>,
    /// Os três beacons aceitáveis para procurar — épocas
    /// anterior/atual/seguinte, na direção do par.
    pub scan_beacons: Vec<Vec<u8>>,
    /// Preâmbulo TCP para discar agora — época corrente, nossa direção.
    pub dial_preamble: Vec<u8>,
    /// Os três preâmbulos TCP aceitáveis para receber — épocas
    /// anterior/atual/seguinte, direção do par.
    pub listen_preambles: Vec<Vec<u8>>,
}

