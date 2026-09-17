//! Primitivas criptográficas e protocolos de sessão.
//!
//! Implementa `docs/protocol.md`. Cada módulo corresponde a uma seção da
//! especificação e qualquer divergência entre os dois é bug neste código.

pub mod aead;
pub mod dh;
pub mod handshake;
pub mod identity;
pub mod kdf;
pub mod kem;
pub mod pairing;
pub mod ratchet;
pub mod safety_number;
