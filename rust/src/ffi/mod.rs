//! Fronteira FFI — superfície exposta ao Dart via `flutter_rust_bridge`.
//!
//! Este é o único módulo apontado por `rust_input` no `flutter_rust_bridge.yaml`
//! (`crate::ffi`). Regra de fronteira, vinda de `CLAUDE.md`: nenhum segredo
//! cruza para o Dart. `Core` guarda `LocalIdentity` e `Store` como campos
//! privados — o codegen os detecta como não codificáveis e trata `Core` como
//! tipo opaco automaticamente (o Dart recebe um handle, nunca os bytes).
//! `ContactDto`/`SafetyNumberDto` só carregam dado público: chaves que já
//! atravessaram o QR e foram verificadas, ou dígitos/palavras derivados delas.

// `pub`, não `mod` privado: o código gerado por `flutter_rust_bridge_codegen`
// em `frb_generated.rs` referencia esses tipos pelo caminho completo
// (`crate::ffi::error::FfiError`, `crate::ffi::types::ContactDto`), não só
// pelo re-export abaixo.
pub mod core;
pub mod error;
pub mod jitter;
pub mod session;
pub mod signaling;
pub mod types;

pub use self::core::Core;
pub use error::FfiError;
pub use types::{
    ContactDto, DeliveryStateDto, IncomingMessageDto, MessageDirectionDto, MessageDto,
    SafetyNumberDto, SealedMessageDto, SessionStateKind, SessionStatusDto, SignalingTopicsDto,
};
