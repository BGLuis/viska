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
}

impl ContactDto {
    pub(crate) fn from_identity(
        identity: &PublicIdentity,
        paired_at_unix_secs: i64,
        nickname: Option<String>,
    ) -> Self {
        Self {
            device_id: identity.device_id.to_vec(),
            signing_pubkey: identity.signing.to_vec(),
            dh_pubkey: identity.dh.as_bytes().to_vec(),
            paired_at_unix_secs,
            nickname,
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
    /// Precisa de uma sessão nova (`Core::ensure_session` de novo).
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
}

/// Distingue uma mensagem de texto de uma nota de voz na timeline única —
/// Fase 5. Espelha os dois valores de `packet_type` que hoje entram em
/// `messages` (`MSG_TEXT`/`AUDIO_CHUNK`); qualquer outro `packet_type`
/// nunca é persistido nesta tabela (`store::messages::reject_typing` e o
/// resto do desenho da Fase 3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageKindDto {
    Text,
    VoiceNote,
}

/// Uma mensagem já persistida, pronta para a tela de chat renderizar — texto
/// e nota de voz na mesma timeline (Fase 5: unificar as duas era decisão do
/// usuário, não escolha técnica deste código).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageDto {
    pub id: i64,
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
}

/// Uma transferência de envio recém-iniciada — `Core::start_send_file`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendFileStartedDto {
    /// Identifica a transferência nas chamadas seguintes
    /// (`next_outgoing_wire_chunk`, `transfer_progress`).
    pub file_id: Vec<u8>,
    /// Corpo do `FILE_METADATA` já selado — mandar pelo canal `control`.
    pub sealed_metadata: Vec<u8>,
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

/// `BeaconID`s de descoberta local para um contato — `docs/protocol.md` §9.1.
/// Os dois lados calculam o mesmo `advertise_beacon`, ao contrário dos
/// tópicos de sinalização (que têm direção).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveryBeaconsDto {
    /// Beacon para anunciar agora — só a época corrente.
    pub advertise_beacon: Vec<u8>,
    /// Os três beacons aceitáveis para procurar — épocas
    /// anterior/atual/seguinte.
    pub scan_beacons: Vec<Vec<u8>>,
}
