//! Superfície FFI de transferência de arquivo — Fase 4.
//!
//! `FILE_SYMBOL` contorna `session::Session` inteiramente (ver o porquê em
//! `viska_proto::file::transfer`, doc do módulo, confirmado com o usuário) —
//! por isso `next_outgoing_file_symbol`/`ingest_incoming_file_symbol` abaixo
//! nunca tocam `self.sessions`. `FILE_METADATA`/`FILE_FEEDBACK`/
//! `FILE_COMPLETE` continuam pelo canal `control`, via `Session`, como
//! `MSG_TEXT` — processados dentro de `Core::decrypt_incoming`
//! (`ffi/session.rs`), não aqui: o dispatch por `packet_type` só pode
//! acontecer depois que o AEAD do envelope já abriu, e `decrypt_incoming` é
//! o único lugar que faz isso.
//!
//! Sem `StreamSink`: mesma filosofia síncrona de `ffi/session.rs`. Quem
//! dirige o laço de envio/recebimento é o lado Dart.
//!
//! ## O que não está aqui — relatado, não decidido em silêncio
//!
//! - **Sem fluxo de aceitar/recusar oferta.** Uma `FILE_METADATA` recebida
//!   inicia o recebimento (cria `.staging`) automaticamente. Antes de expor
//!   isto a usuários de verdade, alguém precisa decidir se um contato já
//!   pareado pode preencher disco sem confirmação — decisão de produto,
//!   não técnica.
//! - **`block_symbols` sempre no teto de D6 (1024), `symbol_size` só
//!   `use_lan: bool`.** Nenhum ajuste fino exposto.
//! - **Controle de taxa de envio é só o que `SendTransfer` já faz**
//!   (parar quando o bloco completa) — nenhum ritmo/pacing aqui.

use std::collections::HashSet;
use std::fs::File;
use std::path::Path;

use crate::ffi::core::Core;
use crate::ffi::error::FfiError;
use crate::ffi::types::{FileOfferDto, SendFileStartedDto, TransferProgressDto};
use viska_proto::crypto::identity::DEVICE_ID_LEN;
use viska_proto::file::manifest::{self, Manifest, FILE_ID_LEN, MAX_BLOCK_SYMBOLS};
use viska_proto::file::merkle;
use viska_proto::file::transfer::{
    self, FileFeedback, ReceiveTransfer, SendTransfer, TransferProgress, TRANSFER_SECRET_LEN,
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
            let body = transfer::encode_metadata_body(&transfer_secret, &manifest)?;
            session.encrypt_outgoing(PacketType::FileMetadata, body, Transport::DataChannel)?
        };

        let file = File::open(&file_path).map_err(|_| FfiError::Internal)?;
        let send = SendTransfer::new(manifest.clone(), &transfer_secret, file);

        let manifest_cbor = manifest.encode()?;
        let created_at = viska_proto::util::time::unix_seconds() as i64;
        self.store.insert_file_transfer(
            &file_id,
            Direction::Sending,
            &device_id,
            &manifest_cbor,
            &transfer_secret,
            created_at,
        )?;

        self.lock_transfers()?
            .insert(file_id, TransferHandle::Send(send));

        Ok(SendFileStartedDto {
            file_id: file_id.to_vec(),
            sealed_metadata,
        })
    }

    /// Próximo símbolo a mandar no canal `file` do WebRTC — já selado com
    /// `K_symbol` (contorna `Session`, ver doc do módulo). `Ok(None)`
    /// quando o `file_id` não é uma transferência de envio conhecida (já
    /// terminou, ou nunca existiu) ou quando o emissor esgotou o que tinha
    /// a mandar para o estado atual.
    pub fn next_outgoing_file_symbol(&self, file_id: Vec<u8>) -> Result<Option<Vec<u8>>, FfiError> {
        let file_id = to_file_id(file_id)?;
        let mut transfers = self.lock_transfers()?;
        match transfers.get_mut(&file_id) {
            Some(TransferHandle::Send(send)) => Ok(send.next_sealed_symbol()?),
            _ => Ok(None),
        }
    }

    /// Progresso de uma transferência conhecida, de qualquer lado — `None`
    /// se `file_id` não corresponde a nada em andamento.
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
    /// já em recebimento.
    pub fn pending_file_offers(&self, peer_device_id: Vec<u8>) -> Result<Vec<FileOfferDto>, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        let stored = self
            .store
            .list_file_transfers_for_contact(&device_id, Direction::Receiving)?;

        let mut offers = Vec::with_capacity(stored.len());
        for entry in stored {
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

    /// Alimenta um símbolo recebido no canal `file` do WebRTC (selado,
    /// contorna `Session` — ver doc do módulo).
    pub fn ingest_incoming_file_symbol(
        &self,
        file_id: Vec<u8>,
        sealed_symbol: Vec<u8>,
    ) -> Result<TransferProgressDto, FfiError> {
        let file_id = to_file_id(file_id)?;
        let mut transfers = self.lock_transfers()?;
        match transfers.get_mut(&file_id) {
            Some(TransferHandle::Receive(recv)) => {
                Ok(progress_dto(recv.ingest_sealed_symbol(sealed_symbol)?))
            }
            _ => Err(FfiError::Internal),
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
        let device_id = to_device_id(peer_device_id)?;
        let file_id = to_file_id(file_id)?;

        let handle = self
            .lock_transfers()?
            .remove(&file_id)
            .ok_or(FfiError::Internal)?;
        let TransferHandle::Receive(recv) = handle else {
            // Devolve o handle de envio — `finish_receive_file` não é o
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
    /// sentido depois que o AEAD do envelope já abriu.
    pub(super) fn handle_incoming_file_metadata(
        &self,
        contact_device_id: [u8; DEVICE_ID_LEN],
        body: Vec<u8>,
    ) -> Result<(), FfiError> {
        let (transfer_secret, manifest) = transfer::decode_metadata_body(&body)?;
        let manifest_cbor = manifest.encode()?;
        let created_at = viska_proto::util::time::unix_seconds() as i64;

        self.store.insert_file_transfer(
            &manifest.file_id,
            Direction::Receiving,
            &contact_device_id,
            &manifest_cbor,
            &transfer_secret,
            created_at,
        )?;

        let receive = ReceiveTransfer::start(manifest.clone(), &transfer_secret, &self.staging_dir)?;
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
        let contact_a_seen_by_b = core_b.pair_from_qr(core_a.my_qr_payload()).unwrap();
        let contact_b_seen_by_a = core_a.pair_from_qr(core_b.my_qr_payload()).unwrap();

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
            .public()
            .is_before(&pair.core_b.identity.public())
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
    fn start_send_file_sem_sessao_estabelecida_erra() {
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
    fn transferencia_de_arquivo_ponta_a_ponta_pela_fronteira_ffi() {
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
            let Some(sealed_symbol) = pair
                .core_a
                .next_outgoing_file_symbol(started.file_id.clone())
                .unwrap()
            else {
                break;
            };
            pair.core_b
                .ingest_incoming_file_symbol(started.file_id.clone(), sealed_symbol)
                .unwrap();

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

    #[test]
    fn cancel_transfer_remove_estado_e_nao_erra_para_file_id_desconhecido() {
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
