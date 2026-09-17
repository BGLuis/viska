//! Envelope de transporte — `docs/protocol.md` §6, com D4, D5 e D6 lidos como
//! justificativa de desenho.
//!
//! Este módulo é serialização pura e determinística: monta e desmonta bytes,
//! nunca cifra nem deriva chave. A única exceção é o CSPRNG, usado para gerar
//! bytes de padding e para amostrar o jitter de envio — nenhum dos dois é
//! material de chave, mas ambos seguem a mesma regra do resto do crate de
//! nunca usar um PRNG de aplicação.
//!
//! Uma futura camada `session` é quem cola `crypto::ratchet` (chaves e
//! contadores) com este módulo (bytes) e `crypto::aead` (cifra), na ordem:
//!
//! 1. `plaintext::InnerPlaintext::encode` produz o plaintext preenchido até o
//!    bucket do transporte;
//! 2. `crypto::aead::seal` cifra esse plaintext, usando `envelope::aad` como AAD;
//! 3. `envelope::encode` prefixa o contador em claro ao resultado;
//! 4. no socket TCP, `framing::frame` prefixa o comprimido do envelope —
//!    no DataChannel, o envelope já é a mensagem inteira.
//!
//! Do lado de recepção, os passos rodam na ordem inversa, com
//! `framing::extract_frame`, `envelope::decode`, `crypto::aead::open` e
//! `plaintext::InnerPlaintext::decode`.
//!
//! Essa separação é o que permite testar este módulo exaustivamente com
//! property tests sem precisar de nenhuma chave — veja os testes em cada
//! submódulo, em especial o de `decode` nunca entrar em pânico sobre bytes
//! arbitrários em `plaintext.rs`.

pub mod envelope;
pub mod framing;
pub mod jitter;
pub mod packet_type;
pub mod plaintext;
pub mod transport;

pub use envelope::COUNTER_LEN;
pub use packet_type::PacketType;
pub use plaintext::InnerPlaintext;
pub use transport::Transport;
