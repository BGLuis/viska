//! Núcleo do Viska: identidade, pareamento, handshake híbrido pós-quântico,
//! ratchet, envelope de transporte, persistência e pipeline de arquivos.
//!
//! Este crate nunca faz FFI diretamente — quem expõe isso ao Dart é o crate
//! `viska_core` (em `rust/src/`), fino, que depende deste aqui. A separação
//! existe porque o código gerado pelo `flutter_rust_bridge_codegen` contém
//! `unsafe` genuíno (inerente a qualquer ponte Rust↔Dart) e não pode conviver
//! com `#![forbid(unsafe_code)]` no mesmo crate — e essa regra não tem
//! exceção. Então ela fica aqui, isolada, e nenhuma linha deste crate escapa
//! dela.
//!
//! A especificação normativa está em `docs/protocol.md` na raiz do repositório.

#![forbid(unsafe_code)]
#![warn(missing_debug_implementations, rust_2018_idioms)]

pub mod crypto;
pub mod discovery;
pub mod file;
pub mod session;
pub mod signaling;
pub mod store;
pub mod util;
pub mod wire;

/// Versão do protocolo de fio implementada por este crate.
pub const PROTOCOL_VERSION: u8 = 0x01;

/// Erro unificado do núcleo.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("versão de protocolo não suportada: {0:#04x}")]
    UnsupportedVersion(u8),

    #[error("payload malformado: {0}")]
    Malformed(&'static str),

    #[error("comprimento inválido: esperado {expected}, recebido {actual}")]
    BadLength { expected: usize, actual: usize },

    #[error("assinatura inválida")]
    BadSignature,

    #[error("falha na autenticação do AEAD")]
    AeadFailure,

    #[error("raiz de Merkle recomputada não bate com a esperada")]
    MerkleMismatch,

    #[error("chave pública inválida: {0}")]
    InvalidPublicKey(&'static str),

    #[error("contribuição de ordem baixa detectada no Diffie-Hellman")]
    LowOrderPoint,

    #[error("auto-pareamento: o contato apresenta a identidade deste dispositivo")]
    SelfPairing,

    #[error("estado de sessão inválido: {0}")]
    InvalidState(&'static str),

    #[error("mensagem não decifrável: chave já consumida ou fora da janela")]
    UndecryptableMessage,

    #[error("payload excede o maior bucket de padding ({max} bytes)")]
    PayloadTooLarge { max: usize },

    #[error("falha ao obter aleatoriedade do sistema operacional")]
    Rng,

    #[error("contador de mensagens de 32 bits esgotado")]
    CounterOverflow,

    #[error("contador de envio cruzou o limiar de segurança; abra uma sessão nova")]
    NeedsRehandshake,

    #[error("falha no banco cifrado")]
    Store,

    #[error("contato não encontrado")]
    ContactNotFound,
}

pub type Result<T> = core::result::Result<T, Error>;
