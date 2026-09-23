//! Superfície FFI de transferência de arquivo e nota de voz — Fase 4 e Fase
//! 5 (D16, D17, D18).
//!
//! `FILE_SYMBOL`/`AUDIO_CHUNK` contornam `session::Session` inteiramente
//! (ver o porquê em `viska_proto::file::transfer`, doc do módulo, confirmado
//! com o usuário) — por isso `next_outgoing_wire_chunk`/
//! `ingest_incoming_wire_bytes` abaixo nunca tocam `self.sessions`.
//! `FILE_METADATA`/`FILE_FEEDBACK`/`FILE_COMPLETE` continuam pelo canal
//! `control`, via `Session`, como `MSG_TEXT` — processados dentro de
//! `Core::decrypt_incoming` (`ffi/session.rs`), não aqui: o dispatch por
//! `packet_type` só pode acontecer depois que o AEAD do envelope já abriu, e
//! `decrypt_incoming` é o único lugar que faz isso. Nota de voz reusa
//! exatamente esses três tipos de controle — a spec não define
//! `AUDIO_METADATA`/`AUDIO_FEEDBACK`/`AUDIO_COMPLETE` (D16); só o `kind`
//! dentro do corpo de `FILE_METADATA` diferencia as duas.
//!
//! ## Várias transferências concorrentes por contato — D17
//!
//! `ingest_incoming_wire_bytes` recebe o pacote do canal `file` **inteiro**
//! (com o `file_id` em claro na frente, D17) e resolve sozinho para qual
//! `ReceiveTransfer` ele vai — quem chama (o lado Dart) não precisa saber de
//! antemão qual `file_id` está chegando. Isso é o que permite várias
//! transferências (arquivo e/ou áudio) ativas ao mesmo tempo com o mesmo
//! contato; antes de D17, só dava para ter uma por vez, porque nada no
//! pacote selado se auto-identificava.
//!
//! Os métodos `..._file`/`..._audio` de início/oferta continuam pares finos
//! em cima de helpers privados parametrizados por `TransferKind` — o estado
//! (`SendTransfer`/`ReceiveTransfer`, RaptorQ, staging, Merkle) é idêntico
//! para os dois; só a chave de símbolo (`K_symbol` vs. `K_audio_chunk`) e o
//! nome do método na fronteira FFI mudam.
//!
//! Sem `StreamSink`: mesma filosofia síncrona de `ffi/session.rs`. Quem
//! dirige o laço de envio/recebimento é o lado Dart.
//!
//! ## Timeline única (Fase 5) — nota de voz é uma `messages` row
//!
//! Decisão do usuário: nota de voz e mensagem de texto compartilham a mesma
//! lista cronológica (`Core::list_messages`), não duas telas separadas.
//! `start_send_audio` insere a linha `Pending` (mesmo padrão de
//! `seal_outgoing_text`); `handle_incoming_file_metadata` insere a `Delivered`
//! assim que a oferta chega, antes mesmo do primeiro `AUDIO_CHUNK` — a UI
//! decide como renderizar "ainda recebendo" olhando se o `file_id` já tem
//! conteúdo pronto, não pelo `delivery_state` (esse continua sendo só sobre
//! entrega ao transporte, como para texto). O corpo dessas linhas é
//! `hex(file_id)`, nunca texto de verdade — convenção só deste módulo e de
//! `ffi/session.rs::message_dto`, que é quem decodifica de volta.
//!
//! ## O que não está aqui — relatado, não decidido em silêncio
//!
//! - **Sem fluxo de aceitar/recusar oferta**, arquivo ou áudio — decisão do
//!   usuário: manter automático por ora, mesmo comportamento de sempre.
//! - **`block_symbols` sempre no teto de D6 (1024), `symbol_size` só
//!   `use_lan: bool`.** Nenhum ajuste fino exposto.
//! - **Controle de taxa de envio é só o que `SendTransfer` já faz**
//!   (parar quando o bloco completa) — nenhum ritmo/pacing aqui.
//! - **Sanitização do Opus (extração via `file::opus_container`) não é
//!   feita aqui.** `start_send_audio` espera receber o caminho de um
//!   arquivo que já esteja no formato interno de `RawOpusStream::encode`
//!   (Fase 5, F1) — a chamada que desmonta o Ogg original do gravador é
//!   outro método FFI, deliberadamente separado para poder ser testado (e
//!   falhar) de forma independente do envio.

use std::collections::HashSet;
use std::fs::File;
use std::path::Path;

use crate::ffi::core::Core;
use crate::ffi::error::FfiError;
use crate::ffi::types::{
    FileOfferDto, IngestedChunkDto, SendAudioStartedDto, SendFileStartedDto, TransferProgressDto,
};
use viska_proto::crypto::identity::DEVICE_ID_LEN;
use viska_proto::file::manifest::{self, Manifest, FILE_ID_LEN, MAX_BLOCK_SYMBOLS};
use viska_proto::file::merkle;
use viska_proto::file::transfer::{
    self, FileFeedback, ReceiveTransfer, SendTransfer, TransferKind, TransferProgress,
    TRANSFER_SECRET_LEN,
};
use viska_proto::store::transfers::Direction;
use viska_proto::wire::packet_type::PacketType;
use viska_proto::wire::transport::Transport;

/// Um lado (emissor ou receptor) de uma transferência em memória, indexado
/// por `file_id` em `Core::transfers`.
pub(super) enum TransferHandle {
    Send(SendTransfer<File>),
    Receive(ReceiveTransfer),
}

/// Resultado interno de [`Core::start_send`] — `start_send_file`/
/// `start_send_audio` cada um decide sozinho como virar isto num DTO
/// público (só `start_send_audio` precisa inserir uma linha na timeline
/// única antes de responder).
struct StartedTransfer {
    file_id: [u8; FILE_ID_LEN],
    sealed_metadata: Vec<u8>,
}

fn to_device_id(bytes: Vec<u8>) -> Result<[u8; DEVICE_ID_LEN], FfiError> {
    bytes.try_into().map_err(|_| FfiError::Internal)
}

fn to_file_id(bytes: Vec<u8>) -> Result<[u8; FILE_ID_LEN], FfiError> {
    bytes.try_into().map_err(|_| FfiError::Internal)
}

fn progress_dto(progress: TransferProgress) -> TransferProgressDto {
    TransferProgressDto {
        blocks_done: progress.blocks_done,
        total_blocks: progress.total_blocks,
        bytes_done: progress.bytes_done,
        is_complete: progress.is_complete(),
    }
}

impl Core {
    /// Inicia o envio de um arquivo para um contato pareado com sessão já
    /// estabelecida. Lê o arquivo inteiro uma vez para calcular a raiz de
    /// Merkle (§7.2) — não tem como evitar essa leitura, o manifesto
    /// precisa da raiz completa antes do primeiro símbolo sair.
    ///
    /// `use_lan` escolhe `symbol_size`: 65536 (LocalSocket) ou 16384
    /// (DataChannel) — a mesma distinção de `wire::transport::Transport`.
    /// `block_symbols` é sempre o teto de D6 (1024).
    pub fn start_send_file(
        &self,
        peer_device_id: Vec<u8>,
        file_path: String,
        use_lan: bool,
    ) -> Result<SendFileStartedDto, FfiError> {
        let device_id = to_device_id(peer_device_id.clone())?;

        // Extrai o nome do arquivo para usar como corpo da mensagem na timeline
        // — o mesmo `name` que vai cifrado no manifesto, mas aqui em claro
        // para exibição local. Não é segredo: o receptor também verá.
        let file_name = Path::new(&file_path)
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or(FfiError::Internal)?
            .to_owned();

        let started = self.start_send(peer_device_id, file_path, use_lan, TransferKind::File)?;

        let created_at = viska_proto::util::time::unix_seconds() as i64;
        let message_id = self.store.insert_pending_message(
            &device_id,
            PacketType::FileMetadata,
            &file_name,
            created_at,
        )?;

        Ok(SendFileStartedDto {
            file_id: started.file_id.to_vec(),
            sealed_metadata: started.sealed_metadata,
            message_id,
        })
    }

    /// Como [`Core::start_send_file`], mas para uma nota de voz — `kind =
    /// Audio` (Fase 5, D16) seleciona `K_audio_chunk` em vez de `K_symbol`.
    /// `audio_path` deve apontar para um arquivo já no formato interno de
    /// `viska_proto::file::opus_container::RawOpusStream::encode` (ver
    /// `Core::sanitize_and_stage_audio`) — nunca o Ogg cru que o gravador
    /// produziu, que ainda carregaria `OpusTags` com metadados de
    /// aparelho. Também insere a linha `Pending` na timeline única
    /// (`store::messages`) — `message_id` no DTO devolvido é para quem
    /// chama marcar `Sent` depois (`Core::mark_message_sent`), mesmo padrão
    /// de `seal_outgoing_text`.
    pub fn start_send_audio(
        &self,
        peer_device_id: Vec<u8>,
        audio_path: String,
        use_lan: bool,
    ) -> Result<SendAudioStartedDto, FfiError> {
        let device_id = to_device_id(peer_device_id.clone())?;
        let started = self.start_send(peer_device_id, audio_path, use_lan, TransferKind::Audio)?;

        let created_at = viska_proto::util::time::unix_seconds() as i64;
        let message_id = self.store.insert_pending_message(
            &device_id,
            PacketType::AudioChunk,
            &hex::encode(started.file_id),
            created_at,
        )?;

        Ok(SendAudioStartedDto {
            file_id: started.file_id.to_vec(),
            sealed_metadata: started.sealed_metadata,
            message_id,
        })
    }

    fn start_send(
        &self,
        peer_device_id: Vec<u8>,
        file_path: String,
        use_lan: bool,
        kind: TransferKind,
    ) -> Result<StartedTransfer, FfiError> {
        let device_id = to_device_id(peer_device_id)?;

        let file_size = std::fs::metadata(&file_path)
            .map_err(|_| FfiError::Internal)?
            .len();
        let symbol_size: u16 = if use_lan {
            Transport::LocalSocket.max_bucket() as u16
        } else {
            Transport::DataChannel.max_bucket() as u16
        };
        let block_symbols = MAX_BLOCK_SYMBOLS;
        let block_bytes = symbol_size as u64 * block_symbols as u64;
        let source_blocks: u32 = if file_size == 0 {
            0
        } else {
            file_size.div_ceil(block_bytes) as u32
        };

        let file_id: [u8; FILE_ID_LEN] = viska_proto::util::rng::array::<FILE_ID_LEN>()?;
        let transfer_secret: [u8; TRANSFER_SECRET_LEN] =
            viska_proto::util::rng::array::<TRANSFER_SECRET_LEN>()?;

        let merkle_root: [u8; 32] = {
            let file = File::open(&file_path).map_err(|_| FfiError::Internal)?;
            *merkle::merkle_root(file)?.as_bytes()
        };

        let name = Path::new(&file_path)
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or(FfiError::Internal)?;
        let name_encrypted = manifest::encrypt_name(&transfer_secret, &file_id, name)?;

        let manifest = Manifest {
            file_id,
            file_size,
            symbol_size,
            source_blocks,
            block_symbols,
            merkle_root,
            name_encrypted,
        };

        let sealed_metadata = {
            let mut sessions = self.lock_sessions()?;
            let session = sessions
                .get_mut(&device_id)
                .ok_or(FfiError::NoActiveSession)?;
            if !session.is_established() {
                return Err(FfiError::NoActiveSession);
            }
            let body = transfer::encode_metadata_body(kind, &transfer_secret, &manifest)?;
            session.encrypt_outgoing(PacketType::FileMetadata, body, Transport::DataChannel)?
        };

        let file = File::open(&file_path).map_err(|_| FfiError::Internal)?;
        let send = SendTransfer::new(manifest.clone(), kind, &transfer_secret, file);

        let manifest_cbor = manifest.encode()?;
        let created_at = viska_proto::util::time::unix_seconds() as i64;
        self.store.insert_file_transfer(
            &file_id,
            Direction::Sending,
            &device_id,
            &manifest_cbor,
            &transfer_secret,
            created_at,
            kind,
        )?;

        self.lock_transfers()?
            .insert(file_id, TransferHandle::Send(send));

        Ok(StartedTransfer {
            file_id,
            sealed_metadata,
        })
    }

    /// Próximo pacote a mandar no canal `file` do WebRTC — já selado com
    /// `K_symbol`/`K_audio_chunk` e prefixado com `file_id` em claro (D17,
    /// contorna `Session`, ver doc do módulo). `Ok(None)` quando o
    /// `file_id` não é uma transferência de envio conhecida (já terminou,
    /// ou nunca existiu) ou quando o emissor esgotou o que tinha a mandar
    /// para o estado atual. Serve arquivo e áudio por igual — nada aqui
    /// depende de `kind`.
    pub fn next_outgoing_wire_chunk(&self, file_id: Vec<u8>) -> Result<Option<Vec<u8>>, FfiError> {
        let file_id = to_file_id(file_id)?;
        let mut transfers = self.lock_transfers()?;
        match transfers.get_mut(&file_id) {
            Some(TransferHandle::Send(send)) => Ok(send.next_sealed_symbol()?),
            _ => Ok(None),
        }
    }

    /// Progresso de uma transferência conhecida, de qualquer lado (arquivo
    /// ou áudio) — `None` se `file_id` não corresponde a nada em andamento.
    pub fn transfer_progress(&self, file_id: Vec<u8>) -> Result<Option<TransferProgressDto>, FfiError> {
        let file_id = to_file_id(file_id)?;
        let transfers = self.lock_transfers()?;
        Ok(match transfers.get(&file_id) {
            Some(TransferHandle::Send(send)) => Some(progress_dto(send.progress())),
            Some(TransferHandle::Receive(recv)) => Some(progress_dto(recv.progress())),
            None => None,
        })
    }

    /// Ofertas de arquivo recebidas de um contato, ainda não concluídas —
    /// para a UI listar e (por ora, automaticamente — ver doc do módulo)
    /// já em recebimento. Só `kind = File`; ver
    /// [`Core::pending_audio_offers`] para notas de voz.
    pub fn pending_file_offers(&self, peer_device_id: Vec<u8>) -> Result<Vec<FileOfferDto>, FfiError> {
        self.pending_offers(peer_device_id, TransferKind::File)
    }

    /// Como [`Core::pending_file_offers`], só `kind = Audio` (Fase 5, D16).
    pub fn pending_audio_offers(&self, peer_device_id: Vec<u8>) -> Result<Vec<FileOfferDto>, FfiError> {
        self.pending_offers(peer_device_id, TransferKind::Audio)
    }

    fn pending_offers(
        &self,
        peer_device_id: Vec<u8>,
        kind: TransferKind,
    ) -> Result<Vec<FileOfferDto>, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        let stored = self
            .store
            .list_file_transfers_for_contact(&device_id, Direction::Receiving)?;

        let mut offers = Vec::new();
        for entry in stored {
            if entry.kind != kind {
                continue;
            }
            let manifest = Manifest::decode(&entry.manifest_cbor)?;
            let name = manifest::decrypt_name(
                &entry.transfer_secret,
                &manifest.file_id,
                &manifest.name_encrypted,
            )?;
            offers.push(FileOfferDto {
                file_id: entry.file_id.to_vec(),
                name,
                file_size: manifest.file_size,
            });
        }
        Ok(offers)
    }

    /// Alimenta um pacote cru recebido no canal `file` do WebRTC — descobre
    /// sozinho a qual transferência ele pertence (D17: `file_id` vai em
    /// claro na frente, ver `peek_wire_file_id`) e roteia para a
    /// `ReceiveTransfer` certa. `Ok(None)` para um `file_id` desconhecido —
    /// pode ser um pacote de uma transferência já concluída/cancelada, ou
    /// que chegou antes do `FILE_METADATA` correspondente terminar de
    /// processar; nunca um erro, porque nenhum dos dois é sinal de mau uso
    /// de quem chama. Serve arquivo e áudio por igual.
    pub fn ingest_incoming_wire_bytes(
        &self,
        wire_bytes: Vec<u8>,
    ) -> Result<Option<IngestedChunkDto>, FfiError> {
        let file_id = transfer::peek_wire_file_id(&wire_bytes)?;
        let sealed = wire_bytes
            .get(FILE_ID_LEN..)
            .ok_or(FfiError::Internal)?
            .to_vec();

        let mut transfers = self.lock_transfers()?;
        match transfers.get_mut(&file_id) {
            Some(TransferHandle::Receive(recv)) => {
                let progress = progress_dto(recv.ingest_sealed_symbol(sealed)?);
                Ok(Some(IngestedChunkDto {
                    file_id: file_id.to_vec(),
                    progress,
                }))
            }
            _ => Ok(None),
        }
    }

    /// Fecha um recebimento completo: verifica a raiz Merkle inteira,
    /// decifra para `destination_path`, remove o `.staging` e o registro em
    /// `store` (isso é o que torna `K_staging`/`K_symbol` irrecuperáveis,
    /// D15). Devolve o `FILE_COMPLETE` já selado para mandar de volta ao
    /// emissor pelo canal `control`.
    pub fn finish_receive_file(
        &self,
        peer_device_id: Vec<u8>,
        file_id: Vec<u8>,
        destination_path: String,
    ) -> Result<Vec<u8>, FfiError> {
        self.finish_receive(peer_device_id, file_id, destination_path)
    }

    /// Como [`Core::finish_receive_file`] — `destination_path` recebe o
    /// formato interno de `RawOpusStream::encode`, não um Ogg tocável. Quem
    /// chama remonta o contêiner para reprodução (ver
    /// `Core::rebuild_ogg_opus_container`), sem gravar o resultado em disco.
    pub fn finish_receive_audio(
        &self,
        peer_device_id: Vec<u8>,
        file_id: Vec<u8>,
        destination_path: String,
    ) -> Result<Vec<u8>, FfiError> {
        self.finish_receive(peer_device_id, file_id, destination_path)
    }

    fn finish_receive(
        &self,
        peer_device_id: Vec<u8>,
        file_id: Vec<u8>,
        destination_path: String,
    ) -> Result<Vec<u8>, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        let file_id = to_file_id(file_id)?;

        let handle = self
            .lock_transfers()?
            .remove(&file_id)
            .ok_or(FfiError::Internal)?;
        let TransferHandle::Receive(recv) = handle else {
            // Devolve o handle de envio — `finish_receive_*` não é o
            // método certo para ele — em vez de descartá-lo em silêncio.
            self.lock_transfers()?.insert(file_id, handle);
            return Err(FfiError::Internal);
        };

        let destination =
            std::fs::File::create(&destination_path).map_err(|_| FfiError::Internal)?;
        let complete = recv.finish(&self.staging_dir, destination)?;
        self.store.delete_file_transfer(&file_id)?;

        let mut sessions = self.lock_sessions()?;
        let session = sessions
            .get_mut(&device_id)
            .ok_or(FfiError::NoActiveSession)?;
        Ok(session.encrypt_outgoing(
            PacketType::FileComplete,
            complete.encode(),
            Transport::DataChannel,
        )?)
    }

    /// Desmonta um Ogg-Opus gravado por `record` (com `OpusTags` de
    /// metadados) e grava, em `destination_path`, só o formato interno de
    /// `RawOpusStream::encode` — canais, taxa, pre-skip e pacotes crus, sem
    /// nenhum comentário do gravador original (Fase 5, F1, D16). Falha alto
    /// (`Error::Malformed`) em vez de aceitar um Ogg malformado em
    /// silêncio — mesma política do resto do crate para bytes externos.
    pub fn sanitize_and_stage_audio(
        &self,
        source_path: String,
        destination_path: String,
    ) -> Result<(), FfiError> {
        let ogg_bytes = std::fs::read(&source_path).map_err(|_| FfiError::Internal)?;
        let stream = viska_proto::file::opus_container::strip_container(&ogg_bytes)?;
        std::fs::write(&destination_path, stream.encode()).map_err(|_| FfiError::Internal)?;
        Ok(())
    }

    /// Decodifica o formato interno devolvido por
    /// [`Core::finish_receive_audio`] para um WAV tocável — inteiramente em
    /// memória; quem chama nunca deveria gravar o resultado em disco. WAV,
    /// não Ogg-Opus remontado: `AVPlayer` (iOS) não demuxa Ogg de jeito
    /// nenhum, com ou sem suporte a Opus (D18).
    pub fn decode_audio_to_wav(&self, internal_bytes: Vec<u8>) -> Result<Vec<u8>, FfiError> {
        let stream = viska_proto::file::opus_container::RawOpusStream::decode(&internal_bytes)?;
        Ok(viska_proto::file::opus_container::decode_to_wav(&stream)?)
    }

    /// Cancela uma transferência (de qualquer lado): remove o handle em
    /// memória e o registro em `store`. Do lado receptor, também apaga o
    /// `.staging` — mesma garantia de "abortar destrói a chave" de
    /// `StagingWriter::abort`, só que aqui via `sweep_orphaned` na próxima
    /// abertura, já que o handle não guarda o `StagingWriter` bruto (ele já
    /// foi fechado a cada bloco completado). Ver §7.5/D15.
    pub fn cancel_transfer(&self, file_id: Vec<u8>) -> Result<(), FfiError> {
        let file_id = to_file_id(file_id)?;
        self.lock_transfers()?.remove(&file_id);
        self.store.delete_file_transfer(&file_id)?;
        let mut active = HashSet::new();
        for id in self.store.list_active_file_transfer_ids()? {
            active.insert(id);
        }
        viska_proto::file::staging::sweep_orphaned(&self.staging_dir, &active)?;
        Ok(())
    }

    fn lock_transfers(
        &self,
    ) -> Result<std::sync::MutexGuard<'_, std::collections::HashMap<[u8; FILE_ID_LEN], TransferHandle>>, FfiError>
    {
        self.transfers.lock().map_err(|_| FfiError::Internal)
    }

    /// Chamado de dentro de `Core::decrypt_incoming` (`ffi/session.rs`)
    /// quando um `FILE_METADATA` chega — não é público porque só faz
    /// sentido depois que o AEAD do envelope já abriu. `kind` (Fase 5, D16)
    /// decide, aqui, se `ReceiveTransfer::start` deriva `K_symbol` ou
    /// `K_audio_chunk`. Para `kind == Audio`, também insere a linha
    /// `Delivered` na timeline única (`store::messages`) — a nota de voz
    /// aparece na conversa assim que a oferta chega, antes do primeiro
    /// `AUDIO_CHUNK` sequer existir; a UI decide "ainda recebendo" olhando
    /// se o `file_id` já tem conteúdo pronto, não pelo `delivery_state`.
    pub(super) fn handle_incoming_file_metadata(
        &self,
        contact_device_id: [u8; DEVICE_ID_LEN],
        body: Vec<u8>,
    ) -> Result<(), FfiError> {
        let (kind, transfer_secret, manifest) = transfer::decode_metadata_body(&body)?;
        let manifest_cbor = manifest.encode()?;
        let received_at = viska_proto::util::time::unix_seconds() as i64;

        self.store.insert_file_transfer(
            &manifest.file_id,
            Direction::Receiving,
            &contact_device_id,
            &manifest_cbor,
            &transfer_secret,
            received_at,
            kind,
        )?;

        if kind == TransferKind::Audio {
            self.store.insert_incoming_message(
                &contact_device_id,
                PacketType::AudioChunk,
                &hex::encode(manifest.file_id),
                received_at,
            )?;
        }

        let receive = ReceiveTransfer::start(manifest.clone(), kind, &transfer_secret, &self.staging_dir)?;
        self.lock_transfers()?
            .insert(manifest.file_id, TransferHandle::Receive(receive));
        Ok(())
    }

    /// Chamado de dentro de `Core::decrypt_incoming` quando um
    /// `FILE_FEEDBACK` chega — repassa para o `SendTransfer` do `file_id`
    /// indicado, se existir.
    pub(super) fn handle_incoming_file_feedback(&self, body: Vec<u8>) -> Result<(), FfiError> {
        // `source_blocks` vem do próprio manifesto que este lado já
        // persistiu ao iniciar o envio — não do corpo do feedback (§7.4:
        // o tamanho do bitmap não vai no fio).
        let file_id: [u8; FILE_ID_LEN] = body
            .get(..FILE_ID_LEN)
            .ok_or(FfiError::Internal)?
            .try_into()
            .map_err(|_| FfiError::Internal)?;
        let stored = self
            .store
            .find_file_transfer(&file_id)?
            .ok_or(FfiError::Internal)?;
        let manifest = Manifest::decode(&stored.manifest_cbor)?;

        let feedback = FileFeedback::decode(&body, manifest.source_blocks)?;
        if let Some(TransferHandle::Send(send)) = self.lock_transfers()?.get_mut(&file_id) {
            send.ingest_feedback(&feedback);
        }
        Ok(())
    }

    /// Chamado de dentro de `Core::decrypt_incoming` quando um
    /// `FILE_COMPLETE` chega — o receptor confirmou a raiz Merkle e o
    /// commit atômico; o emissor não precisa mais guardar nada desta
    /// transferência.
    pub(super) fn handle_incoming_file_complete(&self, body: Vec<u8>) -> Result<(), FfiError> {
        let complete = transfer::FileComplete::decode(&body)?;
        self.lock_transfers()?.remove(&complete.file_id);
        self.store.delete_file_transfer(&complete.file_id)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::core::Core;
    use crate::ffi::types::{DeliveryStateDto, MessageKindDto};
    use std::io::Write;

    fn open_core(dir: &tempfile::TempDir) -> Core {
        Core::open(dir.path().to_str().unwrap().to_owned()).unwrap()
    }

    /// Duas `Core` pareadas com sessão já estabelecida — mesmo papel de
    /// `establish()` em `ffi/session.rs`, mas próprio deste módulo (padrão
    /// já usado por `ffi/signaling.rs`: cada arquivo de teste monta o par
    /// que precisa, em vez de compartilhar um helper entre arquivos).
    struct EstablishedPair {
        _dir_a: tempfile::TempDir,
        core_a: Core,
        device_id_a: Vec<u8>,
        _dir_b: tempfile::TempDir,
        core_b: Core,
        device_id_b: Vec<u8>,
    }

    fn established_pair() -> EstablishedPair {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let core_a = open_core(&dir_a);
        let core_b = open_core(&dir_b);
        let contact_a_seen_by_b = core_b.pair_from_qr(core_a.my_qr_payload(), None).unwrap();
        let contact_b_seen_by_a = core_a.pair_from_qr(core_b.my_qr_payload(), None).unwrap();

        let mut pair = EstablishedPair {
            _dir_a: dir_a,
            core_a,
            device_id_a: contact_a_seen_by_b.device_id,
            _dir_b: dir_b,
            core_b,
            device_id_b: contact_b_seen_by_a.device_id,
        };

        if !pair
            .core_a
            .identity
            .read()
            .unwrap()
            .public()
            .is_before(&pair.core_b.identity.read().unwrap().public())
        {
            std::mem::swap(&mut pair.core_a, &mut pair.core_b);
            std::mem::swap(&mut pair.device_id_a, &mut pair.device_id_b);
            std::mem::swap(&mut pair._dir_a, &mut pair._dir_b);
        }

        let status_a = pair.core_a.ensure_session(pair.device_id_b.clone()).unwrap();
        pair.core_b.ensure_session(pair.device_id_a.clone()).unwrap();
        let init = status_a.outgoing_handshake.expect("core_a é sempre iniciadora");
        let resp = pair
            .core_b
            .feed_handshake(pair.device_id_a.clone(), init)
            .unwrap()
            .expect("respondedor sempre devolve a RESP");
        let none = pair
            .core_a
            .feed_handshake(pair.device_id_b.clone(), resp)
            .unwrap();
        assert!(none.is_none());

        pair
    }

    fn fid(bytes: &[u8]) -> [u8; FILE_ID_LEN] {
        bytes.try_into().unwrap()
    }

    fn did(bytes: &[u8]) -> [u8; DEVICE_ID_LEN] {
        bytes.try_into().unwrap()
    }

    fn write_temp_file(dir: &tempfile::TempDir, name: &str, content: &[u8]) -> String {
        let path = dir.path().join(name);
        std::fs::File::create(&path)
            .unwrap()
            .write_all(content)
            .unwrap();
        path.to_str().unwrap().to_owned()
    }

    #[test]
    fn start_send_file_without_established_session_fails() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_src = tempfile::tempdir().unwrap();
        let core_a = open_core(&dir_a);
        let path = write_temp_file(&dir_src, "arquivo.bin", b"conteudo");

        assert_eq!(
            core_a.start_send_file(vec![0u8; 16], path, false),
            Err(FfiError::NoActiveSession)
        );
    }

    /// Ida e volta completa pela fronteira FFI: A manda um arquivo pequeno
    /// para B, os dois lados trocam FILE_METADATA/FILE_SYMBOL/FILE_FEEDBACK/
    /// FILE_COMPLETE exatamente como aconteceria com o transporte de
    /// verdade (envelopes/bytes selados passando de um `Core` para o
    /// outro), e o arquivo decifrado em B bate byte a byte com o original.
    #[test]
    fn end_to_end_file_transfer_across_ffi_boundary() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let dir_dst = tempfile::tempdir().unwrap();

        // Pequeno o bastante para poucos blocos, grande o bastante para
        // exercitar mais de um bloco com o teto de D6 reduzido só pelo
        // symbol_size mínimo real (16384) — um arquivo de ~40 KB cabe em um
        // único bloco de 16384*1024, então isto testa o caminho de bloco
        // único; a cobertura multi-bloco já está em
        // `viska_proto::file::transfer` (F4 core).
        let original: Vec<u8> = (0..40_000u32).map(|i| (i % 251) as u8).collect();
        let src_path = write_temp_file(&dir_src, "original.bin", &original);

        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();

        let opened = pair
            .core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();
        assert!(opened.is_none(), "FILE_METADATA nunca produz IncomingMessageDto");

        let offers = pair.core_b.pending_file_offers(pair.device_id_a.clone()).unwrap();
        assert_eq!(offers.len(), 1);
        assert_eq!(offers[0].file_id, started.file_id);
        assert_eq!(offers[0].name, "original.bin");
        assert_eq!(offers[0].file_size, original.len() as u64);

        for _ in 0..10_000 {
            let progress = pair
                .core_b
                .transfer_progress(started.file_id.clone())
                .unwrap();
            if progress.map(|p| p.is_complete).unwrap_or(false) {
                break;
            }
            let Some(wire_chunk) = pair
                .core_a
                .next_outgoing_wire_chunk(started.file_id.clone())
                .unwrap()
            else {
                break;
            };
            pair.core_b
                .ingest_incoming_wire_bytes(wire_chunk)
                .unwrap()
                .expect("file_id vem em claro no próprio pacote — deveria ser reconhecido");

            // Feedback esparso de verdade seria a cada ~500ms; aqui, a cada
            // símbolo, para o teste não depender de tempo real.
            let feedback_body = {
                let transfers = pair.core_b.lock_transfers().unwrap();
                let Some(TransferHandle::Receive(recv)) = transfers.get(&fid(&started.file_id)) else {
                    panic!("receive transfer deveria existir");
                };
                recv.feedback().encode()
            };
            let mut sessions_b = pair.core_b.lock_sessions().unwrap();
            let session_b = sessions_b.get_mut(&did(&pair.device_id_a)).unwrap();
            let sealed_feedback = session_b
                .encrypt_outgoing(
                    viska_proto::wire::packet_type::PacketType::FileFeedback,
                    feedback_body,
                    Transport::DataChannel,
                )
                .unwrap();
            drop(sessions_b);

            pair.core_a
                .decrypt_incoming(pair.device_id_b.clone(), sealed_feedback)
                .unwrap();
        }

        let progress = pair
            .core_b
            .transfer_progress(started.file_id.clone())
            .unwrap()
            .unwrap();
        assert!(progress.is_complete, "transferência não completou dentro do limite de iterações");

        let dst_path = dir_dst.path().join("recebido.bin");
        let sealed_complete = pair
            .core_b
            .finish_receive_file(
                pair.device_id_a.clone(),
                started.file_id.clone(),
                dst_path.to_str().unwrap().to_owned(),
            )
            .unwrap();

        let received = std::fs::read(&dst_path).unwrap();
        assert_eq!(received, original);

        // O emissor ainda não sabe que terminou até processar o
        // FILE_COMPLETE.
        assert!(pair
            .core_a
            .store
            .find_file_transfer(&fid(&started.file_id))
            .unwrap()
            .is_some());

        pair.core_a
            .decrypt_incoming(pair.device_id_b.clone(), sealed_complete)
            .unwrap();

        assert!(pair
            .core_a
            .store
            .find_file_transfer(&fid(&started.file_id))
            .unwrap()
            .is_none());
        assert!(pair
            .core_b
            .store
            .find_file_transfer(&fid(&started.file_id))
            .unwrap()
            .is_none());
    }

    /// Alguns quadros Opus de verdade (não bytes arbitrários) — para que
    /// `decode_audio_to_wav` (D18) tenha algo real para decodificar no fim
    /// do teste ponta-a-ponta.
    fn opus_real_stream(frames: usize) -> viska_proto::file::opus_container::RawOpusStream {
        use audiopus::coder::Encoder;
        use audiopus::{Application, Channels, SampleRate};

        let encoder = Encoder::new(SampleRate::Hz48000, Channels::Mono, Application::Voip).unwrap();
        let frame_samples = 960; // 20 ms a 48 kHz.
        let mut packets = Vec::with_capacity(frames);
        for i in 0..frames {
            let pcm: Vec<i16> = (0..frame_samples)
                .map(|n| (((i * frame_samples + n) as f32 * 0.05).sin() * 4000.0) as i16)
                .collect();
            let mut out = vec![0u8; 4000];
            let len = encoder.encode(&pcm, &mut out).unwrap();
            out.truncate(len);
            packets.push(out);
        }
        viska_proto::file::opus_container::RawOpusStream {
            channels: 1,
            sample_rate: 48000,
            pre_skip: 0,
            packets,
        }
    }

    /// Mesmo cenário do teste de arquivo, mas para uma nota de voz: passa
    /// por `sanitize_and_stage_audio` (F1), atravessa o pipeline com
    /// `start_send_audio`/`next_outgoing_wire_chunk`/
    /// `ingest_incoming_wire_bytes`/`finish_receive_audio`, termina
    /// decodificando para WAV do lado do receptor (D18), e confere que a
    /// nota aparece na timeline única dos dois lados (Fase 5).
    #[test]
    fn end_to_end_voice_note_transfer_across_ffi_boundary() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let dir_dst = tempfile::tempdir().unwrap();

        let original_stream = opus_real_stream(5);
        let gravado_ogg = viska_proto::file::opus_container::rebuild_container(&original_stream);
        let gravado_path = write_temp_file(&dir_src, "gravado.ogg", &gravado_ogg);
        let sanitizado_path = dir_src.path().join("sanitizado.viska-audio").to_str().unwrap().to_owned();

        pair.core_a
            .sanitize_and_stage_audio(gravado_path, sanitizado_path.clone())
            .unwrap();
        // O que de fato entra no pipeline é o formato interno, não o Ogg —
        // confere que bate exatamente com o que `strip_container` extrairia
        // do Ogg original.
        assert_eq!(
            std::fs::read(&sanitizado_path).unwrap(),
            original_stream.encode()
        );

        let started = pair
            .core_a
            .start_send_audio(pair.device_id_b.clone(), sanitizado_path, false)
            .unwrap();

        // Timeline única (Fase 5): a nota já aparece do lado de quem manda,
        // Pending, antes de qualquer byte atravessar a rede.
        let sender_timeline = pair.core_a.list_messages(pair.device_id_b.clone()).unwrap();
        assert_eq!(sender_timeline.len(), 1);
        assert_eq!(sender_timeline[0].id, started.message_id);
        assert_eq!(sender_timeline[0].kind, MessageKindDto::VoiceNote);
        assert_eq!(sender_timeline[0].delivery_state, DeliveryStateDto::Pending);
        assert_eq!(sender_timeline[0].audio_file_id.as_deref(), Some(started.file_id.as_slice()));

        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();

        // ... e do lado de quem recebe, assim que o FILE_METADATA chega —
        // antes do primeiro AUDIO_CHUNK sequer existir.
        let receiver_timeline = pair.core_b.list_messages(pair.device_id_a.clone()).unwrap();
        assert_eq!(receiver_timeline.len(), 1);
        assert_eq!(receiver_timeline[0].kind, MessageKindDto::VoiceNote);
        assert_eq!(receiver_timeline[0].delivery_state, DeliveryStateDto::Delivered);
        assert_eq!(receiver_timeline[0].audio_file_id.as_deref(), Some(started.file_id.as_slice()));

        let audio_offers = pair.core_b.pending_audio_offers(pair.device_id_a.clone()).unwrap();
        assert_eq!(audio_offers.len(), 1, "oferta de áudio deveria aparecer em pending_audio_offers");
        assert!(
            pair.core_b.pending_file_offers(pair.device_id_a.clone()).unwrap().is_empty(),
            "oferta de áudio não deveria vazar para pending_file_offers"
        );

        for _ in 0..1000 {
            let progress = pair.core_b.transfer_progress(started.file_id.clone()).unwrap();
            if progress.map(|p| p.is_complete).unwrap_or(false) {
                break;
            }
            let Some(wire_chunk) = pair
                .core_a
                .next_outgoing_wire_chunk(started.file_id.clone())
                .unwrap()
            else {
                break;
            };
            pair.core_b
                .ingest_incoming_wire_bytes(wire_chunk)
                .unwrap()
                .expect("file_id vem em claro no próprio pacote — deveria ser reconhecido");

            let feedback_body = {
                let transfers = pair.core_b.lock_transfers().unwrap();
                let Some(TransferHandle::Receive(recv)) = transfers.get(&fid(&started.file_id)) else {
                    panic!("receive transfer deveria existir");
                };
                recv.feedback().encode()
            };
            let mut sessions_b = pair.core_b.lock_sessions().unwrap();
            let session_b = sessions_b.get_mut(&did(&pair.device_id_a)).unwrap();
            let sealed_feedback = session_b
                .encrypt_outgoing(
                    viska_proto::wire::packet_type::PacketType::FileFeedback,
                    feedback_body,
                    Transport::DataChannel,
                )
                .unwrap();
            drop(sessions_b);

            pair.core_a
                .decrypt_incoming(pair.device_id_b.clone(), sealed_feedback)
                .unwrap();
        }

        let progress = pair.core_b.transfer_progress(started.file_id.clone()).unwrap().unwrap();
        assert!(progress.is_complete, "transferência de áudio não completou dentro do limite de iterações");

        let dst_path = dir_dst.path().join("recebido.viska-audio");
        let sealed_complete = pair
            .core_b
            .finish_receive_audio(
                pair.device_id_a.clone(),
                started.file_id.clone(),
                dst_path.to_str().unwrap().to_owned(),
            )
            .unwrap();

        let internal_bytes = std::fs::read(&dst_path).unwrap();
        let wav = pair.core_b.decode_audio_to_wav(internal_bytes).unwrap();
        assert_eq!(&wav[0..4], b"RIFF", "decode_audio_to_wav deveria produzir um WAV válido (D18)");
        assert_eq!(&wav[8..12], b"WAVE");
        let declared_data_len = u32::from_le_bytes(wav[40..44].try_into().unwrap());
        assert_eq!(declared_data_len as usize, wav.len() - 44);
        assert!(wav.len() > 44, "WAV não deveria ficar vazio — a nota tinha 5 quadros de áudio real");

        // FILE_COMPLETE de volta ao emissor: o registro de transferência
        // dele (não a linha da timeline, que fica como histórico) some.
        pair.core_a
            .decrypt_incoming(pair.device_id_b.clone(), sealed_complete)
            .unwrap();
        assert!(pair
            .core_a
            .store
            .find_file_transfer(&fid(&started.file_id))
            .unwrap()
            .is_none());

        // A linha na timeline de quem mandou continua existindo (histórico
        // de conversa) mesmo depois da transferência terminar — só o
        // registro efêmero de `file_transfers` é removido.
        let sender_timeline_final = pair.core_a.list_messages(pair.device_id_b.clone()).unwrap();
        assert_eq!(sender_timeline_final.len(), 1);
        assert_eq!(sender_timeline_final[0].kind, MessageKindDto::VoiceNote);
    }

    /// Regressão de D17: duas transferências ativas ao mesmo tempo com o
    /// mesmo contato (um arquivo e uma nota de voz) — os pacotes dos dois
    /// chegam intercalados no mesmo canal `file`, e
    /// `ingest_incoming_wire_bytes` tem que rotear cada um pelo `file_id`
    /// em claro (D17), sem que quem chama precise saber de antemão qual é
    /// qual. Antes de D17 isto exigia rastrear "a" transferência ativa;
    /// agora as duas terminam certas e sem contaminação cruzada.
    #[test]
    fn two_concurrent_transfers_do_not_contaminate_each_other() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let dir_dst = tempfile::tempdir().unwrap();

        let arquivo_original: Vec<u8> = (0..20_000u32).map(|i| (i % 233) as u8).collect();
        let arquivo_path = write_temp_file(&dir_src, "arquivo.bin", &arquivo_original);
        let audio_stream = opus_real_stream(3);
        let audio_path = dir_src.path().join("audio.viska-audio").to_str().unwrap().to_owned();
        std::fs::write(&audio_path, audio_stream.encode()).unwrap();

        let started_arquivo = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), arquivo_path, false)
            .unwrap();
        let started_audio = pair
            .core_a
            .start_send_audio(pair.device_id_b.clone(), audio_path, false)
            .unwrap();

        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started_arquivo.sealed_metadata)
            .unwrap();
        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started_audio.sealed_metadata)
            .unwrap();

        let mut alguma_pendente = true;
        for _ in 0..20_000 {
            if !alguma_pendente {
                break;
            }
            alguma_pendente = false;

            for file_id in [&started_arquivo.file_id, &started_audio.file_id] {
                let progress = pair.core_b.transfer_progress(file_id.clone()).unwrap();
                if progress.map(|p| p.is_complete).unwrap_or(true) {
                    continue;
                }
                alguma_pendente = true;

                let Some(wire_chunk) = pair.core_a.next_outgoing_wire_chunk(file_id.clone()).unwrap() else {
                    continue;
                };
                let ingested = pair
                    .core_b
                    .ingest_incoming_wire_bytes(wire_chunk)
                    .unwrap()
                    .expect("file_id em claro deveria identificar a transferência certa");
                assert_eq!(
                    &ingested.file_id, file_id,
                    "ingest_incoming_wire_bytes roteou o pacote para o file_id errado"
                );

                let feedback_body = {
                    let transfers = pair.core_b.lock_transfers().unwrap();
                    let Some(TransferHandle::Receive(recv)) = transfers.get(&fid(file_id)) else {
                        panic!("receive transfer deveria existir");
                    };
                    recv.feedback().encode()
                };
                let mut sessions_b = pair.core_b.lock_sessions().unwrap();
                let session_b = sessions_b.get_mut(&did(&pair.device_id_a)).unwrap();
                let sealed_feedback = session_b
                    .encrypt_outgoing(PacketType::FileFeedback, feedback_body, Transport::DataChannel)
                    .unwrap();
                drop(sessions_b);
                pair.core_a
                    .decrypt_incoming(pair.device_id_b.clone(), sealed_feedback)
                    .unwrap();
            }
        }

        let progresso_arquivo = pair.core_b.transfer_progress(started_arquivo.file_id.clone()).unwrap().unwrap();
        let progresso_audio = pair.core_b.transfer_progress(started_audio.file_id.clone()).unwrap().unwrap();
        assert!(progresso_arquivo.is_complete, "arquivo não completou — provável contaminação cruzada");
        assert!(progresso_audio.is_complete, "áudio não completou — provável contaminação cruzada");

        let dst_arquivo = dir_dst.path().join("arquivo-recebido.bin");
        pair.core_b
            .finish_receive_file(
                pair.device_id_a.clone(),
                started_arquivo.file_id.clone(),
                dst_arquivo.to_str().unwrap().to_owned(),
            )
            .unwrap();
        assert_eq!(std::fs::read(&dst_arquivo).unwrap(), arquivo_original);

        let dst_audio = dir_dst.path().join("audio-recebido.viska-audio");
        pair.core_b
            .finish_receive_audio(
                pair.device_id_a.clone(),
                started_audio.file_id.clone(),
                dst_audio.to_str().unwrap().to_owned(),
            )
            .unwrap();
        let audio_recebido =
            viska_proto::file::opus_container::RawOpusStream::decode(&std::fs::read(&dst_audio).unwrap())
                .unwrap();
        assert_eq!(audio_recebido, audio_stream);
    }

    #[test]
    fn cancel_transfer_removes_state_and_does_not_error_for_unknown_file_id() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let src_path = write_temp_file(&dir_src, "x.bin", b"conteudo pequeno");

        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();

        pair.core_a.cancel_transfer(started.file_id.clone()).unwrap();
        assert!(pair
            .core_a
            .store
            .find_file_transfer(&fid(&started.file_id))
            .unwrap()
            .is_none());

        // `file_id` desconhecido: não deveria errar.
        pair.core_a.cancel_transfer(vec![0u8; 16]).unwrap();
    }
}
