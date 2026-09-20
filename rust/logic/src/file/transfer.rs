//! Camada de transferência de arquivo — `docs/protocol.md` §7.3/§7.4.
//!
//! Cola manifesto, Merkle, RaptorQ e staging num estado por transferência.
//! `session::Session` não despacha por `PacketType` (achado do relatório da
//! Fase 4: `encrypt_outgoing`/`decrypt_incoming` são agnósticos ao tipo) —
//! é este módulo, chamado de fora da sessão, que decide o que fazer com o
//! corpo já decifrado de um `FILE_FEEDBACK`/`FILE_COMPLETE`. `session`
//! continua sem saber nada sobre arquivos.
//!
//! ## `FILE_SYMBOL` contorna `session::Session` inteiramente
//!
//! Confirmado com o usuário: ao contrário de `FILE_METADATA`/`FILE_FEEDBACK`/
//! `FILE_COMPLETE` (baixo volume, vão pelo canal `control` via `Session`,
//! igual `MSG_TEXT`), cada `FILE_SYMBOL` é selado com `aead::seal_xchacha`
//! sob `K_symbol` (`file::keys::derive_symbol_key`, D15) e mandado direto no
//! canal `file` do WebRTC — nunca passa pelo envelope do ratchet. Mesmo
//! padrão de `signaling::payload` (chave própria fora da sessão): o volume
//! de símbolos por transferência estressaria o teto de chaves puladas do
//! ratchet (§5.5, 1000 — perto o bastante do teto de 1.024 símbolos por
//! bloco de D6 para não ser coincidência a evitar), e um símbolo precisa
//! seguir decifrável mesmo depois de a sessão ser reaberta (retomada após
//! queda de conexão, D6/D9) — o que a cadeia sequencial do ratchet, por
//! desenho, não garante.
//!
//! [`SendTransfer::next_sealed_symbol`]/[`ReceiveTransfer::ingest_sealed_symbol`]
//! são os pontos de entrada para quem fala com o canal `file` do WebRTC;
//! [`SendTransfer::next_symbol`]/[`ReceiveTransfer::ingest_symbol`] continuam
//! existindo, sem cifra, para testar a lógica de RaptorQ isoladamente.
//!
//! ## Formatos de fio que `docs/protocol.md` não fixa
//!
//! §6.2 lista `FILE_SYMBOL`, `FILE_FEEDBACK` e `FILE_COMPLETE` como tipos de
//! pacote, mas não define o layout de bytes de nenhum dos três corpos — só
//! `FILE_METADATA`, em CBOR, é especificado por extenso em §7.1. As escolhas
//! abaixo são deste código, relatadas aqui, não decididas em silêncio:
//!
//! - **[`FileSymbol`]**: deslocamento fixo, no padrão de `crypto::pairing`/
//!   `wire::plaintext` — `block_index (u32 BE) ‖ symbol_id (u32 BE) ‖ dados`.
//!   CBOR custaria bytes de mais num pacote que se repete aos milhares por
//!   transferência; deslocamento fixo tem overhead zero além dos campos.
//! - **[`FileFeedback`]**: mesmo padrão —
//!   `file_id (16 B) ‖ block_index (u32 BE) ‖ symbols_received (u32 BE) ‖
//!   bitmap`. O tamanho do bitmap não vai no fio: quem decodifica já sabe
//!   `source_blocks` (é quem montou o manifesto).
//! - **[`FileComplete`]**: só `file_id (16 B)` — confirmação do receptor ao
//!   emissor de que a raiz Merkle completa bateu e o commit atômico (§7.5)
//!   aconteceu. Direção receptor→emissor: é o receptor quem verifica.
//! - **Corpo de `FILE_METADATA`**: `transfer_secret (32 B) ‖ manifest_cbor`.
//!   `transfer_secret` (D15) **não** é gerado por cada lado independente —
//!   isso derivaria chaves diferentes dos dois lados e nada decifraria. É
//!   gerado uma vez pelo emissor e viaja aqui, na frente do manifesto,
//!   protegido pelo envelope normal do ratchet (`FILE_METADATA` vai pelo
//!   canal `control`, via `Session`, como qualquer outra mensagem). Precisa
//!   estar disponível antes até de decodificar o manifesto porque `K_name`
//!   (usada para `name_encrypted`, um campo *dentro* do CBOR) já depende
//!   dele — ver [`encode_metadata_body`]/[`decode_metadata_body`].
//!
//! ## O que fica para depois — não implementado aqui
//!
//! - **Verificação só ao final, não por bloco.** O spike de `file::merkle`
//!   (F0) mostrou que autenticar um bloco no meio do arquivo contra uma
//!   única raiz de 32 B exige dado extra no manifesto — decisão pendente,
//!   não tomada. Este módulo confia no que o RaptorQ decodifica e só
//!   verifica a raiz completa em [`ReceiveTransfer::finish`], antes do
//!   commit atômico (§7.5): mais fraco que "detecta no bloco", mas nunca
//!   grava no destino final sem a raiz bater.
//! - **Controle de taxa é só "parar quando o bloco completa"** — a política
//!   mínima que §7.3 exige. Um token bucket de verdade (ritmo de envio, não
//!   só parar/continuar) fica para quando houver número real de rede para
//!   calibrar; não modelado aqui.
//! - **`transfer_secret` (D15) só vive em RAM** enquanto o valor Rust
//!   existir. Persisti-lo cifrado no banco local para sobreviver a um
//!   reinício do app é responsabilidade de quem constrói `SendTransfer`/
//!   `ReceiveTransfer` (a camada FFI, via `store`), não deste módulo.

use std::collections::HashSet;
use std::io::{Read, Write};
use std::path::Path;

use crate::crypto::aead;
use crate::crypto::kdf::Key;
use crate::file::fountain::{BlockDecoder, BlockEncoder};
use crate::file::keys;
use crate::file::manifest::{Manifest, FILE_ID_LEN};
use crate::file::merkle;
use crate::file::staging::{self, StagingReader, StagingWriter};
use crate::{Error, Result};

const SYMBOL_BLOCK_INDEX_AT: usize = 0;
const SYMBOL_SYMBOL_ID_AT: usize = SYMBOL_BLOCK_INDEX_AT + 4;
const SYMBOL_DATA_AT: usize = SYMBOL_SYMBOL_ID_AT + 4;

/// Corpo de um pacote `FILE_SYMBOL` (0x21).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileSymbol {
    pub block_index: u32,
    pub symbol_id: u32,
    pub data: Vec<u8>,
}

impl FileSymbol {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(SYMBOL_DATA_AT + self.data.len());
        out.extend_from_slice(&self.block_index.to_be_bytes());
        out.extend_from_slice(&self.symbol_id.to_be_bytes());
        out.extend_from_slice(&self.data);
        out
    }

    /// `bytes` vem de um par em potencial mal-intencionado (o AEAD do
    /// envelope já autenticou, mas não garante que o corpo seja um
    /// `FileSymbol` bem formado) — só `get`/`checked_add`, nunca indexação
    /// direta, no espírito de `wire::plaintext::decode`.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let block_index = crate::util::encoding::read_u32(
            bytes
                .get(SYMBOL_BLOCK_INDEX_AT..SYMBOL_SYMBOL_ID_AT)
                .ok_or(Error::Malformed("FILE_SYMBOL curto demais para block_index"))?,
        )
        .expect("fatia de 4 bytes já garantida acima");

        let symbol_id = crate::util::encoding::read_u32(
            bytes
                .get(SYMBOL_SYMBOL_ID_AT..SYMBOL_DATA_AT)
                .ok_or(Error::Malformed("FILE_SYMBOL curto demais para symbol_id"))?,
        )
        .expect("fatia de 4 bytes já garantida acima");

        let data = bytes
            .get(SYMBOL_DATA_AT..)
            .ok_or(Error::Malformed("FILE_SYMBOL sem dados de símbolo"))?
            .to_vec();

        Ok(Self {
            block_index,
            symbol_id,
            data,
        })
    }
}

const FEEDBACK_FILE_ID_AT: usize = 0;
const FEEDBACK_BLOCK_INDEX_AT: usize = FEEDBACK_FILE_ID_AT + FILE_ID_LEN;
const FEEDBACK_SYMBOLS_RECEIVED_AT: usize = FEEDBACK_BLOCK_INDEX_AT + 4;
const FEEDBACK_BITMAP_AT: usize = FEEDBACK_SYMBOLS_RECEIVED_AT + 4;

/// Corpo de um pacote `FILE_FEEDBACK` (0x22) — §7.4.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileFeedback {
    pub file_id: [u8; FILE_ID_LEN],
    /// Bloco que o receptor está processando no momento deste feedback.
    pub block_index: u32,
    /// Símbolos únicos recebidos para `block_index` até agora.
    pub symbols_received: u32,
    /// Um `bool` por source block do manifesto — `true` quando já
    /// reconstruído e gravado no staging.
    pub blocks_completed: Vec<bool>,
}

impl FileFeedback {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(FEEDBACK_BITMAP_AT + self.blocks_completed.len().div_ceil(8));
        out.extend_from_slice(&self.file_id);
        out.extend_from_slice(&self.block_index.to_be_bytes());
        out.extend_from_slice(&self.symbols_received.to_be_bytes());
        out.extend(pack_bitmap(&self.blocks_completed));
        out
    }

    /// `source_blocks` vem de fora (o manifesto que quem decodifica já tem)
    /// — não é transmitido de novo dentro do `FILE_FEEDBACK`.
    pub fn decode(bytes: &[u8], source_blocks: u32) -> Result<Self> {
        let file_id: [u8; FILE_ID_LEN] = bytes
            .get(FEEDBACK_FILE_ID_AT..FEEDBACK_BLOCK_INDEX_AT)
            .ok_or(Error::Malformed("FILE_FEEDBACK curto demais para file_id"))?
            .try_into()
            .expect("fatia do tamanho de FILE_ID_LEN já garantida acima");

        let block_index = crate::util::encoding::read_u32(
            bytes
                .get(FEEDBACK_BLOCK_INDEX_AT..FEEDBACK_SYMBOLS_RECEIVED_AT)
                .ok_or(Error::Malformed("FILE_FEEDBACK curto demais para block_index"))?,
        )
        .expect("fatia de 4 bytes já garantida acima");

        let symbols_received = crate::util::encoding::read_u32(
            bytes
                .get(FEEDBACK_SYMBOLS_RECEIVED_AT..FEEDBACK_BITMAP_AT)
                .ok_or(Error::Malformed(
                    "FILE_FEEDBACK curto demais para symbols_received",
                ))?,
        )
        .expect("fatia de 4 bytes já garantida acima");

        let expected_bitmap_len = (source_blocks as usize).div_ceil(8);
        let bitmap_bytes = bytes
            .get(FEEDBACK_BITMAP_AT..)
            .ok_or(Error::Malformed("FILE_FEEDBACK sem bitmap"))?;
        if bitmap_bytes.len() != expected_bitmap_len {
            return Err(Error::Malformed(
                "bitmap do FILE_FEEDBACK não tem o tamanho esperado para source_blocks",
            ));
        }

        Ok(Self {
            file_id,
            block_index,
            symbols_received,
            blocks_completed: unpack_bitmap(bitmap_bytes, source_blocks as usize),
        })
    }
}

fn pack_bitmap(bits: &[bool]) -> Vec<u8> {
    let mut out = vec![0u8; bits.len().div_ceil(8)];
    for (i, &bit) in bits.iter().enumerate() {
        if bit {
            out[i / 8] |= 1 << (i % 8);
        }
    }
    out
}

fn unpack_bitmap(bytes: &[u8], count: usize) -> Vec<bool> {
    (0..count)
        .map(|i| bytes[i / 8] & (1 << (i % 8)) != 0)
        .collect()
}

/// Corpo de um pacote `FILE_COMPLETE` (0x23) — confirmação do receptor ao
/// emissor de que a raiz Merkle completa bateu e o commit atômico (§7.5)
/// aconteceu.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileComplete {
    pub file_id: [u8; FILE_ID_LEN],
}

impl FileComplete {
    pub fn encode(&self) -> Vec<u8> {
        self.file_id.to_vec()
    }

    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let file_id: [u8; FILE_ID_LEN] = bytes
            .get(..FILE_ID_LEN)
            .ok_or(Error::Malformed("FILE_COMPLETE curto demais para file_id"))?
            .try_into()
            .expect("fatia do tamanho de FILE_ID_LEN já garantida acima");
        Ok(Self { file_id })
    }
}

/// Tamanho de `transfer_secret` (D15) — 32 bytes, o mesmo tamanho de
/// qualquer material de chave no Viska.
pub const TRANSFER_SECRET_LEN: usize = 32;

/// Monta o corpo de `FILE_METADATA`: `transfer_secret ‖ manifest_cbor`.
/// Chamado pelo emissor, que é quem gera `transfer_secret` (D15) — nunca o
/// receptor, que só o lê daqui.
pub fn encode_metadata_body(
    transfer_secret: &[u8; TRANSFER_SECRET_LEN],
    manifest: &Manifest,
) -> Result<Vec<u8>> {
    let mut body = transfer_secret.to_vec();
    body.extend_from_slice(&manifest.encode()?);
    Ok(body)
}

/// Desmonta o corpo de `FILE_METADATA` recebido, devolvendo `transfer_secret`
/// e o [`Manifest`] já validado — nessa ordem, porque decodificar/validar o
/// manifesto não depende do segredo, só decifrar `name_encrypted` depende
/// (responsabilidade de quem chama, via `manifest::decrypt_name`).
pub fn decode_metadata_body(body: &[u8]) -> Result<([u8; TRANSFER_SECRET_LEN], Manifest)> {
    let transfer_secret: [u8; TRANSFER_SECRET_LEN] = body
        .get(..TRANSFER_SECRET_LEN)
        .ok_or(Error::Malformed(
            "FILE_METADATA curto demais para transfer_secret",
        ))?
        .try_into()
        .expect("fatia do tamanho de TRANSFER_SECRET_LEN já garantida acima");

    let manifest_bytes = body
        .get(TRANSFER_SECRET_LEN..)
        .ok_or(Error::Malformed("FILE_METADATA sem manifesto"))?;
    let manifest = Manifest::decode(manifest_bytes)?;

    Ok((transfer_secret, manifest))
}

/// Tamanho, em bytes, do source block em `block_index` — todos iguais a
/// `symbol_size * block_symbols`, exceto o último, que fica com o resto de
/// `file_size`. `Manifest::validate` já garante que essa conta fecha.
fn block_len_at(manifest: &Manifest, block_index: u32) -> usize {
    let block_bytes = manifest.symbol_size as u64 * manifest.block_symbols as u64;
    if block_index as u64 + 1 == manifest.source_blocks as u64 {
        let bytes_before = block_bytes * (manifest.source_blocks as u64 - 1);
        (manifest.file_size - bytes_before) as usize
    } else {
        block_bytes as usize
    }
}

/// Progresso de uma transferência em andamento — devolvido de forma
/// síncrona por cada chamada que avança o estado (decisão confirmada: sem
/// `StreamSink`, ver relatório da Fase 4 e `rust/src/ffi/session.rs`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TransferProgress {
    pub blocks_done: u32,
    pub total_blocks: u32,
    pub bytes_done: u64,
}

impl TransferProgress {
    pub fn is_complete(&self) -> bool {
        self.blocks_done >= self.total_blocks
    }
}

/// Lado emissor de uma transferência — lê o arquivo em blocos, na ordem, e
/// nunca mantém mais de um bloco (`BlockEncoder`) em RAM por vez (D6).
pub struct SendTransfer<R: Read> {
    manifest: Manifest,
    symbol_key: Key,
    file: R,
    current_block_index: u32,
    current_encoder: Option<BlockEncoder>,
    next_repair_symbol_id: u32,
}

impl<R: Read> core::fmt::Debug for SendTransfer<R> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("SendTransfer")
            .field("manifest", &self.manifest)
            .field("current_block_index", &self.current_block_index)
            .finish_non_exhaustive()
    }
}

impl<R: Read> SendTransfer<R> {
    pub fn new(manifest: Manifest, transfer_secret: &[u8], file: R) -> Self {
        let symbol_key = keys::derive_symbol_key(transfer_secret, &manifest.file_id);
        Self {
            manifest,
            symbol_key,
            file,
            current_block_index: 0,
            current_encoder: None,
            next_repair_symbol_id: 0,
        }
    }

    pub fn is_complete(&self) -> bool {
        self.current_block_index >= self.manifest.source_blocks
    }

    /// Progresso do lado emissor — `bytes_done` é aproximado (blocos
    /// completos × tamanho de bloco, sem contar parcial em voo), porque o
    /// emissor não tem um staging para medir de forma exata como o
    /// receptor tem.
    pub fn progress(&self) -> TransferProgress {
        let block_bytes = self.manifest.symbol_size as u64 * self.manifest.block_symbols as u64;
        TransferProgress {
            blocks_done: self.current_block_index,
            total_blocks: self.manifest.source_blocks,
            bytes_done: self.current_block_index as u64 * block_bytes,
        }
    }

    fn ensure_current_encoder(&mut self) -> Result<()> {
        if self.current_encoder.is_some() || self.is_complete() {
            return Ok(());
        }
        let len = block_len_at(&self.manifest, self.current_block_index);
        let mut buf = vec![0u8; len];
        self.file
            .read_exact(&mut buf)
            .map_err(|_| Error::Malformed("falha lendo o arquivo para montar o source block"))?;
        self.current_encoder = Some(BlockEncoder::new(self.manifest.symbol_size, &buf)?);
        self.next_repair_symbol_id = 0;
        Ok(())
    }

    /// Devolve o próximo símbolo a mandar: todos os símbolos-fonte do bloco
    /// corrente (uma vez cada), depois reparo contínuo — até
    /// [`SendTransfer::ingest_feedback`] confirmar o bloco completo, quando
    /// então o próximo bloco assume. `Ok(None)` só depois do último bloco.
    pub fn next_symbol(&mut self) -> Result<Option<FileSymbol>> {
        self.ensure_current_encoder()?;
        let Some(encoder) = &self.current_encoder else {
            return Ok(None);
        };

        let k = encoder.source_symbol_count();
        let data = if self.next_repair_symbol_id < k {
            encoder.source_symbols()[self.next_repair_symbol_id as usize].clone()
        } else {
            let repair_offset = self.next_repair_symbol_id - k;
            encoder
                .repair_symbols(repair_offset, 1)
                .into_iter()
                .next()
                .expect("repair_symbols(_, 1) sempre devolve exatamente um símbolo")
        };

        let symbol = FileSymbol {
            block_index: self.current_block_index,
            symbol_id: self.next_repair_symbol_id,
            data,
        };
        self.next_repair_symbol_id += 1;
        Ok(Some(symbol))
    }

    /// Como [`SendTransfer::next_symbol`], mas já selado com `K_symbol`
    /// (`aead::seal_xchacha`, D11/D15) — o que de fato vai no canal `file`
    /// do WebRTC, sem passar por `session::Session`. `aad` é `file_id`: liga
    /// cada símbolo à transferência, sem depender de nenhum estado de
    /// sessão.
    pub fn next_sealed_symbol(&mut self) -> Result<Option<Vec<u8>>> {
        let Some(symbol) = self.next_symbol()? else {
            return Ok(None);
        };
        let mut buffer = symbol.encode();
        aead::seal_xchacha(&self.symbol_key, &self.manifest.file_id, &mut buffer)?;
        Ok(Some(buffer))
    }

    /// Consome um `FILE_FEEDBACK` recebido: se o bitmap confirma o bloco
    /// corrente do emissor completo, para de gerar reparo para ele e avança
    /// para o próximo. `feedback.block_index` é só informativo (a que bloco
    /// `symbols_received` se refere no receptor) — o bitmap é que decide,
    /// porque no momento em que o receptor manda o feedback ele já pode ter
    /// avançado para o bloco seguinte.
    pub fn ingest_feedback(&mut self, feedback: &FileFeedback) {
        if feedback
            .blocks_completed
            .get(self.current_block_index as usize)
            .copied()
            .unwrap_or(false)
        {
            self.current_encoder = None;
            self.current_block_index += 1;
        }
    }
}

/// Lado receptor de uma transferência — mantém só o `BlockDecoder` do bloco
/// corrente em RAM (D6) e grava cada bloco decodificado no staging (§7.5)
/// assim que reconstruído.
pub struct ReceiveTransfer {
    manifest: Manifest,
    key: Key,
    symbol_key: Key,
    staging: StagingWriter,
    current_block_index: u32,
    current_decoder: BlockDecoder,
    symbols_received_current_block: u32,
    blocks_completed: Vec<bool>,
}

impl core::fmt::Debug for ReceiveTransfer {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("ReceiveTransfer")
            .field("manifest", &self.manifest)
            .field("current_block_index", &self.current_block_index)
            .finish_non_exhaustive()
    }
}

impl ReceiveTransfer {
    /// Inicia o recebimento: deriva `K_staging` (D15) e cria o `.staging`
    /// vazio em `staging_dir`.
    pub fn start(manifest: Manifest, transfer_secret: &[u8], staging_dir: &Path) -> Result<Self> {
        let key = staging::derive_staging_key(transfer_secret, &manifest.file_id);
        let symbol_key = keys::derive_symbol_key(transfer_secret, &manifest.file_id);
        let staging = StagingWriter::create(staging_dir, manifest.file_id, key.clone())?;
        let first_block_len = block_len_at(&manifest, 0);
        let current_decoder = BlockDecoder::new(manifest.symbol_size, first_block_len)?;
        let blocks_completed = vec![false; manifest.source_blocks as usize];

        Ok(Self {
            manifest,
            key,
            symbol_key,
            staging,
            current_block_index: 0,
            current_decoder,
            symbols_received_current_block: 0,
            blocks_completed,
        })
    }

    pub fn progress(&self) -> TransferProgress {
        TransferProgress {
            blocks_done: self.current_block_index,
            total_blocks: self.manifest.source_blocks,
            bytes_done: self.staging.bytes_written(),
        }
    }

    /// Alimenta um símbolo recebido. Símbolos de um bloco que não é o
    /// corrente (repetido de um já completo, ou adiantado demais) são
    /// silenciosamente ignorados — este receptor só processa um bloco por
    /// vez (D6).
    pub fn ingest_symbol(&mut self, symbol: FileSymbol) -> Result<TransferProgress> {
        if symbol.block_index != self.current_block_index {
            return Ok(self.progress());
        }

        match self
            .current_decoder
            .ingest_symbol(symbol.symbol_id, symbol.data)?
        {
            Some(plaintext) => {
                self.staging.write(&plaintext)?;
                self.blocks_completed[self.current_block_index as usize] = true;
                self.current_block_index += 1;
                self.symbols_received_current_block = 0;

                if (self.current_block_index as usize) < self.blocks_completed.len() {
                    let len = block_len_at(&self.manifest, self.current_block_index);
                    self.current_decoder = BlockDecoder::new(self.manifest.symbol_size, len)?;
                }
            }
            None => {
                self.symbols_received_current_block += 1;
            }
        }

        Ok(self.progress())
    }

    /// Abre um símbolo selado (o que de fato chega pelo canal `file` do
    /// WebRTC — ver doc do módulo) com `K_symbol` e alimenta
    /// [`ReceiveTransfer::ingest_symbol`]. Tag inválida, `aad` errado ou
    /// buffer curto demais viram `Error::AeadFailure`, sem distinção — a
    /// mesma política do resto do crate para AEAD.
    pub fn ingest_sealed_symbol(&mut self, sealed: Vec<u8>) -> Result<TransferProgress> {
        let mut buffer = sealed;
        aead::open_xchacha(&self.symbol_key, &self.manifest.file_id, &mut buffer)?;
        let symbol = FileSymbol::decode(&buffer)?;
        self.ingest_symbol(symbol)
    }

    /// Corpo de `FILE_FEEDBACK` para o estado atual — quem chama decide a
    /// cadência (§7.4: ~500 ms) e por qual canal mandar; nada de timer
    /// dentro deste módulo.
    pub fn feedback(&self) -> FileFeedback {
        FileFeedback {
            file_id: self.manifest.file_id,
            block_index: self.current_block_index,
            symbols_received: self.symbols_received_current_block,
            blocks_completed: self.blocks_completed.clone(),
        }
    }

    pub fn is_complete(&self) -> bool {
        self.blocks_completed.iter().all(|&done| done)
    }

    /// Fecha o staging, recomputa a raiz Merkle do arquivo inteiro e só
    /// então decifra para `destination` — nunca ao contrário. Duas
    /// passagens pelo `.staging` (uma só para verificar, outra para
    /// escrever) em vez de manter o arquivo inteiro em RAM. Devolve o
    /// `FileComplete` a mandar de volta ao emissor.
    pub fn finish(self, staging_dir: &Path, mut destination: impl Write) -> Result<FileComplete> {
        if !self.is_complete() {
            return Err(Error::InvalidState(
                "finish chamado antes de todos os blocos completarem",
            ));
        }

        let ReceiveTransfer {
            manifest,
            key,
            staging,
            ..
        } = self;
        staging.finish()?;

        let mut hasher = HashingWriter(blake3::Hasher::new());
        StagingReader::open(staging_dir, manifest.file_id, key.clone(), manifest.file_size)?
            .decrypt_to(&mut hasher)?;
        merkle::verify_root(&hasher.0.finalize(), &manifest.merkle_root)?;

        StagingReader::open(staging_dir, manifest.file_id, key, manifest.file_size)?
            .decrypt_to(&mut destination)?;

        let _ = std::fs::remove_file(staging::staging_path(staging_dir, &manifest.file_id));
        Ok(FileComplete {
            file_id: manifest.file_id,
        })
    }
}

struct HashingWriter(blake3::Hasher);

impl Write for HashingWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.update(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Varre `staging_dir` apagando `.staging` cujo `file_id` não esteja em
/// `active`. Fino invólucro sobre [`staging::sweep_orphaned`] — existe aqui
/// só para quem só conhece `file::transfer` (a FFI, por exemplo) não
/// precisar importar `file::staging` diretamente.
pub fn sweep_orphaned_staging(
    staging_dir: &Path,
    active: &HashSet<[u8; FILE_ID_LEN]>,
) -> Result<()> {
    staging::sweep_orphaned(staging_dir, active)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn manifesto_de_teste(file_size: u64, symbol_size: u16, block_symbols: u16) -> (Manifest, Vec<u8>) {
        let conteudo: Vec<u8> = (0..file_size).map(|i| (i % 253) as u8).collect();
        let root = merkle::merkle_root(Cursor::new(&conteudo)).unwrap();
        let block_bytes = symbol_size as u64 * block_symbols as u64;
        let source_blocks = if file_size == 0 {
            0
        } else {
            file_size.div_ceil(block_bytes)
        } as u32;

        let manifest = Manifest {
            file_id: [42u8; FILE_ID_LEN],
            file_size,
            symbol_size,
            source_blocks,
            block_symbols,
            merkle_root: *root.as_bytes(),
            name_encrypted: b"nome-de-teste-cifrado".to_vec(),
        };
        (manifest, conteudo)
    }

    /// Ida e volta completa: emissor manda todos os símbolos-fonte de cada
    /// bloco, o receptor decodifica direto (sem perda), feedback fecha cada
    /// bloco, e o arquivo final bate byte a byte com o original.
    #[test]
    fn transferencia_completa_sem_perda_de_simbolos() {
        let (manifest, original) = manifesto_de_teste(3 * 4096, 512, 8); // 3 blocos de 4096 B.
        let transfer_secret = b"segredo-de-transferencia-de-teste";
        let staging_dir = tempfile::tempdir().unwrap();

        let mut sender =
            SendTransfer::new(manifest.clone(), transfer_secret, Cursor::new(original.clone()));
        let mut receiver =
            ReceiveTransfer::start(manifest.clone(), transfer_secret, staging_dir.path()).unwrap();

        for _ in 0..1000 {
            if receiver.is_complete() {
                break;
            }
            let symbol = sender.next_symbol().unwrap().expect("sem símbolos restantes antes de completar");
            receiver.ingest_symbol(symbol).unwrap();
            sender.ingest_feedback(&receiver.feedback());
        }
        assert!(receiver.is_complete(), "não completou dentro do limite de iterações — provável bug de laço infinito");
        assert!(sender.is_complete());

        let mut destino = Vec::new();
        let complete = receiver.finish(staging_dir.path(), &mut destino).unwrap();
        assert_eq!(complete.file_id, manifest.file_id);

        assert_eq!(destino, original);
    }

    /// Mesmo cenário do primeiro teste, mas pelos métodos selados
    /// (`next_sealed_symbol`/`ingest_sealed_symbol`) — o caminho que de fato
    /// atravessaria o canal `file` do WebRTC, com `K_symbol` de verdade.
    #[test]
    fn transferencia_completa_por_simbolos_selados() {
        let (manifest, original) = manifesto_de_teste(3 * 4096, 512, 8);
        let transfer_secret = b"segredo-para-simbolos-selados";
        let staging_dir = tempfile::tempdir().unwrap();

        let mut sender =
            SendTransfer::new(manifest.clone(), transfer_secret, Cursor::new(original.clone()));
        let mut receiver =
            ReceiveTransfer::start(manifest.clone(), transfer_secret, staging_dir.path()).unwrap();

        for _ in 0..1000 {
            if receiver.is_complete() {
                break;
            }
            let sealed = sender
                .next_sealed_symbol()
                .unwrap()
                .expect("sem símbolos restantes antes de completar");
            receiver.ingest_sealed_symbol(sealed).unwrap();
            sender.ingest_feedback(&receiver.feedback());
        }
        assert!(receiver.is_complete());

        let mut destino = Vec::new();
        receiver.finish(staging_dir.path(), &mut destino).unwrap();
        assert_eq!(destino, original);
    }

    #[test]
    fn ingest_sealed_symbol_com_segredo_errado_falha() {
        let (manifest, original) = manifesto_de_teste(4096, 512, 8);
        let staging_dir = tempfile::tempdir().unwrap();

        let mut sender =
            SendTransfer::new(manifest.clone(), b"segredo-certo", Cursor::new(original));
        let mut receiver =
            ReceiveTransfer::start(manifest, b"segredo-errado", staging_dir.path()).unwrap();

        let sealed = sender.next_sealed_symbol().unwrap().unwrap();
        assert!(matches!(
            receiver.ingest_sealed_symbol(sealed),
            Err(Error::AeadFailure)
        ));
    }

    #[test]
    fn metadata_body_ida_e_volta() {
        let (manifest, _original) = manifesto_de_teste(2 * 65536, 16384, 4);
        let secret = [42u8; TRANSFER_SECRET_LEN];

        let body = encode_metadata_body(&secret, &manifest).unwrap();
        let (decoded_secret, decoded_manifest) = decode_metadata_body(&body).unwrap();

        assert_eq!(decoded_secret, secret);
        assert_eq!(decoded_manifest, manifest);
    }

    #[test]
    fn metadata_body_rejeita_corpo_curto_demais_sem_panico() {
        assert!(matches!(
            decode_metadata_body(&[0u8; TRANSFER_SECRET_LEN - 1]),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn file_complete_ida_e_volta() {
        let original = FileComplete {
            file_id: [11u8; FILE_ID_LEN],
        };
        let decoded = FileComplete::decode(&original.encode()).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn file_complete_decode_rejeita_corpo_curto_sem_panico() {
        assert!(matches!(
            FileComplete::decode(&[0u8; FILE_ID_LEN - 1]),
            Err(Error::Malformed(_))
        ));
    }

    /// Mesmo cenário, mas descartando símbolos-fonte e completando com
    /// reparo — prova que o RaptorQ (F2) e o resto da camada de
    /// transferência (F4) se encaixam de verdade, não só em isolamento.
    #[test]
    fn transferencia_completa_com_perda_de_simbolos_e_reparo() {
        let (manifest, original) = manifesto_de_teste(2 * 65536 + 1000, 1024, 64); // 2 blocos cheios + resto.
        let transfer_secret = b"outro-segredo-de-transferencia";
        let staging_dir = tempfile::tempdir().unwrap();

        let mut sender =
            SendTransfer::new(manifest.clone(), transfer_secret, Cursor::new(original.clone()));
        let mut receiver =
            ReceiveTransfer::start(manifest.clone(), transfer_secret, staging_dir.path()).unwrap();

        let mut enviados = 0u32;
        for _ in 0..10_000 {
            if receiver.is_complete() {
                break;
            }
            let symbol = sender.next_symbol().unwrap().expect("sem símbolos restantes antes de completar");
            enviados += 1;

            // Descarta 1 em cada 4 símbolos — só os que sobram chegam ao
            // receptor.
            if enviados % 4 != 0 {
                receiver.ingest_symbol(symbol).unwrap();
            }

            let feedback = receiver.feedback();
            sender.ingest_feedback(&feedback);
        }
        assert!(receiver.is_complete(), "não completou dentro do limite de iterações — provável bug de laço infinito");

        let mut destino = Vec::new();
        receiver.finish(staging_dir.path(), &mut destino).unwrap();
        assert_eq!(destino, original);
    }

    #[test]
    fn finish_antes_de_completo_e_rejeitado() {
        let (manifest, _original) = manifesto_de_teste(4096, 512, 8);
        let staging_dir = tempfile::tempdir().unwrap();
        let receiver = ReceiveTransfer::start(manifest, b"segredo", staging_dir.path()).unwrap();

        let mut destino = Vec::new();
        assert!(matches!(
            receiver.finish(staging_dir.path(), &mut destino),
            Err(Error::InvalidState(_))
        ));
    }

    #[test]
    fn ingest_symbol_de_bloco_que_nao_e_o_corrente_e_ignorado() {
        let (manifest, _original) = manifesto_de_teste(2 * 4096, 512, 8);
        let staging_dir = tempfile::tempdir().unwrap();
        let mut receiver =
            ReceiveTransfer::start(manifest, b"segredo", staging_dir.path()).unwrap();

        let progresso_antes = receiver.progress();
        let simbolo_do_bloco_seguinte = FileSymbol {
            block_index: 1,
            symbol_id: 0,
            data: vec![0u8; 512],
        };
        let progresso_depois = receiver.ingest_symbol(simbolo_do_bloco_seguinte).unwrap();
        assert_eq!(progresso_antes, progresso_depois);
    }

    #[test]
    fn file_symbol_ida_e_volta() {
        let original = FileSymbol {
            block_index: 7,
            symbol_id: 99,
            data: b"conteudo do simbolo".to_vec(),
        };
        let encoded = original.encode();
        let decoded = FileSymbol::decode(&encoded).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn file_symbol_decode_aceita_dados_vazios() {
        let original = FileSymbol {
            block_index: 1,
            symbol_id: 2,
            data: vec![],
        };
        let decoded = FileSymbol::decode(&original.encode()).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn file_symbol_decode_rejeita_cabecalho_incompleto_sem_panico() {
        for tamanho in 0..SYMBOL_DATA_AT {
            assert!(matches!(
                FileSymbol::decode(&vec![0u8; tamanho]),
                Err(Error::Malformed(_))
            ));
        }
    }

    #[test]
    fn file_feedback_ida_e_volta() {
        let original = FileFeedback {
            file_id: [3u8; FILE_ID_LEN],
            block_index: 5,
            symbols_received: 12,
            blocks_completed: vec![true, false, true, true, false, false, true],
        };
        let encoded = original.encode();
        let decoded = FileFeedback::decode(&encoded, original.blocks_completed.len() as u32).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn file_feedback_rejeita_bitmap_de_tamanho_errado() {
        let feedback = FileFeedback {
            file_id: [1u8; FILE_ID_LEN],
            block_index: 0,
            symbols_received: 0,
            blocks_completed: vec![true; 10],
        };
        let encoded = feedback.encode();
        // Decodifica esperando um número de blocos diferente do usado para
        // codificar — o bitmap não bate mais de tamanho.
        assert!(matches!(
            FileFeedback::decode(&encoded, 20),
            Err(Error::Malformed(_))
        ));
    }

    proptest::proptest! {
        #[test]
        fn file_symbol_decode_nunca_entra_em_panico(bytes in proptest::collection::vec(proptest::prelude::any::<u8>(), 0..=2048)) {
            let _ = FileSymbol::decode(&bytes);
        }

        #[test]
        fn file_feedback_decode_nunca_entra_em_panico(
            bytes in proptest::collection::vec(proptest::prelude::any::<u8>(), 0..=2048),
            source_blocks in 0u32..2048,
        ) {
            let _ = FileFeedback::decode(&bytes, source_blocks);
        }

        #[test]
        fn file_complete_decode_nunca_entra_em_panico(bytes in proptest::collection::vec(proptest::prelude::any::<u8>(), 0..=64)) {
            let _ = FileComplete::decode(&bytes);
        }

        #[test]
        fn decode_metadata_body_nunca_entra_em_panico(bytes in proptest::collection::vec(proptest::prelude::any::<u8>(), 0..=4096)) {
            let _ = decode_metadata_body(&bytes);
        }
    }
}
