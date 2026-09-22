//! Manifesto de arquivo (`FILE_METADATA`, 0x20) — `docs/protocol.md` §7.1.
//!
//! CBOR: cada campo é uma entrada de mapa, chave por texto, sempre montadas
//! na mesma ordem — a mesma serialização vale para os dois lados, então não
//! há ambiguidade a resolver por fora do protocolo. Construído diretamente
//! sobre `ciborium::value::Value`, em vez de `#[derive(Serialize)]`, para
//! controlar byte a byte a representação de cada campo (`file_id` e
//! `merkle_root` como *byte string* CBOR, não como array de inteiros — o que
//! `serde` produziria por padrão para `[u8; N]`/`Vec<u8>` sem uma crate
//! auxiliar) e para poder validar cada campo lido, no espírito de
//! `wire::plaintext::decode`: nenhuma fatia sem checar limite antes.
//!
//! `decode` processa bytes que vêm de um par em potencial mal-intencionado —
//! o AEAD do envelope já autenticou o pacote, mas nada garante que o corpo
//! seja um manifesto bem formado. Por isso todo campo é validado contra os
//! invariantes do próprio protocolo (D6, buckets de `wire::transport`), não
//! só contra o formato CBOR — um manifesto que decodifica sem erro mas com
//! `block_symbols = 0`, por exemplo, quebraria o resto do pipeline mais
//! adiante de um jeito bem mais difícil de depurar do que rejeitar aqui.

use ciborium::value::{Integer, Value};

use crate::wire::transport::Transport;
use crate::{Error, Result};

/// Tamanho de `file_id`, em bytes.
pub const FILE_ID_LEN: usize = 16;
/// Tamanho de `merkle_root`, em bytes — saída padrão do BLAKE3.
pub const MERKLE_ROOT_LEN: usize = 32;
/// Teto de símbolos-fonte por bloco (D6) — RFC 6330 permite até 56.403; o
/// protocolo fixa bem menos para travar o pico de RAM do decodificador
/// RaptorQ (~16 MB a 16 KB de símbolo). Travado em `const`, não em
/// comentário, por pedido explícito do relatório da Fase 4.
pub const MAX_BLOCK_SYMBOLS: u16 = 1024;

const _: () = assert!(MAX_BLOCK_SYMBOLS as u32 <= 56_403);

/// Teto de sanidade para `source_blocks`, independente da consistência
/// aritmética com `file_size`/`symbol_size`/`block_symbols` — sem isto, um
/// manifesto malicioso com `file_size` astronômico (mas ainda consistente)
/// faria `ReceiveTransfer::start` alocar um `Vec<bool>` de gigabytes (um
/// `bool` por bloco) só para registrar o progresso, antes de qualquer
/// símbolo chegar. Não há aceitar/recusar oferta ainda (Fase 4): qualquer
/// contato pareado pode mandar um `FILE_METADATA`, então este teto é a
/// única defesa contra esse vetor. 65.536 blocos, no maior tamanho de
/// bloco possível (1024 símbolos × 65536 B, D6), já cobre 4 TB — bem acima
/// de qualquer transferência real neste app; o `Vec<bool>` correspondente
/// nunca passa de 64 KB.
pub const MAX_SOURCE_BLOCKS: u32 = 65_536;

/// Único valor de `mime` que já trafegou ou trafegará no fio — o tipo real
/// do arquivo vai cifrado dentro do corpo, nunca em claro (§7.1).
pub const MIME_OCTET_STREAM: &str = "application/octet-stream";

const KEY_FILE_ID: &str = "file_id";
const KEY_FILE_SIZE: &str = "file_size";
const KEY_SYMBOL_SIZE: &str = "symbol_size";
const KEY_SOURCE_BLOCKS: &str = "source_blocks";
const KEY_BLOCK_SYMBOLS: &str = "block_symbols";
const KEY_MERKLE_ROOT: &str = "merkle_root";
const KEY_NAME_ENCRYPTED: &str = "name_encrypted";
const KEY_MIME: &str = "mime";

/// Manifesto de uma transferência de arquivo — corpo do pacote
/// `FILE_METADATA`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    /// Identificador aleatório da transferência — sobrevive a troca de
    /// transporte (WebRTC → LAN) e a retomada após queda de conexão.
    pub file_id: [u8; FILE_ID_LEN],
    /// Tamanho do arquivo em claro, em bytes.
    pub file_size: u64,
    /// 16384 no DataChannel WebRTC, 65536 na LAN — um dos dois buckets de
    /// `wire::transport::Transport`.
    pub symbol_size: u16,
    /// Quantidade de source blocks RaptorQ em que o arquivo é particionado.
    pub source_blocks: u32,
    /// Símbolos-fonte por bloco — no máximo [`MAX_BLOCK_SYMBOLS`] (D6).
    pub block_symbols: u16,
    /// Raiz BLAKE3 do arquivo em claro completo (§7.2).
    pub merkle_root: [u8; MERKLE_ROOT_LEN],
    /// Nome original do arquivo, já cifrado — a cifra em si é
    /// responsabilidade de quem monta o manifesto, não deste módulo.
    pub name_encrypted: Vec<u8>,
}

impl Manifest {
    /// Serializa em CBOR. Erra se os próprios campos violarem um invariante
    /// do protocolo — um manifesto inválido não deveria nem ser produzido
    /// por este lado, então isto é principalmente uma rede de segurança
    /// contra erro de programação em quem monta o `Manifest`.
    pub fn encode(&self) -> Result<Vec<u8>> {
        self.validate()?;

        let value = Value::Map(vec![
            (text(KEY_FILE_ID), Value::Bytes(self.file_id.to_vec())),
            (text(KEY_FILE_SIZE), integer(self.file_size)),
            (text(KEY_SYMBOL_SIZE), integer(self.symbol_size)),
            (text(KEY_SOURCE_BLOCKS), integer(self.source_blocks)),
            (text(KEY_BLOCK_SYMBOLS), integer(self.block_symbols)),
            (
                text(KEY_MERKLE_ROOT),
                Value::Bytes(self.merkle_root.to_vec()),
            ),
            (
                text(KEY_NAME_ENCRYPTED),
                Value::Bytes(self.name_encrypted.clone()),
            ),
            (text(KEY_MIME), Value::Text(MIME_OCTET_STREAM.to_string())),
        ]);

        let mut buf = Vec::new();
        ciborium::into_writer(&value, &mut buf)
            .map_err(|_| Error::Malformed("falha codificando manifesto em CBOR"))?;
        Ok(buf)
    }

    /// Desserializa e valida um manifesto recebido pela rede.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let value: Value = ciborium::from_reader(bytes)
            .map_err(|_| Error::Malformed("manifesto não é CBOR bem formado"))?;
        let map = value
            .into_map()
            .map_err(|_| Error::Malformed("manifesto CBOR não é um mapa"))?;

        let file_id = bytes_field(&map, KEY_FILE_ID)?
            .try_into()
            .map_err(|_| Error::Malformed("file_id não tem 16 bytes"))?;
        let file_size = u64_field(&map, KEY_FILE_SIZE)?;
        let symbol_size: u16 = u64_field(&map, KEY_SYMBOL_SIZE)?
            .try_into()
            .map_err(|_| Error::Malformed("symbol_size estoura u16"))?;
        let source_blocks: u32 = u64_field(&map, KEY_SOURCE_BLOCKS)?
            .try_into()
            .map_err(|_| Error::Malformed("source_blocks estoura u32"))?;
        let block_symbols: u16 = u64_field(&map, KEY_BLOCK_SYMBOLS)?
            .try_into()
            .map_err(|_| Error::Malformed("block_symbols estoura u16"))?;
        let merkle_root = bytes_field(&map, KEY_MERKLE_ROOT)?
            .try_into()
            .map_err(|_| Error::Malformed("merkle_root não tem 32 bytes"))?;
        let name_encrypted = bytes_field(&map, KEY_NAME_ENCRYPTED)?;

        let mime = text_field(&map, KEY_MIME)?;
        if mime != MIME_OCTET_STREAM {
            // §7.1: este campo só existe com um valor possível no fio hoje.
            // Um valor diferente indica um par que fala outra versão do
            // protocolo ou tentando contrabandear metadado fora do corpo
            // cifrado — não é um caso para tolerar silenciosamente.
            return Err(Error::Malformed(
                "mime do manifesto diverge de application/octet-stream",
            ));
        }

        let manifest = Manifest {
            file_id,
            file_size,
            symbol_size,
            source_blocks,
            block_symbols,
            merkle_root,
            name_encrypted,
        };
        manifest.validate()?;
        Ok(manifest)
    }

    /// Invariantes do protocolo que não dependem de nenhum outro dado além
    /// do próprio manifesto.
    fn validate(&self) -> Result<()> {
        if self.block_symbols == 0 || self.block_symbols > MAX_BLOCK_SYMBOLS {
            return Err(Error::Malformed(
                "block_symbols fora do intervalo permitido por D6 (1..=1024)",
            ));
        }

        if self.source_blocks > MAX_SOURCE_BLOCKS {
            // Checado antes de qualquer outra coisa depender do valor —
            // `source_blocks` dirige diretamente o tamanho do `Vec<bool>`
            // de progresso em `ReceiveTransfer::start` (ver doc da
            // constante). Rejeitar aqui, na borda, é o que impede um
            // manifesto malicioso de forçar uma alocação de gigabytes só
            // por ter sido recebido.
            return Err(Error::Malformed(
                "source_blocks acima do teto de sanidade — arquivo declarado grande demais",
            ));
        }

        let symbol_size_u64 = self.symbol_size as u64;
        let valid_symbol_size = [Transport::DataChannel, Transport::LocalSocket]
            .into_iter()
            .any(|t| t.max_bucket() as u64 == symbol_size_u64);
        if !valid_symbol_size {
            return Err(Error::Malformed(
                "symbol_size não corresponde a nenhum bucket de transporte conhecido",
            ));
        }

        // Recomputa quantos source blocks o par (file_size, symbol_size,
        // block_symbols) implica, e rejeita se o manifesto anunciar outra
        // coisa — um `source_blocks` inconsistente confundiria o resto do
        // pipeline (fountain/staging) de um jeito bem mais difícil de
        // depurar do que rejeitar aqui, na borda.
        let block_bytes = symbol_size_u64
            .checked_mul(self.block_symbols as u64)
            .ok_or(Error::Malformed(
                "overflow calculando bytes por source block",
            ))?;
        let expected_blocks = if self.file_size == 0 {
            0
        } else {
            self.file_size.div_ceil(block_bytes)
        };
        if expected_blocks != self.source_blocks as u64 {
            return Err(Error::Malformed(
                "source_blocks não corresponde a file_size/symbol_size/block_symbols",
            ));
        }

        Ok(())
    }
}

/// Cifra o nome original do arquivo para o campo `name_encrypted` (§7.1),
/// sob `K_name` (derivada de `transfer_secret`+`file_id`, D15) —
/// `aead::seal_xchacha`, nonce aleatório prefixado ao resultado.
pub fn encrypt_name(
    transfer_secret: &[u8],
    file_id: &[u8; FILE_ID_LEN],
    name: &str,
) -> Result<Vec<u8>> {
    let key = crate::file::keys::derive_name_key(transfer_secret, file_id);
    let mut buffer = name.as_bytes().to_vec();
    crate::crypto::aead::seal_xchacha(&key, file_id, &mut buffer)?;
    Ok(buffer)
}

/// Decifra `name_encrypted` de volta ao nome original.
pub fn decrypt_name(
    transfer_secret: &[u8],
    file_id: &[u8; FILE_ID_LEN],
    encrypted: &[u8],
) -> Result<String> {
    let key = crate::file::keys::derive_name_key(transfer_secret, file_id);
    let mut buffer = encrypted.to_vec();
    crate::crypto::aead::open_xchacha(&key, file_id, &mut buffer)?;
    String::from_utf8(buffer).map_err(|_| Error::Malformed("nome decifrado não é UTF-8 válido"))
}

fn text(s: &str) -> Value {
    Value::Text(s.to_string())
}

fn integer(n: impl Into<Integer>) -> Value {
    Value::Integer(n.into())
}

fn lookup<'a>(map: &'a [(Value, Value)], key: &str) -> Result<&'a Value> {
    map.iter()
        .find(|(k, _)| k.as_text() == Some(key))
        .map(|(_, v)| v)
        .ok_or(Error::Malformed("campo obrigatório ausente no manifesto"))
}

fn bytes_field(map: &[(Value, Value)], key: &str) -> Result<Vec<u8>> {
    lookup(map, key)?
        .as_bytes()
        .cloned()
        .ok_or(Error::Malformed("campo do manifesto não é um byte string"))
}

fn text_field(map: &[(Value, Value)], key: &str) -> Result<String> {
    lookup(map, key)?
        .as_text()
        .map(str::to_string)
        .ok_or(Error::Malformed("campo do manifesto não é texto"))
}

fn u64_field(map: &[(Value, Value)], key: &str) -> Result<u64> {
    lookup(map, key)?
        .as_integer()
        .and_then(|i| i.try_into().ok())
        .ok_or(Error::Malformed(
            "campo do manifesto não é um inteiro não negativo válido",
        ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn encrypt_name_roundtrip() {
        let secret = b"segredo-de-transferencia";
        let file_id = [3u8; FILE_ID_LEN];
        let encrypted = encrypt_name(secret, &file_id, "relatorio-final.pdf").unwrap();
        assert_ne!(encrypted, b"relatorio-final.pdf");

        let decrypted = decrypt_name(secret, &file_id, &encrypted).unwrap();
        assert_eq!(decrypted, "relatorio-final.pdf");
    }

    #[test]
    fn decrypt_name_with_wrong_secret_fails() {
        let file_id = [4u8; FILE_ID_LEN];
        let encrypted = encrypt_name(b"segredo-certo", &file_id, "nome.txt").unwrap();
        assert!(matches!(
            decrypt_name(b"segredo-errado", &file_id, &encrypted),
            Err(Error::AeadFailure)
        ));
    }

    fn amostra() -> Manifest {
        // symbol_size * block_symbols = 65536 bytes por source block; dois
        // blocos completos, sem resto, para o `source_blocks` bater fácil de
        // conferir de cabeça.
        Manifest {
            file_id: [7u8; FILE_ID_LEN],
            file_size: 2 * 65536,
            symbol_size: 16384,
            source_blocks: 2,
            block_symbols: 4,
            merkle_root: [9u8; MERKLE_ROOT_LEN],
            name_encrypted: b"nome-cifrado-de-teste".to_vec(),
        }
    }

    #[test]
    fn roundtrip_preserves_all_fields() {
        let original = amostra();
        let encoded = original.encode().unwrap();
        let decoded = Manifest::decode(&encoded).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn binary_fields_become_cbor_byte_strings_not_integer_arrays() {
        // Um byte string CBOR de 16 bytes começa com o major type 2
        // (0b010) e o comprimento 16 no próprio byte inicial: 0x50. Se
        // `file_id` tivesse virado um array de inteiros (o padrão do
        // `serde` para `[u8; N]` sem crate auxiliar), o encoding seria bem
        // maior e não teria esse byte de assinatura na posição do valor.
        let encoded = amostra().encode().unwrap();
        assert!(
            encoded.windows(2).any(|w| w == [0x50, 7]),
            "esperava encontrar o byte string de 16 bytes de file_id (0x50 seguido do byte 7 repetido)"
        );
    }

    #[test]
    fn decode_rejects_mime_different_from_fixed() {
        let mut manifesto = amostra();
        // Contorna `encode()` para forjar um mime diferente — `encode` nunca
        // produziria isto sozinho, então o teste precisa montar o CBOR à mão.
        let value = Value::Map(vec![
            (text(KEY_FILE_ID), Value::Bytes(manifesto.file_id.to_vec())),
            (text(KEY_FILE_SIZE), integer(manifesto.file_size)),
            (text(KEY_SYMBOL_SIZE), integer(manifesto.symbol_size)),
            (text(KEY_SOURCE_BLOCKS), integer(manifesto.source_blocks)),
            (text(KEY_BLOCK_SYMBOLS), integer(manifesto.block_symbols)),
            (
                text(KEY_MERKLE_ROOT),
                Value::Bytes(manifesto.merkle_root.to_vec()),
            ),
            (
                text(KEY_NAME_ENCRYPTED),
                Value::Bytes(std::mem::take(&mut manifesto.name_encrypted)),
            ),
            (text(KEY_MIME), Value::Text("text/plain".to_string())),
        ]);
        let mut bytes = Vec::new();
        ciborium::into_writer(&value, &mut bytes).unwrap();

        assert!(matches!(
            Manifest::decode(&bytes),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn decode_rejects_block_symbols_zero_or_above_d6_ceiling() {
        // `validate` checa `block_symbols` antes de checar a consistência de
        // `source_blocks` — então o valor de `source_blocks` no CBOR
        // adulterado é irrelevante aqui, mesmo deixando o da amostra válida
        // (que não bate mais com o `block_symbols` trocado).
        for invalido in [0u16, MAX_BLOCK_SYMBOLS + 1, u16::MAX] {
            let encoded_valido = amostra().encode().unwrap();
            let mut value: Value = ciborium::from_reader(&encoded_valido[..]).unwrap();
            if let Value::Map(entries) = &mut value {
                for (k, v) in entries.iter_mut() {
                    if k.as_text() == Some(KEY_BLOCK_SYMBOLS) {
                        *v = integer(invalido);
                    }
                }
            }
            let mut bytes = Vec::new();
            ciborium::into_writer(&value, &mut bytes).unwrap();

            assert!(
                matches!(Manifest::decode(&bytes), Err(Error::Malformed(_))),
                "block_symbols={invalido} deveria ser rejeitado"
            );
        }
    }

    #[test]
    fn decode_rejects_symbol_size_outside_known_buckets() {
        let encoded_valido = amostra().encode().unwrap();
        let mut value: Value = ciborium::from_reader(&encoded_valido[..]).unwrap();
        if let Value::Map(entries) = &mut value {
            for (k, v) in entries.iter_mut() {
                if k.as_text() == Some(KEY_SYMBOL_SIZE) {
                    *v = integer(12345u16);
                }
            }
        }
        let mut bytes = Vec::new();
        ciborium::into_writer(&value, &mut bytes).unwrap();

        assert!(matches!(
            Manifest::decode(&bytes),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn decode_rejects_inconsistent_source_blocks() {
        let mut manifesto = amostra();
        manifesto.source_blocks += 1; // não bate mais com file_size/symbol_size/block_symbols.
        let encoded_valido = amostra().encode().unwrap();
        let mut value: Value = ciborium::from_reader(&encoded_valido[..]).unwrap();
        if let Value::Map(entries) = &mut value {
            for (k, v) in entries.iter_mut() {
                if k.as_text() == Some(KEY_SOURCE_BLOCKS) {
                    *v = integer(manifesto.source_blocks);
                }
            }
        }
        let mut bytes = Vec::new();
        ciborium::into_writer(&value, &mut bytes).unwrap();

        assert!(matches!(
            Manifest::decode(&bytes),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn decode_rejects_file_id_with_wrong_size() {
        let value = Value::Map(vec![
            (text(KEY_FILE_ID), Value::Bytes(vec![1u8; 15])),
            (text(KEY_FILE_SIZE), integer(0u64)),
            (text(KEY_SYMBOL_SIZE), integer(16384u16)),
            (text(KEY_SOURCE_BLOCKS), integer(0u32)),
            (text(KEY_BLOCK_SYMBOLS), integer(4u16)),
            (text(KEY_MERKLE_ROOT), Value::Bytes(vec![0u8; 32])),
            (text(KEY_NAME_ENCRYPTED), Value::Bytes(vec![])),
            (text(KEY_MIME), Value::Text(MIME_OCTET_STREAM.to_string())),
        ]);
        let mut bytes = Vec::new();
        ciborium::into_writer(&value, &mut bytes).unwrap();

        assert!(matches!(
            Manifest::decode(&bytes),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn decode_rejects_missing_mandatory_field() {
        let value = Value::Map(vec![
            (text(KEY_FILE_ID), Value::Bytes(vec![1u8; FILE_ID_LEN])),
            (text(KEY_FILE_SIZE), integer(0u64)),
            // symbol_size ausente de propósito.
            (text(KEY_SOURCE_BLOCKS), integer(0u32)),
            (text(KEY_BLOCK_SYMBOLS), integer(4u16)),
            (text(KEY_MERKLE_ROOT), Value::Bytes(vec![0u8; 32])),
            (text(KEY_NAME_ENCRYPTED), Value::Bytes(vec![])),
            (text(KEY_MIME), Value::Text(MIME_OCTET_STREAM.to_string())),
        ]);
        let mut bytes = Vec::new();
        ciborium::into_writer(&value, &mut bytes).unwrap();

        assert!(matches!(
            Manifest::decode(&bytes),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn encode_rejects_invalid_block_symbols_before_serializing() {
        let mut manifesto = amostra();
        manifesto.block_symbols = 0;
        assert!(matches!(manifesto.encode(), Err(Error::Malformed(_))));

        manifesto.block_symbols = MAX_BLOCK_SYMBOLS + 1;
        assert!(matches!(manifesto.encode(), Err(Error::Malformed(_))));
    }

    #[test]
    fn encode_rejects_source_blocks_above_sanity_ceiling() {
        let mut manifesto = amostra();
        manifesto.source_blocks = MAX_SOURCE_BLOCKS + 1;
        assert!(matches!(manifesto.encode(), Err(Error::Malformed(_))));
    }

    #[test]
    fn decode_rejects_source_blocks_above_sanity_ceiling() {
        // Prova a defesa contra o vetor real: um manifesto declarando um
        // `source_blocks` na casa dos bilhões (o que faria
        // `ReceiveTransfer::start` alocar um `Vec<bool>` de gigabytes) é
        // rejeitado na borda, antes de qualquer alocação proporcional ao
        // valor declarado.
        let encoded_valido = amostra().encode().unwrap();
        let mut value: Value = ciborium::from_reader(&encoded_valido[..]).unwrap();
        if let Value::Map(entries) = &mut value {
            for (k, v) in entries.iter_mut() {
                if k.as_text() == Some(KEY_SOURCE_BLOCKS) {
                    *v = integer(u32::MAX);
                }
            }
        }
        let mut bytes = Vec::new();
        ciborium::into_writer(&value, &mut bytes).unwrap();

        assert!(matches!(
            Manifest::decode(&bytes),
            Err(Error::Malformed(_))
        ));
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(256))]

        /// O teste mais importante do módulo: `decode` processa bytes vindos
        /// de um par em potencial mal-intencionado. Para qualquer entrada, o
        /// resultado é sempre `Ok` ou `Err` — nunca panic.
        #[test]
        fn decode_never_panics(bytes in proptest::collection::vec(any::<u8>(), 0..=4096)) {
            let _ = Manifest::decode(&bytes);
        }

        /// Mesma propriedade, especializada em adulterar um manifesto que
        /// começou válido — mais provável de passar da checagem de "é CBOR
        /// bem formado" e exercitar as validações de campo.
        #[test]
        fn decode_never_panics_from_tampered_valid_manifest(
            indices_e_bits in proptest::collection::vec((any::<usize>(), any::<u8>()), 0..=20),
        ) {
            let mut bytes = amostra().encode().unwrap();
            for (idx, bit) in indices_e_bits {
                if bytes.is_empty() {
                    break;
                }
                let i = idx % bytes.len();
                bytes[i] ^= 1 << (bit % 8);
            }
            let _ = Manifest::decode(&bytes);
        }
    }
}
