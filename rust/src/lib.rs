//! Núcleo do Viska: identidade, pareamento, handshake híbrido pós-quântico,
//! ratchet, envelope de transporte e pipeline de arquivos.
//!
//! Regra de fronteira: nenhum byte de material de chave atravessa o FFI para o
//! Dart. Este crate detém todos os segredos; a camada Flutter só orquestra UI,
//! sensores e sockets.
//!
//! A especificação normativa está em `docs/protocol.md` na raiz do repositório.

#![forbid(unsafe_code)]
#![warn(missing_debug_implementations, rust_2018_idioms)]

pub mod crypto;
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
}

pub type Result<T> = core::result::Result<T, Error>;
