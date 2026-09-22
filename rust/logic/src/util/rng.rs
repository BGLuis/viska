//! Aleatoriedade.
//!
//! Toda entropia do Viska vem do CSPRNG do sistema operacional, sem exceção:
//! nenhum PRNG de aplicação gera material de chave, nonce, padding ou jitter.
//! Um PRNG semeado uma única vez é um risco desnecessário em um app móvel, que
//! pode ser clonado, restaurado de snapshot ou suspenso por horas.

use crate::{Error, Result};

/// Preenche `dst` com bytes aleatórios do sistema operacional.
pub fn fill(dst: &mut [u8]) -> Result<()> {
    getrandom::fill(dst).map_err(|_| Error::Rng)
}

/// Devolve um array aleatório de tamanho fixo.
pub fn array<const N: usize>() -> Result<[u8; N]> {
    let mut out = [0u8; N];
    fill(&mut out)?;
    Ok(out)
}

/// Maior candidato aceito pela amostragem por rejeição de [`below`].
///
/// Separado em função própria por dois motivos: (1) o cálculo é sutil o
/// bastante para merecer nome e comentário isolados, e (2) assim dá para
/// travar em teste, sem sortear nada, o invariante que define "sem viés":
/// a quantidade de candidatos aceitos (`limit as u64 + 1`) tem que ser
/// múltiplo exato de `bound` — senão os restos menores saem mais prováveis
/// que os maiores, que é exatamente o defeito que a rejeição existe para
/// evitar.
///
/// `2^32` não cabe em `u32`, então `2^32 mod bound` é obtido em duas etapas
/// só com aritmética que cabe no tipo: `u32::MAX % bound` dá
/// `(2^32 - 1) mod bound`, e somar 1 (com um segundo `% bound` para cobrir o
/// caso em que isso estoura para exatamente `bound`) completa a conta sem
/// nunca precisar de um tipo maior.
fn rejection_limit(bound: u32) -> u32 {
    let rem = ((u32::MAX % bound) + 1) % bound; // == 2^32 mod bound
    u32::MAX - rem
}

/// Inteiro uniforme em `[0, bound)` sem viés de módulo, por rejeição.
///
/// `bound` é pré-condição do chamador (hoje sempre uma constante do próprio
/// crate — número de buckets de padding, largura da faixa de jitter — nunca
/// um valor vindo da rede), não um dado a validar em runtime. Por isso
/// `bound == 0` vira `assert!` — pânico determinístico e com mensagem clara
/// em **qualquer** perfil de build — em vez de `Result::Err`: devolver erro
/// obrigaria todo chamador a tratar como falha de ambiente (rede, SO) algo
/// que é um bug de programação no próprio crate, escondendo o bug atrás de
/// um `?` em vez de estourá-lo no primeiro teste. Um `debug_assert!` sozinho
/// não bastava: removido em release, a conta de `rejection_limit` acabaria
/// caindo numa divisão por zero de qualquer jeito (Rust sempre verifica
/// divisão/resto por zero, em release também — nunca é UB nem "passa
/// direto"), só que com uma mensagem de pânico genérica em vez de apontar o
/// problema real.
pub fn below(bound: u32) -> Result<u32> {
    assert!(bound > 0, "util::rng::below: bound deve ser maior que zero");

    // `bound == 1` teria `limit == u32::MAX`, ou seja, todo candidato seria
    // aceito e reduzido a 0 de qualquer forma — mas sortear bytes do SO só
    // para descartá-los é desperdício de entropia sem propósito, já que o
    // único valor possível em `[0, 1)` é conhecido de antemão.
    if bound == 1 {
        return Ok(0);
    }

    let limit = rejection_limit(bound);
    loop {
        let candidate = u32::from_le_bytes(array::<4>()?);
        if candidate <= limit {
            return Ok(candidate % bound);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn below_one_always_returns_zero() {
        for _ in 0..100 {
            assert_eq!(below(1).unwrap(), 0);
        }
    }

    #[test]
    fn samples_always_fall_within_interval() {
        for bound in [2u32, 3, 7, 1000, u32::MAX] {
            for _ in 0..2_000 {
                let v = below(bound).unwrap();
                assert!(v < bound, "bound={bound}: valor {v} fora de [0, bound)");
            }
        }
    }

    #[test]
    fn below_with_maximum_bound_terminates_quickly() {
        // Este é o teste que teria pego a regressão original: com a fórmula
        // antiga, `bound = u32::MAX` colapsava `limit` para 1, aceitando só
        // ~4,7e-10 dos candidatos — cada amostra precisava, em média, de mais
        // de 2 bilhões de sorteios, e os testes de `wire::jitter` (que chamam
        // `below(u32::MAX)`) passavam de 60s cada. Com o limite correto a
        // aceitação fica ~100%, então isto deve terminar em milissegundos.
        let inicio = std::time::Instant::now();
        for _ in 0..5_000 {
            below(u32::MAX).unwrap();
        }
        let decorrido = inicio.elapsed();
        // 2s é uma folga generosa para não ficar flaky sob CI carregado, mas
        // continua duas ordens de grandeza abaixo dos >60s do bug original —
        // qualquer regressão de rejeição patológica ainda estoura o teste.
        assert!(
            decorrido < std::time::Duration::from_secs(2),
            "below(u32::MAX) muito lento: {decorrido:?} para 5000 amostras"
        );
    }

    #[test]
    fn distributes_uniformly_for_small_bound() {
        let bound = 6u32;
        let amostras = 60_000u32;
        let p = 1.0 / bound as f64;
        let esperado = amostras as f64 * p;

        // A contagem de cada valor segue uma binomial(amostras, p); usamos o
        // desvio padrão dela para dimensionar a margem em vez de cravar um
        // número arbitrário, para a margem continuar fazendo sentido se
        // `amostras` mudar no futuro. 8 desvios padrão dá uma folga enorme
        // (a chance de um gerador correto estourar isso por puro acaso do
        // sorteio é da ordem de 1e-15 por valor) — um teste estatístico que
        // falha de vez em quando por sorte é pior que nenhum teste, porque
        // ensina a ignorar falha de CI. Só falha aqui se houver viés real.
        let desvio_padrao = (amostras as f64 * p * (1.0 - p)).sqrt();
        let margem = 8.0 * desvio_padrao;

        let mut contagem = [0u32; 6];
        for _ in 0..amostras {
            let v = below(bound).unwrap();
            contagem[v as usize] += 1;
        }

        for (valor, &c) in contagem.iter().enumerate() {
            let diff = (c as f64 - esperado).abs();
            assert!(
                diff <= margem,
                "valor {valor}: contagem {c}, esperado {esperado:.1} ± {margem:.1}"
            );
        }
    }

    #[test]
    fn accepted_count_is_always_multiple_of_bound() {
        // Este é o invariante que define "sem viés de módulo": se a
        // quantidade de candidatos aceitos não for múltiplo exato de
        // `bound`, o `% bound` final favorece os restos menores.
        for bound in [2u32, 3, 7, 1000, 100_000, u32::MAX] {
            let limit = rejection_limit(bound);
            // `+1` em u64 porque `limit` pode ser `u32::MAX` (quando `bound`
            // divide `2^32` exatamente), e `limit + 1` estouraria um `u32`.
            let aceitos = limit as u64 + 1;
            assert_eq!(
                aceitos % bound as u64,
                0,
                "bound={bound}: aceitos={aceitos} não é múltiplo de bound"
            );
        }
    }
}
