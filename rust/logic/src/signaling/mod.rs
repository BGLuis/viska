//! Sinalização remota — `docs/protocol.md` §8 (D8).
//!
//! Só produz bytes prontos para publicar/assinar; não sabe nada de MQTT,
//! Nostr ou qualquer transporte de sinalização em si — isso é
//! responsabilidade da camada Dart (Fase 3, F4). `topic` deriva o tópico
//! rotativo por época (§8.1); `payload` cifra/decifra o SDP e os candidatos
//! ICE (§8.2).
//!
//! Ao contrário de `session`, `K_sig` aqui vem de um DH **estático** entre as
//! duas identidades de longo prazo trocadas no QR — não da raiz de um
//! ratchet. A sinalização existe para estabelecer o `DataChannel`; ela não
//! pode depender de uma sessão que só existe depois que o handshake já rodou
//! sobre esse mesmo `DataChannel` (decisão registrada em `docs/protocol.md`
//! §8.1).

pub mod payload;
pub mod topic;

pub use topic::{signaling_key, Direction};
