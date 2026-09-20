//! Pipeline de arquivos — `docs/protocol.md` §7 (Fase 4).
//!
//! Fica acima de `session`, nunca dentro dela: `session::Session` não
//! despacha por `PacketType` (é agnóstica a ele por desenho), então quem colar
//! manifesto, RaptorQ, staging e controle de taxa num estado por
//! transferência precisa ser uma camada própria — ver `transfer` mais adiante
//! nesta fase.

pub mod fountain;
pub mod keys;
pub mod manifest;
pub mod merkle;
pub mod staging;
pub mod transfer;
