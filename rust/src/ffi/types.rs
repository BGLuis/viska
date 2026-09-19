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

/// Uma mensagem já persistida, pronta para a tela de chat renderizar.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageDto {
    pub id: i64,
    pub direction: MessageDirectionDto,
    pub body: String,
    pub delivery_state: DeliveryStateDto,
    pub created_at_unix_secs: i64,
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
