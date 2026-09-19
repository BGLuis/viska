//! Amostragem de jitter para o Dart — `docs/protocol.md` §6.5.
//!
//! `wire::jitter::sample_delay` só amostra, nunca dorme: quem aplica o
//! atraso é a camada de transporte, do lado Dart (decisão 2.5 do relatório
//! de Fase 3), porque só ela sabe qual runtime assíncrono está em uso. Esta
//! função é só a travessia da fronteira — o Rust amostra do CSPRNG, o Dart
//! chama `Future.delayed` com o valor devolvido antes de cada envio.

use crate::ffi::error::FfiError;

/// Atraso a aplicar antes do próximo envio, em milissegundos — normal
/// truncada em [5, 25] ms (§6.5). Chamar de novo a cada mensagem: o valor
/// não deve ser reaproveitado entre envios.
pub fn sample_jitter_delay_ms() -> Result<u64, FfiError> {
    let delay = viska_proto::wire::jitter::sample_delay()?;
    Ok(delay.as_millis() as u64)
}
