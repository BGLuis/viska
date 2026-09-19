//! Fronteira FFI do Viska: casca fina em torno de `viska_proto`, gerada por
//! `flutter_rust_bridge_codegen` a partir de `ffi/`.
//!
//! Regra de fronteira: nenhum byte de material de chave atravessa o FFI para o
//! Dart. `viska_proto` detém todos os segredos; este crate só marshalling.
//!
//! Este é o único crate do projeto sem `#![forbid(unsafe_code)]`: o código
//! gerado em `frb_generated.rs` contém `unsafe` genuíno, inerente a qualquer
//! ponte Rust↔Dart. Toda a lógica de protocolo — tudo que `CLAUDE.md` trata
//! como não-negociável quanto a `unsafe` — mora em `viska_proto`
//! (`rust/logic/`), que mantém `forbid(unsafe_code)` sem exceção. Nenhuma
//! linha escrita à mão neste crate usa `unsafe`; só o código gerado o faz.
//!
//! A especificação normativa está em `docs/protocol.md` na raiz do repositório.

#![warn(missing_debug_implementations, rust_2018_idioms)]

mod frb_generated; // Gerado por `flutter_rust_bridge_codegen generate`.
pub mod ffi;
