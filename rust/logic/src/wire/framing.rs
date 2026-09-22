//! Enquadramento de transporte — `docs/protocol.md` §6.4, D4.
//!
//! - **DataChannel WebRTC**: SCTP já entrega mensagens delimitadas, então a
//!   camada de sessão manda o envelope inteiro como uma mensagem do
//!   DataChannel e não passa por este módulo.
//! - **Socket TCP local**: TCP é um fluxo de bytes sem limites de mensagem, e
//!   entrega pedaços de tamanho arbitrário — nunca garantidamente um envelope
//!   inteiro por `read()`. Este módulo resolve isso com um prefixo `u32`
//!   big-endian de comprimento, e nada além disso: **nenhum magic number**.
//!   Um magic number fixo seria uma impressão digital perfeita para DPI (D4)
//!   — bastaria a caixa do meio procurar por aqueles bytes fixos para marcar
//!   todo o tráfego do app.

use crate::crypto::aead::TAG_LEN;
use crate::wire::envelope::COUNTER_LEN;
use crate::wire::transport::Transport;
use crate::{Error, Result};

/// Tamanho do prefixo de comprimento que precede cada envelope no socket TCP.
pub const LENGTH_PREFIX_LEN: usize = 4;

/// Maior envelope que um par honesto pode produzir: o maior bucket de
/// plaintext do socket TCP local, mais o contador em claro e a tag do AEAD.
///
/// Qualquer comprimento anunciado acima disso só pode vir de um peer hostil
/// ou de um bug sério — e é rejeitado *antes* de alocar um único byte para o
/// corpo do quadro, para que um comprimento forjado de 4 GB não vire uma
/// tentativa de alocação de 4 GB.
pub const MAX_FRAME_LEN: usize = COUNTER_LEN + Transport::LocalSocket.max_bucket() + TAG_LEN;

/// Prefixa `envelope` com seu comprimento em big-endian, para envio pelo socket TCP.
pub fn frame(envelope: &[u8]) -> Result<Vec<u8>> {
    let len: u32 = envelope
        .len()
        .try_into()
        .map_err(|_| Error::Malformed("envelope grande demais para enquadrar em um u32"))?;

    let mut out = Vec::with_capacity(LENGTH_PREFIX_LEN + envelope.len());
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(envelope);
    Ok(out)
}

/// Extrai o próximo quadro completo de `buffer`, se já tiver chegado por
/// inteiro, removendo-o do início do buffer.
///
/// `Ok(None)` significa "ainda não chegaram bytes suficientes" — TCP entrega
/// pedaços arbitrários, então o chamador simplesmente lê mais do socket e
/// tenta de novo, acumulando em `buffer`. `Err` só acontece para um
/// comprimento anunciado maior que `MAX_FRAME_LEN`, verificado antes de
/// qualquer alocação proporcional a esse comprimento.
pub fn extract_frame(buffer: &mut Vec<u8>) -> Result<Option<Vec<u8>>> {
    if buffer.len() < LENGTH_PREFIX_LEN {
        return Ok(None);
    }

    let len_bytes: [u8; LENGTH_PREFIX_LEN] = buffer[..LENGTH_PREFIX_LEN]
        .try_into()
        .expect("comprimento checado acima");
    let len = u32::from_be_bytes(len_bytes) as usize;

    if len > MAX_FRAME_LEN {
        return Err(Error::Malformed(
            "quadro TCP anuncia comprimento absurdo para um envelope válido",
        ));
    }

    let total = LENGTH_PREFIX_LEN + len;
    if buffer.len() < total {
        return Ok(None);
    }

    let frame = buffer[LENGTH_PREFIX_LEN..total].to_vec();
    buffer.drain(..total);
    Ok(Some(frame))
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn roundtrip_single_complete_frame() {
        let envelope = b"envelope de teste".to_vec();
        let mut buffer = frame(&envelope).unwrap();

        let extraido = extract_frame(&mut buffer).unwrap();
        assert_eq!(extraido, Some(envelope));
        assert!(buffer.is_empty());
    }

    #[test]
    fn incomplete_buffer_returns_none_without_consuming() {
        let envelope = b"envelope maior que o prefixo".to_vec();
        let completo = frame(&envelope).unwrap();

        // Só o prefixo de comprimento, sem nenhum byte do corpo ainda.
        let mut parcial = completo[..LENGTH_PREFIX_LEN].to_vec();
        assert_eq!(extract_frame(&mut parcial).unwrap(), None);
        assert_eq!(parcial.len(), LENGTH_PREFIX_LEN);

        // Prefixo completo e corpo pela metade.
        let meio = completo.len() / 2;
        let mut parcial2 = completo[..meio].to_vec();
        assert_eq!(extract_frame(&mut parcial2).unwrap(), None);
    }

    #[test]
    fn multiple_concatenated_frames_are_reassembled_in_order() {
        let envelopes: Vec<Vec<u8>> = vec![
            b"primeiro".to_vec(),
            b"segundo, um pouco maior".to_vec(),
            Vec::new(),
            vec![0x42u8; 500],
        ];

        let mut stream = Vec::new();
        for envelope in &envelopes {
            stream.extend(frame(envelope).unwrap());
        }

        let mut extraidos = Vec::new();
        while let Some(quadro) = extract_frame(&mut stream).unwrap() {
            extraidos.push(quadro);
        }

        assert_eq!(extraidos, envelopes);
        assert!(stream.is_empty());
    }

    #[test]
    fn rejects_absurd_length_without_allocating_body() {
        let mut buffer = (MAX_FRAME_LEN as u32 + 1).to_be_bytes().to_vec();
        // Deliberadamente sem anexar nenhum byte de corpo: se `extract_frame`
        // tentasse alocar `len` bytes antes de checar o teto, isto já teria
        // estourado memória bem antes de qualquer asserção rodar.
        assert!(matches!(
            extract_frame(&mut buffer),
            Err(Error::Malformed(_))
        ));
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(64))]

        /// Um fluxo com vários quadros concatenados, cortado em qualquer
        /// posição possível, é sempre remontado corretamente assim que os
        /// bytes que faltam chegam — nunca perde, duplica ou embaralha quadros.
        #[test]
        fn reassembly_is_correct_for_any_slice(
            envelopes in proptest::collection::vec(
                proptest::collection::vec(any::<u8>(), 0..200),
                0..8,
            ),
            corte_seed in any::<u64>(),
        ) {
            let mut stream = Vec::new();
            for envelope in &envelopes {
                stream.extend(frame(envelope).unwrap());
            }

            // Corta o stream em pedaços de tamanho pseudo-aleatório (mas
            // determinístico, a partir da semente do proptest) para simular
            // `read()`s parciais de um socket TCP real.
            let mut pedacos = Vec::new();
            let mut resto = stream.as_slice();
            let mut estado = corte_seed.max(1);
            while !resto.is_empty() {
                estado = estado.wrapping_mul(6364136223846793005).wrapping_add(1);
                let tamanho = 1 + (estado % 37) as usize;
                let tamanho = tamanho.min(resto.len());
                let (pedaco, novo_resto) = resto.split_at(tamanho);
                pedacos.push(pedaco.to_vec());
                resto = novo_resto;
            }

            let mut buffer = Vec::new();
            let mut extraidos = Vec::new();
            for pedaco in pedacos {
                buffer.extend(pedaco);
                while let Some(quadro) = extract_frame(&mut buffer).unwrap() {
                    extraidos.push(quadro);
                }
            }

            prop_assert_eq!(extraidos, envelopes);
            prop_assert!(buffer.is_empty());
        }
    }
}
