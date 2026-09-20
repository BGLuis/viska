//! Código de fonte RaptorQ (RFC 6330) por source block — `docs/protocol.md`
//! §7.3, D6.
//!
//! Este módulo só sabe codificar/decodificar os bytes de **um** source block
//! por vez, sem conhecer manifesto, staging, feedback nem controle de taxa —
//! quem decide quando parar de gerar reparo, para qual canal mandar e quando
//! desistir mora em `file::transfer` (F4), não aqui. Mesma separação de
//! responsabilidade de `wire`/`crypto` do resto do crate.
//!
//! ## Por que `source_block_id` da crate `raptorq` é sempre `0` aqui
//!
//! O `PayloadId` da crate `raptorq` reserva só 1 byte para o número do source
//! block (RFC 6330 §3.2) — no máximo 256 blocos por objeto na numeração
//! *dela*. O manifesto do Viska (§7.1) usa `source_blocks: u32`, porque um
//! arquivo grande o bastante com blocos de 16 MB passa de 256 blocos sem
//! problema. Para não herdar o teto de 256 blocos da crate, cada bloco vira
//! uma instância própria de [`BlockEncoder`]/[`BlockDecoder`], e o índice de
//! bloco *de verdade* (`u32`) é responsabilidade de quem chama (`transfer`,
//! no enquadramento do `FILE_SYMBOL`) — nunca do `PayloadId` interno da
//! `raptorq`, que aqui é só um identificador de correspondência interno à
//! própria chamada e sempre vale `0`.
//!
//! ## Por que o teto de símbolos aqui é 56.403, não 1.024
//!
//! 56.403 (`MAX_SOURCE_SYMBOLS_PER_BLOCK` da própria crate `raptorq`, RFC
//! 6330 §5.1.2) é o limite que evita um *panic* dentro da crate — este
//! módulo só se responsabiliza por isso. O teto de 1.024 símbolos de D6 é
//! política do Viska (orçamento de RAM do decodificador, não limitação
//! matemática do RaptorQ) e já é aplicado em [`crate::file::manifest`]; ele
//! não é repetido aqui para as duas checagens não divergirem se um dos dois
//! números mudar no futuro.

use raptorq::{
    EncodingPacket, ObjectTransmissionInformation, PayloadId, SourceBlockDecoder,
    SourceBlockEncoder,
};

use crate::{Error, Result};

/// Maior `encoding_symbol_id` que `raptorq::PayloadId` aceita (24 bits, RFC
/// 6330 §3.2) — checado aqui antes de chamar a crate, que só teria um
/// `assert!` para isso, e dado de rede nunca deve alcançar um `assert!`.
const MAX_ENCODING_SYMBOL_ID: u32 = (1 << 24) - 1;

/// Identificador de source block interno, fixo: ver o porquê no doc do
/// módulo. Nunca deriva de dado de rede.
const LOCAL_BLOCK_ID: u8 = 0;

/// RFC 6330 §5.1.2 — teto de símbolos-fonte por source block. A própria
/// crate `raptorq` impõe isso via `assert!` interno em
/// `ObjectTransmissionInformation::new` (o valor não é exportado
/// publicamente por ela); espelhado aqui como constante, checado *antes* de
/// chamar a crate — dado de rede nunca deve alcançar um `assert!` de
/// terceiro. Os testes `novo_rejeita_bloco_acima_do_teto_de_simbolos...` e
/// `novo_aceita_bloco_exatamente_no_teto...` travam esse número contra a
/// versão instalada da crate, para acusar se uma atualização mudar isso.
const RAPTORQ_MAX_SOURCE_SYMBOLS_PER_BLOCK: u64 = 56_403;

fn object_transmission_info(
    symbol_size: u16,
    block_len: u64,
) -> Result<ObjectTransmissionInformation> {
    if symbol_size == 0 {
        return Err(Error::Malformed("symbol_size não pode ser zero"));
    }
    if block_len == 0 {
        return Err(Error::Malformed("bloco de arquivo vazio"));
    }

    let symbol_count = block_len.div_ceil(symbol_size as u64);
    if symbol_count > RAPTORQ_MAX_SOURCE_SYMBOLS_PER_BLOCK {
        return Err(Error::Malformed(
            "bloco excede o teto de símbolos-fonte do RaptorQ (RFC 6330 §5.1.2)",
        ));
    }

    Ok(ObjectTransmissionInformation::new(
        block_len, symbol_size, 1, 1, 1,
    ))
}

/// Preenche `data` com zeros até o próximo múltiplo de `symbol_size` — o
/// RaptorQ exige que o buffer codificado seja um múltiplo exato do tamanho
/// de símbolo (`SourceBlockEncoder` faz um `assert!` disso). O padding nunca
/// é persistido nem verificado: quem decodifica sempre trunca de volta ao
/// `block_len` real, que viaja fora do RaptorQ (vem do manifesto).
fn pad_to_symbol_boundary(data: &[u8], symbol_size: u16) -> Vec<u8> {
    let symbol_size = symbol_size as usize;
    let padded_len = data.len().div_ceil(symbol_size) * symbol_size;
    let mut padded = Vec::with_capacity(padded_len);
    padded.extend_from_slice(data);
    padded.resize(padded_len, 0);
    padded
}

/// Codificador de um source block: parte do plaintext do bloco (já do
/// tamanho real, sem padding) e produz símbolos-fonte e de reparo.
pub struct BlockEncoder {
    inner: SourceBlockEncoder,
    source_symbol_count: u32,
}

// `raptorq::SourceBlockEncoder` não implementa `Debug`; a implementação
// manual evita expor os símbolos-fonte (conteúdo do arquivo do usuário, não
// segredo criptográfico, mas ainda assim dado privado) em qualquer log ou
// painel de erro que formate este tipo.
impl core::fmt::Debug for BlockEncoder {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("BlockEncoder")
            .field("source_symbol_count", &self.source_symbol_count)
            .finish_non_exhaustive()
    }
}

impl BlockEncoder {
    /// `block_plaintext` é o conteúdo real do bloco — não precisa ser
    /// múltiplo de `symbol_size`, o preenchimento é interno e descartado
    /// pelo lado que decodifica.
    pub fn new(symbol_size: u16, block_plaintext: &[u8]) -> Result<Self> {
        let config = object_transmission_info(symbol_size, block_plaintext.len() as u64)?;
        let padded = pad_to_symbol_boundary(block_plaintext, symbol_size);
        let inner = SourceBlockEncoder::new(LOCAL_BLOCK_ID, &config, &padded);
        let source_symbol_count = padded.len() as u32 / symbol_size as u32;

        Ok(Self {
            inner,
            source_symbol_count,
        })
    }

    /// Quantidade de símbolos-fonte deste bloco — os `encoding_symbol_id`
    /// de `0` até `source_symbol_count() - 1`. Símbolos de reparo começam em
    /// `source_symbol_count()`.
    pub fn source_symbol_count(&self) -> u32 {
        self.source_symbol_count
    }

    /// Todos os símbolos-fonte, na ordem (`id` = índice no vetor).
    pub fn source_symbols(&self) -> Vec<Vec<u8>> {
        self.inner
            .source_packets()
            .into_iter()
            .map(|packet| packet.data().to_vec())
            .collect()
    }

    /// Gera `count` símbolos de reparo a partir de
    /// `source_symbol_count() + start_repair_symbol_id`.
    ///
    /// Cada chamada gera símbolos novos (determinísticos para o mesmo
    /// `start_repair_symbol_id`, mas nunca repete um `id` já devolvido antes
    /// se `start_repair_symbol_id` avançar) — quem decide quantos pedir e
    /// quando parar é `file::transfer`, reagindo ao `FILE_FEEDBACK` (§7.3).
    pub fn repair_symbols(&self, start_repair_symbol_id: u32, count: u32) -> Vec<Vec<u8>> {
        self.inner
            .repair_packets(start_repair_symbol_id, count)
            .into_iter()
            .map(|packet| packet.data().to_vec())
            .collect()
    }
}

/// Decodificador de um source block: recebe símbolos (fonte ou reparo, em
/// qualquer ordem, com repetição tolerada) até ter o suficiente para
/// reconstruir o bloco.
pub struct BlockDecoder {
    inner: SourceBlockDecoder,
    block_len: usize,
    symbol_size: u16,
}

// Mesmo motivo do `Debug` manual de `BlockEncoder`: `SourceBlockDecoder` não
// implementa `Debug`, e os símbolos já recebidos são dado privado do
// usuário.
impl core::fmt::Debug for BlockDecoder {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("BlockDecoder")
            .field("block_len", &self.block_len)
            .field("symbol_size", &self.symbol_size)
            .finish_non_exhaustive()
    }
}

impl BlockDecoder {
    /// `block_len` é o tamanho real (sem padding) do bloco, vindo do
    /// manifesto/cálculo de offsets — nunca do próprio símbolo.
    pub fn new(symbol_size: u16, block_len: usize) -> Result<Self> {
        let config = object_transmission_info(symbol_size, block_len as u64)?;
        let inner = SourceBlockDecoder::new(LOCAL_BLOCK_ID, &config, block_len as u64);
        Ok(Self {
            inner,
            block_len,
            symbol_size,
        })
    }

    /// Alimenta um símbolo recebido. Devolve `Ok(Some(bytes))` (já truncado
    /// para `block_len`) assim que o bloco fica reconstruível, `Ok(None)`
    /// enquanto faltar símbolo, e `Err` se `symbol_id`/`data` forem
    /// incoerentes — nunca *panic*, `symbol_id` e o tamanho de `data` vêm de
    /// um par em potencial mal-intencionado.
    pub fn ingest_symbol(&mut self, symbol_id: u32, data: Vec<u8>) -> Result<Option<Vec<u8>>> {
        if symbol_id > MAX_ENCODING_SYMBOL_ID {
            return Err(Error::Malformed(
                "id de símbolo RaptorQ excede o campo de 24 bits do protocolo",
            ));
        }
        if data.len() != self.inner_symbol_size() {
            return Err(Error::Malformed(
                "símbolo RaptorQ com tamanho diferente do declarado no manifesto",
            ));
        }

        let packet = EncodingPacket::new(PayloadId::new(LOCAL_BLOCK_ID, symbol_id), data);
        match self.inner.decode(std::iter::once(packet)) {
            Some(mut padded) => {
                padded.truncate(self.block_len);
                Ok(Some(padded))
            }
            None => Ok(None),
        }
    }

    fn inner_symbol_size(&self) -> usize {
        self.symbol_size as usize
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn simple_block_decoder(symbol_size: u16, block_len: usize) -> BlockDecoder {
        BlockDecoder::new(symbol_size, block_len).unwrap()
    }

    #[test]
    fn ida_e_volta_so_com_simbolos_fonte() {
        let data: Vec<u8> = (0..10_000u32).map(|i| (i % 251) as u8).collect();
        let encoder = BlockEncoder::new(512, &data).unwrap();
        let mut decoder = simple_block_decoder(512, data.len());

        let mut resultado = None;
        for (id, symbol) in encoder.source_symbols().into_iter().enumerate() {
            resultado = decoder.ingest_symbol(id as u32, symbol).unwrap();
            if resultado.is_some() {
                break;
            }
        }

        assert_eq!(resultado.unwrap(), data);
    }

    #[test]
    fn repara_com_30_por_cento_dos_simbolos_fonte_descartados() {
        let data: Vec<u8> = (0..200_000u32).map(|i| (i * 7 % 256) as u8).collect();
        let symbol_size = 1024u16;
        let encoder = BlockEncoder::new(symbol_size, &data).unwrap();
        let k = encoder.source_symbol_count();

        let mut decoder = simple_block_decoder(symbol_size, data.len());
        let mut resultado = None;

        // Descarta ~30% dos símbolos-fonte, determinístico (sem depender de
        // aleatoriedade em teste): todo terceiro símbolo.
        for (id, symbol) in encoder.source_symbols().into_iter().enumerate() {
            if id % 3 == 0 {
                continue;
            }
            resultado = decoder.ingest_symbol(id as u32, symbol).unwrap();
            if resultado.is_some() {
                break;
            }
        }
        assert!(
            resultado.is_none(),
            "não deveria decodificar só com símbolos-fonte faltando"
        );

        // Repara com símbolos de reparo suficientes para cobrir o descarte
        // (com folga: RaptorQ às vezes precisa de 1-2 símbolos extras).
        let faltantes = (k as usize).div_ceil(3) + 4;
        for (i, symbol) in encoder.repair_symbols(0, faltantes as u32).into_iter().enumerate() {
            resultado = decoder.ingest_symbol(k + i as u32, symbol).unwrap();
            if resultado.is_some() {
                break;
            }
        }

        assert_eq!(resultado.unwrap(), data);
    }

    #[test]
    fn bloco_cujo_tamanho_nao_e_multiplo_do_simbolo_reconstroi_exato() {
        let data = vec![0x5Au8; 10_007]; // não é múltiplo de 1024.
        let symbol_size = 1024u16;
        let encoder = BlockEncoder::new(symbol_size, &data).unwrap();
        let mut decoder = simple_block_decoder(symbol_size, data.len());

        let mut resultado = None;
        for (id, symbol) in encoder.source_symbols().into_iter().enumerate() {
            resultado = decoder.ingest_symbol(id as u32, symbol).unwrap();
            if resultado.is_some() {
                break;
            }
        }

        let bytes = resultado.unwrap();
        assert_eq!(bytes.len(), data.len());
        assert_eq!(bytes, data);
    }

    #[test]
    fn ingest_e_idempotente_para_o_mesmo_simbolo_repetido() {
        let data = vec![0xABu8; 5_000];
        let symbol_size = 512u16;
        let encoder = BlockEncoder::new(symbol_size, &data).unwrap();
        let mut decoder = simple_block_decoder(symbol_size, data.len());

        let symbols = encoder.source_symbols();
        // Manda o primeiro símbolo duas vezes antes de completar o resto —
        // não deveria confundir a contagem de símbolos únicos recebidos.
        decoder.ingest_symbol(0, symbols[0].clone()).unwrap();
        decoder.ingest_symbol(0, symbols[0].clone()).unwrap();

        let mut resultado = None;
        for (id, symbol) in symbols.into_iter().enumerate().skip(1) {
            resultado = decoder.ingest_symbol(id as u32, symbol).unwrap();
            if resultado.is_some() {
                break;
            }
        }

        assert_eq!(resultado.unwrap(), data);
    }

    #[test]
    fn ingest_rejeita_simbolo_de_tamanho_errado_sem_panico() {
        let mut decoder = simple_block_decoder(512, 5_000);
        assert!(matches!(
            decoder.ingest_symbol(0, vec![0u8; 511]),
            Err(Error::Malformed(_))
        ));
        assert!(matches!(
            decoder.ingest_symbol(0, vec![0u8; 513]),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn ingest_rejeita_symbol_id_acima_de_24_bits_sem_panico() {
        let mut decoder = simple_block_decoder(512, 5_000);
        assert!(matches!(
            decoder.ingest_symbol(1 << 24, vec![0u8; 512]),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn novo_rejeita_bloco_vazio() {
        assert!(matches!(
            BlockEncoder::new(512, &[]),
            Err(Error::Malformed(_))
        ));
        assert!(matches!(
            BlockDecoder::new(512, 0),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn novo_rejeita_symbol_size_zero() {
        assert!(matches!(
            BlockEncoder::new(0, &[1, 2, 3]),
            Err(Error::Malformed(_))
        ));
        assert!(matches!(
            BlockDecoder::new(0, 10),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn novo_rejeita_bloco_acima_do_teto_de_simbolos_do_raptorq() {
        // symbol_size = 1 força um símbolo por byte — barato de montar em
        // teste e força o teto de 56.403 símbolos-fonte a estourar.
        let tamanho = 56_404usize;
        assert!(matches!(
            BlockEncoder::new(1, &vec![0u8; tamanho]),
            Err(Error::Malformed(_))
        ));
        assert!(matches!(
            BlockDecoder::new(1, tamanho),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn novo_aceita_bloco_exatamente_no_teto_de_simbolos_do_raptorq() {
        // Prova que o teto espelhado em `RAPTORQ_MAX_SOURCE_SYMBOLS_PER_BLOCK`
        // não está conservador demais: o valor exato ainda passa na
        // validação — só `+1` (teste acima) deveria falhar.
        //
        // Não constrói de fato um `BlockEncoder` neste tamanho: gerar os
        // símbolos intermediários do RaptorQ para ~56 mil símbolos-fonte é
        // uma resolução de matriz cara demais para rodar em build de
        // depuração a cada `cargo test` (minutos, não milissegundos) — quem
        // este teste quer travar é a validação (`object_transmission_info`),
        // não o desempenho da crate `raptorq` nesse tamanho.
        let tamanho = 56_403u64;
        assert!(object_transmission_info(1, tamanho).is_ok());

        // O lado do decodificador só aloca um vetor de posições vazias na
        // construção — o trabalho pesado de verdade só acontece ao
        // `ingest_symbol` (delegado a `SourceBlockDecoder::decode`) — então
        // continua barato mesmo neste tamanho.
        assert!(BlockDecoder::new(1, tamanho as usize).is_ok());
    }
}
