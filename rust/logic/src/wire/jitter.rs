//! Jitter de envio — `docs/protocol.md` §6.5.
//!
//! Antes de cada envio, a camada de transporte espera um atraso amostrado de
//! uma normal truncada em `[5 ms, 25 ms]`. Este módulo só amostra a duração;
//! quem efetivamente dorme (`tokio::time::sleep` ou equivalente) é a camada
//! de transporte, que é a única que sabe se está enviando pela DataChannel ou
//! pelo socket TCP e qual runtime assíncrono usar.
//!
//! **Honestidade sobre o que isso defende (D12):** isto mitiga análise de
//! tráfego por um observador posicionado em *um* ponto da rede, tornando o
//! espaçamento entre pacotes menos regular. Não derrota um adversário global
//! passivo, que observa múltiplos pontos simultaneamente e pode correlacionar
//! por outros sinais (volume agregado, momento de conexão, etc.) mesmo com
//! jitter por pacote. Ver `docs/threat-model.md`.

use std::time::Duration;

const MIN_MS: f64 = 5.0;
const MAX_MS: f64 = 25.0;
const MEAN_MS: f64 = (MIN_MS + MAX_MS) / 2.0;
/// Desvio padrão tal que `[MIN_MS, MAX_MS]` cobre 3 desvios para cada lado da
/// média — a maior parte da massa da normal já cai dentro do intervalo antes
/// mesmo de truncar, então a rejeição abaixo raramente precisa de mais de uma
/// tentativa.
const STD_DEV_MS: f64 = (MAX_MS - MIN_MS) / 6.0;

/// Amostra o atraso de envio: uma normal truncada em `[5 ms, 25 ms]`.
///
/// A amostragem usa exclusivamente o CSPRNG do sistema (`crate::util::rng`),
/// como toda fonte de aleatoriedade neste crate — inclusive para jitter, que
/// não é material de chave, mas ainda assim não tem por que usar um PRNG à
/// parte.
pub fn sample_delay() -> crate::Result<Duration> {
    loop {
        let z = standard_normal()?;
        let ms = MEAN_MS + z * STD_DEV_MS;
        if (MIN_MS..=MAX_MS).contains(&ms) {
            // `clamp` aqui é só para blindar contra erro de arredondamento de
            // ponto flutuante perto da fronteira — a amostra já caiu dentro do
            // intervalo aberto testado acima.
            let micros = (ms * 1000.0).round() as u64;
            let micros = micros.clamp((MIN_MS * 1000.0) as u64, (MAX_MS * 1000.0) as u64);
            return Ok(Duration::from_micros(micros));
        }
        // Fora do intervalo: descarta e amostra de novo. É isso que faz desta
        // uma normal *truncada*, e não uma normal com os extremos cortados
        // (`clamp` sozinho empilharia massa de probabilidade nas bordas).
    }
}

/// Uma amostra da normal padrão via transformada de Box-Muller, a partir de
/// dois uniformes do CSPRNG do sistema.
fn standard_normal() -> crate::Result<f64> {
    let u1 = uniform_meio_aberto()?;
    let u2 = uniform_meio_aberto()?;
    Ok((-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos())
}

/// Uniforme em `(0, 1]`: nunca exatamente 0, para que `ln(u1)` em
/// `standard_normal` jamais veja `ln(0) = -inf`.
fn uniform_meio_aberto() -> crate::Result<f64> {
    let v = crate::util::rng::below(u32::MAX)?; // uniforme em [0, u32::MAX)
    Ok((v as f64 + 1.0) / (u32::MAX as f64 + 1.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jitter_always_stays_within_documented_interval() {
        for _ in 0..10_000 {
            let delay = sample_delay().unwrap();
            assert!(
                delay >= Duration::from_millis(5) && delay <= Duration::from_millis(25),
                "jitter fora do intervalo: {delay:?}"
            );
        }
    }

    #[test]
    fn jitter_is_not_always_same_value() {
        // Prova que a amostragem de fato varia, não uma constante disfarçada.
        let amostras: std::collections::HashSet<_> =
            (0..64).map(|_| sample_delay().unwrap()).collect();
        assert!(amostras.len() > 1);
    }
}
