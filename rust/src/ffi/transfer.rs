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
//! ## Fluxo de aceitar/recusar oferta (Issue #23, U-08)
//!
//! Transferências com tamanho até o limite configurável (`auto_accept_file_size_limit`,
//! padrão 100 MiB) são aceitas e iniciadas automaticamente. Ofertas acima do limite
//! são retidas em memória volátil (`Core::unconfirmed_offers`) aguardando confirmação
//! explícita do usuário via [`Core::accept_file_offer`] ou recusa via [`Core::reject_file_offer`],
//! prevenindo que contatos preencham o disco silenciosamente.
//!
//! ## O que não está aqui — relatado, não decidido em silêncio
//!
//! - **Recusa e perda no lock avisam o emissor só em melhor esforço**:
//!   `reject_file_offer` e `Core::lock` selam um `FILE_REJECT` (§7.7), mas sem
//!   sessão ou transporte o aviso se perde. O emissor cobre o resto com o prazo
//!   de [`OFFER_RESPONSE_TIMEOUT_SECS`], contado a partir do banco.
//! - **Ofertas não confirmadas vivem só em RAM**: um auto-lock (`Core::lock`) ou
//!   fechamento do app limpa as ofertas retidas com zeroize.
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
//!
//! ## Retomada depois de bloqueio ou reinício (§7.5)
//!
//! O handle em memória é descartável: `Core::lock` o joga fora com as chaves,
//! e [`Core::resume_transfers`] o reconstrói do banco quando a sessão com o
//! contato volta a `Established`. O emissor lê de uma cópia cifrada do
//! arquivo-fonte em `outgoing/`, gravada em `start_send` e conferida contra a
//! raiz a cada reconstrução; o receptor reabre o próprio `.staging`. Quem
//! recebe o arquivo nada precisa saber: o bitmap de `FILE_FEEDBACK` já faz o
//! emissor pular o que chegou. Uma transferência enfileirada sem sessão (#79)
//! entra pelo mesmo caminho: basta existir a linha e a cópia.

use std::fs::File;
use std::path::Path;

use crate::ffi::core::Core;
use crate::ffi::error::FfiError;
use crate::ffi::transfer_handles::{can_seal_now, OutgoingHandle, TransferHandle};
use crate::ffi::types::{
    FileOfferDto, IngestedChunkDto, SealedNoticeDto, SendAudioStartedDto, SendFileStartedDto,
    TransferEventDto, TransferEventKind, TransferProgressDto,
};
use crate::frb_generated::StreamSink;
use crate::transfer_events::TransferEventSink;
use viska_proto::crypto::identity::DEVICE_ID_LEN;
use viska_proto::file::manifest::{self, Manifest, FILE_ID_LEN, LAN_SYMBOL_SIZE, MAX_BLOCK_SYMBOLS};
use viska_proto::file::outgoing;
use viska_proto::file::staging;
use viska_proto::file::transfer::{
    self, FileFeedback, ReceiveTransfer, TransferKind, TransferProgress,
    TRANSFER_SECRET_LEN,
};
use viska_proto::store::transfers::Direction;
use viska_proto::wire::packet_type::PacketType;
use viska_proto::wire::transport::Transport;

/// Sela o `FILE_REJECT` de `file_id`, ou `None` sem sessão estabelecida ou se
/// selar falhar. Recusa e bloqueio passam por aqui para o emissor não poder
/// distinguir um do outro (§7.7 item 1).
pub(super) fn seal_file_reject(session: &mut viska_proto::session::Session, file_id: &[u8; FILE_ID_LEN]) -> Option<Vec<u8>> {
    if !session.is_established() {
        return None;
    }
    session
        .encrypt_outgoing(PacketType::FileReject, file_id.to_vec(), Transport::DataChannel)
        .ok()
}

/// Quanto o emissor espera pelo primeiro `FILE_FEEDBACK` ou `FILE_REJECT`
/// antes de desistir da oferta (§7.7). Longo de propósito: o `lock()` do
/// receptor já avisa, então isto só cobre o aviso que não chegou, e não deve
/// matar a oferta de quem ainda está decidindo.
pub(super) const OFFER_RESPONSE_TIMEOUT_SECS: i64 = 24 * 60 * 60;

/// Apaga a cópia de envio se `start_send` falhar depois de gravá-la.
struct OutgoingCopyGuard {
    path: Option<std::path::PathBuf>,
}

impl Drop for OutgoingCopyGuard {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// Teto padrão em bytes para aceitação automática de arquivos (100 MiB).
/// Ofertas que excederem este valor ficam retidas aguardando confirmação explícita
/// do usuário para evitar exaustão silenciosa de disco (Issue #23, U-08).
pub const DEFAULT_AUTO_ACCEPT_FILE_SIZE_LIMIT: u64 = 100 * 1024 * 1024;

/// Chave em `app_config` que guarda o limite de auto-aceite configurado.
pub const CONFIG_KEY_AUTO_ACCEPT_FILE_SIZE_LIMIT: &str = "auto_accept_file_size_limit";

/// Teto de ofertas retidas em memória por contato para evitar flood de RAM (Issue #23).
pub const MAX_UNCONFIRMED_OFFERS_PER_CONTACT: usize = 16;

/// Teto total de ofertas retidas em memória em todo o dispositivo.
pub const MAX_UNCONFIRMED_OFFERS_TOTAL: usize = 64;

/// Uma oferta de arquivo recebida com tamanho acima do limite de
/// auto-aceite, retida em memória aguardando confirmação do usuário.
pub(super) struct UnconfirmedOffer {
    pub(super) contact_device_id: [u8; DEVICE_ID_LEN],
    pub(super) kind: TransferKind,
    pub(super) transfer_secret: zeroize::Zeroizing<[u8; TRANSFER_SECRET_LEN]>,
    pub(super) manifest: Manifest,
    pub(super) manifest_cbor: Vec<u8>,
    pub(super) received_at: i64,
}

impl std::fmt::Debug for UnconfirmedOffer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UnconfirmedOffer")
            .field("contact_device_id", &hex::encode(self.contact_device_id))
            .field("kind", &self.kind)
            .field("transfer_secret", &"<redigido>")
            .field("file_id", &hex::encode(self.manifest.file_id))
            .field("file_size", &self.manifest.file_size)
            .field("received_at", &self.received_at)
            .finish()
    }
}

/// Resultado interno de [`Core::start_send`] — `start_send_file`/
/// `start_send_audio` cada um decide sozinho como virar isto num DTO
/// público (só `start_send_audio` precisa inserir uma linha na timeline
/// única antes de responder).
struct StartedTransfer {
    file_id: [u8; FILE_ID_LEN],
    sealed_metadata: Vec<u8>,
    message_id: i64,
}

pub(super) fn to_device_id(bytes: Vec<u8>) -> Result<[u8; DEVICE_ID_LEN], FfiError> {
    bytes.try_into().map_err(|_| FfiError::Internal)
}

fn to_file_id(bytes: Vec<u8>) -> Result<[u8; FILE_ID_LEN], FfiError> {
    bytes.try_into().map_err(|_| FfiError::Internal)
}

fn progress_dto(progress: TransferProgress, awaiting_answer: bool) -> TransferProgressDto {
    TransferProgressDto {
        blocks_done: progress.blocks_done,
        total_blocks: progress.total_blocks,
        bytes_done: progress.bytes_done,
        is_complete: progress.is_complete(),
        awaiting_answer,
    }
}

impl Core {
    /// Inicia o envio de um arquivo para um contato pareado com sessão já
    /// estabelecida. Lê o arquivo inteiro uma vez para calcular a raiz de
    /// Merkle (§7.2) — não tem como evitar essa leitura, o manifesto
    /// precisa da raiz completa antes do primeiro símbolo sair.
    ///
    /// `use_lan` escolhe `symbol_size`: 65535 (LAN, `LAN_SYMBOL_SIZE`) ou 16384
    /// (DataChannel) — a mesma distinção de `wire::transport::Transport`.
    /// `block_symbols` é sempre o teto de D6 (1024).
    pub fn start_send_file(
        &self,
        peer_device_id: Vec<u8>,
        file_path: String,
        use_lan: bool,
    ) -> Result<SendFileStartedDto, FfiError> {
        // Extrai o nome do arquivo para usar como corpo da mensagem na timeline
        // — o mesmo `name` que vai cifrado no manifesto, mas aqui em claro
        // para exibição local. Não é segredo: o receptor também verá.
        let file_name = Path::new(&file_path)
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or(FfiError::Internal)?
            .to_owned();

        let started = self.start_send(peer_device_id, file_path, use_lan, TransferKind::File, |_| file_name)?;

        Ok(SendFileStartedDto {
            file_id: started.file_id.to_vec(),
            sealed_metadata: started.sealed_metadata,
            message_id: started.message_id,
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
        let started =
            self.start_send(peer_device_id, audio_path, use_lan, TransferKind::Audio, |file_id| hex::encode(file_id))?;

        Ok(SendAudioStartedDto {
            file_id: started.file_id.to_vec(),
            sealed_metadata: started.sealed_metadata,
            message_id: started.message_id,
        })
    }

    /// Núcleo de `start_send_file`/`start_send_audio`. `message_body` monta o
    /// corpo da linha da timeline a partir do `file_id` (nome do arquivo, ou
    /// `hex(file_id)` numa nota de voz, ver doc do módulo).
    fn start_send(
        &self,
        peer_device_id: Vec<u8>,
        file_path: String,
        use_lan: bool,
        kind: TransferKind,
        message_body: impl FnOnce(&[u8; FILE_ID_LEN]) -> String,
    ) -> Result<StartedTransfer, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);

        // Sem sessão não há como oferecer; checar antes de copiar poupa a
        // leitura inteira do arquivo. A sessão é conferida de novo ao selar.
        if !self.lock_sessions()?.get(&device_id).is_some_and(can_seal_now) {
            return Err(FfiError::NoActiveSession);
        }

        let symbol_size: u16 = if use_lan {
            LAN_SYMBOL_SIZE
        } else {
            Transport::DataChannel.max_bucket() as u16
        };
        let block_symbols = MAX_BLOCK_SYMBOLS;

        let file_id: [u8; FILE_ID_LEN] = viska_proto::util::rng::array::<FILE_ID_LEN>()?;
        // Preenche in loco: `rng::array` devolveria o array `Copy` por valor e
        // deixaria cópias do segredo na pilha sem zeroize.
        let mut transfer_secret = zeroize::Zeroizing::new([0u8; TRANSFER_SECRET_LEN]);
        viska_proto::util::rng::fill(&mut *transfer_secret)?;

        let name = Path::new(&file_path)
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or(FfiError::Internal)?;
        let name_encrypted = manifest::encrypt_name(&*transfer_secret, &file_id, name)?;

        // Raiz e tamanho vêm da cópia, não de uma leitura à parte do original:
        // o que se oferece é exatamente o que será lido na retomada.
        let source = File::open(&file_path).map_err(|_| FfiError::Internal)?;
        let mut copy_guard = OutgoingCopyGuard {
            path: Some(staging::staging_path(&self.outgoing_dir, &file_id)),
        };
        let (merkle_root, file_size) =
            outgoing::stage_outgoing_copy(source, &self.outgoing_dir, file_id, &*transfer_secret)?;
        let block_bytes = symbol_size as u64 * block_symbols as u64;
        let source_blocks = u32::try_from(file_size.div_ceil(block_bytes)).map_err(|_| FfiError::Internal)?;

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
            let sealed = session.encrypt_outgoing(PacketType::FileMetadata, body, Transport::DataChannel)?;
            (sealed, session.generation())
        };
        let (sealed_metadata, generation) = sealed_metadata;

        let reader = outgoing::read_outgoing_copy(&self.outgoing_dir, &manifest, &*transfer_secret)?;

        let manifest_cbor = manifest.encode()?;
        let created_at = viska_proto::util::time::unix_seconds() as i64;
        // A mensagem vem antes da linha da transferência: uma linha sem mensagem
        // seria retomada sem que a pessoa a visse. Uma mensagem sem linha (o app
        // fechou entre as duas) vira falha na próxima abertura.
        let packet_type = match kind {
            TransferKind::File => PacketType::FileMetadata,
            TransferKind::Audio => PacketType::AudioChunk,
        };
        let message_id =
            self.store
                .insert_pending_message(&device_id, packet_type, &message_body(&file_id), created_at)?;
        self.store.set_message_file_id(message_id, &file_id)?;
        let inserted = self.store.insert_file_transfer(
            &file_id,
            Direction::Sending,
            &device_id,
            &manifest_cbor,
            &*transfer_secret,
            created_at,
            kind,
        );
        if let Err(err) = inserted {
            let _ = self.store.mark_message_failed(message_id);
            return Err(err.into());
        }
        // A linha existe: daqui em diante a cópia é dela, e quem a apaga é o fim
        // da transferência ou o prazo de retenção.
        copy_guard.path = None;

        let handle = OutgoingHandle::new(manifest, kind, &*transfer_secret, reader, generation, false);
        if !self.install_handle(file_id, TransferHandle::Send(handle), None)? {
            // A Core trancou durante a cópia: a linha e a cópia ficam, e o envio
            // retoma depois do desbloqueio.
            return Err(FfiError::Locked);
        }

        Ok(StartedTransfer {
            file_id,
            sealed_metadata,
            message_id,
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
        // Trancada, o handle sumiu e `None` pareceria "nada a mandar agora": o
        // laço do Dart daria o envio por concluído (§7.5).
        self.ensure_not_locked()?;
        let file_id = to_file_id(file_id)?;
        let mut transfers = self.lock_transfers()?;
        match transfers.get_mut(&file_id) {
            Some(TransferHandle::Send(send)) => Ok(send.transfer.next_sealed_symbol()?),
            _ => Ok(None),
        }
    }

    /// Progresso de uma transferência conhecida, de qualquer lado (arquivo
    /// ou áudio) — `None` se `file_id` não corresponde a nada em andamento.
    pub fn transfer_progress(&self, file_id: Vec<u8>) -> Result<Option<TransferProgressDto>, FfiError> {
        // Mesmo motivo de `next_outgoing_wire_chunk`: `None` trancada seria lido
        // como transferência terminada.
        self.ensure_not_locked()?;
        let file_id = to_file_id(file_id)?;
        let transfers = self.lock_transfers()?;
        Ok(match transfers.get(&file_id) {
            Some(TransferHandle::Send(send)) => Some(progress_dto(send.transfer.progress(), !send.answered)),
            Some(TransferHandle::Receive(recv)) => Some(progress_dto(recv.progress(), false)),
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
            // Linha com nome que não decifra (gravada antes da validação na
            // chegada) não pode esconder as demais transferências do contato.
            let Ok(name) = manifest::decrypt_name(
                &entry.transfer_secret,
                &manifest.file_id,
                &manifest.name_encrypted,
            ) else {
                continue;
            };
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
                let progress = progress_dto(recv.ingest_sealed_symbol(sealed)?, false);
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
    /// D15).
    ///
    /// `Ok` quer dizer que o arquivo está no destino, e só então: quem chama
    /// pode apagar `destination_path` num `Err`. O `FILE_COMPLETE` selado volta
    /// em `Some` para mandar ao emissor pelo canal `control`; sem sessão que
    /// cifre agora ele é `None`, em melhor esforço como o `FILE_REJECT`, e o
    /// emissor só para pelo limite de inatividade (issue #108).
    pub fn finish_receive_file(
        &self,
        peer_device_id: Vec<u8>,
        file_id: Vec<u8>,
        destination_path: String,
    ) -> Result<Option<Vec<u8>>, FfiError> {
        self.finish_receive(peer_device_id, file_id, destination_path, TransferKind::File)
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
    ) -> Result<Option<Vec<u8>>, FfiError> {
        self.finish_receive(peer_device_id, file_id, destination_path, TransferKind::Audio)
    }

    /// Gera o pacote `FILE_FEEDBACK` (0x22) selado pela sessão para o `file_id`
    /// indicado, refletindo o progresso atual do `ReceiveTransfer` (U-02).
    /// Devolve o payload selado pronto para envio pelo canal de controle.
    pub fn file_feedback(
        &self,
        peer_device_id: Vec<u8>,
        file_id: Vec<u8>,
    ) -> Result<Vec<u8>, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);
        let file_id = to_file_id(file_id)?;

        let feedback_body = {
            let transfers = self.lock_transfers()?;
            let Some(TransferHandle::Receive(recv)) = transfers.get(&file_id) else {
                return Err(FfiError::Internal);
            };
            recv.feedback().encode()
        };

        let mut sessions = self.lock_sessions()?;
        let session = sessions
            .get_mut(&device_id)
            .ok_or(FfiError::NoActiveSession)?;
        if !session.is_established() {
            return Err(FfiError::NoActiveSession);
        }

        let sealed = session.encrypt_outgoing(
            PacketType::FileFeedback,
            feedback_body,
            Transport::DataChannel,
        )?;
        Ok(sealed)
    }

    fn finish_receive(
        &self,
        peer_device_id: Vec<u8>,
        file_id: Vec<u8>,
        destination_path: String,
        kind: TransferKind,
    ) -> Result<Option<Vec<u8>>, FfiError> {
        let device_id = to_device_id(peer_device_id)?;
        // Declarado antes do lock de sessões, de propósito: é solto depois dele.
        let _publish = self.publish_on_exit(device_id);
        let file_id = to_file_id(file_id)?;
        // Um arquivo fechado como nota de voz seria lido inteiro para a memória e
        // apagado; o tipo vem do `FILE_METADATA`, não de quem chama.
        let stored = self.store.find_file_transfer(&file_id)?.ok_or(FfiError::Internal)?;
        if stored.kind != kind || stored.direction != Direction::Receiving {
            return Err(FfiError::Internal);
        }

        let destination =
            std::fs::File::create(&destination_path).map_err(|_| FfiError::Internal)?;
        let (handle, claim) = self.take_for_finish(file_id)?.ok_or(FfiError::Internal)?;
        let TransferHandle::Receive(mut recv) = handle else {
            // Defensivo: a linha conferida acima é de recebimento, então o handle
            // também é. Se não for, ele volta ao mapa em vez de sumir.
            self.install_handle(file_id, handle, Some(claim))?;
            return Err(FfiError::Internal);
        };

        let complete = match recv.finish(&self.staging_dir, destination) {
            Ok(complete) => complete,
            // A raiz não bate: receber de novo daria o mesmo arquivo errado.
            Err(viska_proto::Error::MerkleMismatch) => {
                self.end_transfer(&file_id)?;
                return Err(viska_proto::Error::MerkleMismatch.into());
            }
            // Qualquer outra falha (E/S no destino, Core trancada no meio) devolve o
            // handle, ainda completo: a próxima tentativa só decifra de novo, sem
            // receber nada (§7.5).
            Err(err) => {
                self.install_handle(file_id, TransferHandle::Receive(recv), Some(claim))?;
                return Err(err.into());
            }
        };
        // A reserva vai até a linha sumir; uma retomada que reservar depois disso
        // confere a linha antes de concluir que o staging se perdeu (`rebuild`).
        self.end_transfer(&file_id)?;
        drop(claim);

        // Daqui em diante o arquivo já está no destino e a transferência acabou:
        // uma falha ao selar não pode virar `Err`, que faria quem chama apagar o
        // arquivo recebido.
        let mut sessions = self.lock_sessions()?;
        Ok(sessions
            .get_mut(&device_id)
            .filter(|session| can_seal_now(session))
            .and_then(|session| {
                session
                    .encrypt_outgoing(PacketType::FileComplete, complete.encode(), Transport::DataChannel)
                    .ok()
            }))
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
    /// memória e o registro em `store`, o que destrói a chave (§7.5/D15), e
    /// apaga o `.staging` do receptor ou a cópia em `outgoing/` do emissor.
    pub fn cancel_transfer(&self, file_id: Vec<u8>) -> Result<(), FfiError> {
        let file_id = to_file_id(file_id)?;
        self.remove_unconfirmed_offer(&file_id)?;
        self.end_transfer(&file_id)
    }

    /// Lista os `file_id` de transferências de arquivo ativas persistidas em banco.
    pub fn list_active_file_transfer_ids(&self) -> Result<Vec<Vec<u8>>, FfiError> {
        self.ensure_not_locked()?;
        let ids = self.store.list_active_file_transfer_ids()?;
        Ok(ids.into_iter().map(|id| id.to_vec()).collect())
    }

    /// Sela um `FILE_REJECT` para cada oferta retida, para `Core::lock` entregar
    /// ao Dart antes de zerar as sessões (§7.6.2). Sem sessão estabelecida, ou
    /// se selar falhar, aquele aviso se perde: o prazo do emissor cobre.
    pub(super) fn seal_lock_notices(&self) -> Vec<SealedNoticeDto> {
        // Mutex envenenado: `lock()` zera tudo logo depois, então o aviso se perde
        // sem rastro. Aceitável num melhor esforço; o prazo do emissor cobre.
        let (Ok(offers), Ok(mut sessions)) = (self.lock_unconfirmed_offers(), self.lock_sessions()) else {
            return Vec::new();
        };
        offers
            .iter()
            .filter_map(|(file_id, offer)| {
                let session = sessions.get_mut(&offer.contact_device_id)?;
                let bytes = seal_file_reject(session, file_id)?;
                Some(SealedNoticeDto {
                    peer_device_id: offer.contact_device_id.to_vec(),
                    bytes,
                })
            })
            .collect()
    }

    fn lock_unconfirmed_offers(
        &self,
    ) -> Result<std::sync::MutexGuard<'_, std::collections::HashMap<[u8; FILE_ID_LEN], UnconfirmedOffer>>, FfiError>
    {
        self.unconfirmed_offers.lock().map_err(|_| FfiError::Internal)
    }

    /// Passa a receber os eventos de oferta de arquivo, a partir das ofertas já
    /// retidas (replay): um evento emitido antes da assinatura não se perderia
    /// para o Dart. Uma nova assinatura substitui a anterior.
    pub fn subscribe_transfer_events(
        &self,
        sink: StreamSink<TransferEventDto>,
    ) -> Result<(), FfiError> {
        self.set_transfer_event_sink(Box::new(move |event| {
            // Erro aqui é o Dart já ter fechado o stream: nada a fazer.
            let _ = sink.add(event);
        }))
    }

    /// Núcleo de [`Self::subscribe_transfer_events`], sem o `StreamSink`, para
    /// que os testes observem os eventos sem subir a ponte.
    pub(crate) fn set_transfer_event_sink(&self, sink: TransferEventSink) -> Result<(), FfiError> {
        let offers = self.lock_unconfirmed_offers()?;
        let mut events = self.transfer_events.lock().map_err(|_| FfiError::Internal)?;
        events.set_sink(
            sink,
            offers.iter().map(|(file_id, offer)| {
                offer_event(TransferEventKind::OfferAppeared, offer.contact_device_id, *file_id)
            }),
        );
        Ok(())
    }

    /// Chamar com a trava de `unconfirmed_offers` em mãos (ver `Core`).
    fn emit_offer_event(
        &self,
        kind: TransferEventKind,
        contact: [u8; DEVICE_ID_LEN],
        file_id: [u8; FILE_ID_LEN],
    ) {
        // Trava envenenada só acontece depois de um pânico, que já inutiliza a
        // Core; o aviso se perde e a lista só é relida na próxima ação da pessoa.
        if let Ok(events) = self.transfer_events.lock() {
            events.emit(offer_event(kind, contact, file_id));
        }
    }

    /// Tira uma oferta retida e avisa o Dart, sem evento se ela não existia.
    fn remove_unconfirmed_offer(
        &self,
        file_id: &[u8; FILE_ID_LEN],
    ) -> Result<Option<UnconfirmedOffer>, FfiError> {
        let mut offers = self.lock_unconfirmed_offers()?;
        let removed = offers.remove(file_id);
        if let Some(offer) = &removed {
            self.emit_offer_event(TransferEventKind::OfferGone, offer.contact_device_id, *file_id);
        }
        Ok(removed)
    }

    /// Descarta todas as ofertas retidas, avisando cada uma (bloqueio do cofre).
    pub(super) fn clear_unconfirmed_offers(&self) -> Result<(), FfiError> {
        let mut offers = self.lock_unconfirmed_offers()?;
        for (file_id, offer) in offers.drain() {
            self.emit_offer_event(TransferEventKind::OfferGone, offer.contact_device_id, file_id);
        }
        Ok(())
    }

    /// Lista as ofertas de arquivo pendentes de confirmação do usuário para
    /// o contato especificado (Issue #23, U-08).
    pub fn unconfirmed_file_offers(
        &self,
        peer_device_id: Vec<u8>,
    ) -> Result<Vec<FileOfferDto>, FfiError> {
        self.ensure_not_locked()?;
        let device_id = to_device_id(peer_device_id)?;
        let unconfirmed = self.lock_unconfirmed_offers()?;

        let mut offers = Vec::new();
        for offer in unconfirmed.values() {
            if offer.contact_device_id != device_id {
                continue;
            }
            // Um nome que não decifra não pode derrubar a listagem inteira do
            // contato; a oferta ruim só não aparece.
            let Ok(name) = manifest::decrypt_name(
                offer.transfer_secret.as_ref(),
                &offer.manifest.file_id,
                &offer.manifest.name_encrypted,
            ) else {
                continue;
            };
            offers.push(FileOfferDto {
                file_id: offer.manifest.file_id.to_vec(),
                name,
                file_size: offer.manifest.file_size,
            });
        }
        Ok(offers)
    }

    /// Aceita manualmente uma oferta de arquivo retida por exceder o limite
    /// de auto-aceite. Cria o registro em `file_transfers`, inicializa o
    /// `ReceiveTransfer` em `.staging` e passa a aceitar os pacotes do arquivo.
    pub fn accept_file_offer(&self, file_id: Vec<u8>) -> Result<(), FfiError> {
        self.ensure_not_locked()?;
        let fid = to_file_id(file_id)?;

        // A oferta só sai do mapa depois do sucesso: se o .staging falhar (disco
        // cheio), o usuário pode tentar de novo, e o emissor não reenvia FILE_METADATA.
        let (contact_device_id, kind, secret, manifest, manifest_cbor, received_at) = {
            let unconfirmed = self.lock_unconfirmed_offers()?;
            let offer = unconfirmed.get(&fid).ok_or(FfiError::OfferNotFound)?;
            (
                offer.contact_device_id,
                offer.kind,
                offer.transfer_secret.clone(),
                offer.manifest.clone(),
                offer.manifest_cbor.clone(),
                offer.received_at,
            )
        };

        self.start_receiving_transfer(
            contact_device_id,
            kind,
            &secret[..],
            manifest,
            manifest_cbor,
            received_at,
        )?;

        self.remove_unconfirmed_offer(&fid)?;
        Ok(())
    }

    /// Rejeita e descarta uma oferta de arquivo retida em memória. Remove
    /// a oferta e zera o material de chave sem criar registro em banco ou
    /// arquivo em staging.
    ///
    /// Devolve o `FILE_REJECT` já selado para o Dart enviar (§7.7), ou `None`
    /// se não há sessão estabelecida agora. A recusa local vale de qualquer
    /// jeito: o aviso é melhor esforço e nada é guardado em disco para
    /// reenviá-lo, para não contrariar a retenção volátil da §7.6.
    pub fn reject_file_offer(&self, file_id: Vec<u8>) -> Result<Option<Vec<u8>>, FfiError> {
        self.ensure_not_locked()?;
        let fid = to_file_id(file_id)?;
        let offer = self
            .remove_unconfirmed_offer(&fid)?
            .ok_or(FfiError::OfferNotFound)?;

        let _publish = self.publish_on_exit(offer.contact_device_id);
        let mut sessions = self.lock_sessions()?;
        let Some(session) = sessions.get_mut(&offer.contact_device_id) else {
            return Ok(None);
        };
        // Falha ao selar não desfaz a recusa: o chamador só perde o aviso.
        Ok(seal_file_reject(session, &fid))
    }

    fn start_receiving_transfer(
        &self,
        contact_device_id: [u8; DEVICE_ID_LEN],
        kind: TransferKind,
        transfer_secret: &[u8],
        manifest: Manifest,
        manifest_cbor: Vec<u8>,
        received_at: i64,
    ) -> Result<(), FfiError> {
        // O staging vem antes do banco: uma falha aqui não deixa linha em
        // `file_transfers`, que impediria o novo aceite por conflito de chave.
        // Tentar de novo trunca o arquivo, e `sweep_orphaned` recolhe o que sobrar.
        let receive = ReceiveTransfer::start(manifest.clone(), kind, transfer_secret, &self.staging_dir)?;

        self.store.insert_file_transfer(
            &manifest.file_id,
            Direction::Receiving,
            &contact_device_id,
            &manifest_cbor,
            transfer_secret,
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

        if !self.install_handle(manifest.file_id, TransferHandle::Receive(receive), None)? {
            return Err(FfiError::Locked);
        }
        Ok(())
    }

    /// Chamado de dentro de `Core::decrypt_incoming` (`ffi/session.rs`)
    /// quando um `FILE_METADATA` chega — não é público porque só faz
    /// sentido depois que o AEAD do envelope já abriu. Se `manifest.file_size`
    /// exceder o limite de auto-aceite configurado, retém a oferta em memória
    /// para confirmação explícita do usuário (Issue #23, U-08).
    pub(super) fn handle_incoming_file_metadata(
        &self,
        contact_device_id: [u8; DEVICE_ID_LEN],
        body: zeroize::Zeroizing<Vec<u8>>,
    ) -> Result<(), FfiError> {
        let (kind, transfer_secret, manifest) = transfer::decode_metadata_body(&body)?;
        // O emissor reenvia a oferta ao retomar, enquanto não tiver resposta
        // (§7.5): uma oferta que já virou recebimento é ignorada, e uma retida
        // é tratada logo abaixo. Um `file_id` de envio nosso também, sem erro
        // distinguível.
        if self.store.file_transfer_exists(&manifest.file_id)? {
            return Ok(());
        }
        let manifest_cbor = manifest.encode()?;
        let received_at = viska_proto::util::time::unix_seconds() as i64;

        // Valida o nome antes de reter ou gravar qualquer coisa: uma oferta cujo
        // nome não decifra nunca poderia ser listada nem recusada, e ocuparia
        // uma das vagas do contato.
        manifest::decrypt_name(&*transfer_secret, &manifest.file_id, &manifest.name_encrypted)?;

        let auto_accept_limit = self.auto_accept_file_size_limit()?;
        if manifest.file_size > auto_accept_limit {
            let mut unconfirmed = self.lock_unconfirmed_offers()?;
            if unconfirmed.contains_key(&manifest.file_id) {
                // Não sobrescreve oferta já retida com o mesmo file_id (Menor 1).
                return Ok(());
            }
            if unconfirmed.len() >= MAX_UNCONFIRMED_OFFERS_TOTAL {
                return Ok(());
            }
            let contact_count = unconfirmed
                .values()
                .filter(|o| o.contact_device_id == contact_device_id)
                .count();
            if contact_count >= MAX_UNCONFIRMED_OFFERS_PER_CONTACT {
                return Ok(());
            }

            let manifest_file_id = manifest.file_id;
            unconfirmed.insert(
                manifest.file_id,
                UnconfirmedOffer {
                    contact_device_id,
                    kind,
                    transfer_secret,
                    manifest,
                    manifest_cbor,
                    received_at,
                },
            );
            // Sob a trava das ofertas, como em `remove_unconfirmed_offer`.
            self.emit_offer_event(
                TransferEventKind::OfferAppeared,
                contact_device_id,
                manifest_file_id,
            );
            return Ok(());
        }

        self.start_receiving_transfer(
            contact_device_id,
            kind,
            &*transfer_secret,
            manifest,
            manifest_cbor,
            received_at,
        )
    }

    /// Chamado de dentro de `Core::decrypt_incoming` quando um
    /// `FILE_FEEDBACK` chega — repassa para o `SendTransfer` do `file_id`
    /// indicado, se existir.
    pub(super) fn handle_incoming_file_feedback(
        &self,
        contact_device_id: [u8; DEVICE_ID_LEN],
        body: &[u8],
    ) -> Result<(), FfiError> {
        // `source_blocks` vem do próprio manifesto que este lado já
        // persistiu ao iniciar o envio — não do corpo do feedback (§7.4:
        // o tamanho do bitmap não vai no fio).
        let file_id: [u8; FILE_ID_LEN] = body
            .get(..FILE_ID_LEN)
            .ok_or(FfiError::Internal)?
            .try_into()
            .map_err(|_| FfiError::Internal)?;
        // Expirar antes de aceitar: feedback depois do prazo não ressuscita a oferta.
        // Falha da varredura não impede processar o feedback.
        let _ = self.enforce_transfer_deadlines();
        let stored = self
            .store
            .find_file_transfer(&file_id)?
            .ok_or(FfiError::Internal)?;
        // Só o destinatário da oferta a responde, e só ele encerra o prazo.
        if stored.contact_device_id != contact_device_id || stored.direction != Direction::Sending {
            return Ok(());
        }
        let manifest = Manifest::decode(&stored.manifest_cbor)?;

        let feedback = FileFeedback::decode(body, manifest.source_blocks)?;
        // O primeiro feedback prova que a oferta foi aceita: o prazo acaba aqui,
        // e a retomada deixa de reenviar a oferta.
        if !stored.answered {
            self.store.mark_file_transfer_answered(&file_id)?;
        }
        self.ingest_send_feedback(&stored, &manifest, &feedback)
    }

    /// Chamado de dentro de `Core::decrypt_incoming` quando um
    /// `FILE_COMPLETE` chega — o receptor confirmou a raiz Merkle e o
    /// commit atômico; o emissor não precisa mais guardar nada desta
    /// transferência.
    pub(super) fn handle_incoming_file_complete(&self, body: &[u8]) -> Result<(), FfiError> {
        let complete = transfer::FileComplete::decode(body)?;
        self.end_transfer(&complete.file_id)
    }

    /// Chamado de dentro de `Core::decrypt_incoming` quando um `FILE_REJECT`
    /// chega (§7.7). Só encerra um envio que exista, que seja deste contato e
    /// que ainda esteja em curso; qualquer outra coisa é ignorada sem erro
    /// distinguível, para que um par não consiga sondar transferências alheias.
    pub(super) fn handle_incoming_file_reject(
        &self,
        contact_device_id: [u8; DEVICE_ID_LEN],
        body: &[u8],
    ) -> Result<(), FfiError> {
        // O corpo é exatamente o `file_id`; qualquer outro tamanho é lixo.
        let file_id: [u8; FILE_ID_LEN] = body.try_into().map_err(|_| FfiError::Internal)?;
        let Some(stored) = self.store.find_file_transfer(&file_id)? else {
            return Ok(());
        };
        if stored.direction != Direction::Sending || stored.contact_device_id != contact_device_id {
            return Ok(());
        }
        // A mensagem vem antes: se esta escrita falhar, a linha de transferência
        // ainda existe e um novo `FILE_REJECT` consegue repetir o caminho todo.
        self.store
            .mark_message_rejected_by_file_id(&file_id, &contact_device_id)?;
        self.end_transfer(&file_id)
    }
}

fn offer_event(
    kind: TransferEventKind,
    contact: [u8; DEVICE_ID_LEN],
    file_id: [u8; FILE_ID_LEN],
) -> TransferEventDto {
    TransferEventDto { peer_device_id: contact.to_vec(), file_id: file_id.to_vec(), kind }
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use crate::ffi::core::Core;
    use crate::ffi::types::{DeliveryStateDto, MessageKindDto, SessionStateKind};
    use std::io::Write;

    pub(crate) fn open_core(dir: &tempfile::TempDir) -> Core {
        Core::open(dir.path().to_str().unwrap().to_owned()).unwrap()
    }

    /// Duas `Core` pareadas com sessão já estabelecida — mesmo papel de
    /// `establish()` em `ffi/session.rs`, mas próprio deste módulo (padrão
    /// já usado por `ffi/signaling.rs`: cada arquivo de teste monta o par
    /// que precisa, em vez de compartilhar um helper entre arquivos).
    pub(crate) struct EstablishedPair {
        pub(crate) _dir_a: tempfile::TempDir,
        pub(crate) core_a: Core,
        pub(crate) device_id_a: Vec<u8>,
        pub(crate) _dir_b: tempfile::TempDir,
        pub(crate) core_b: Core,
        pub(crate) device_id_b: Vec<u8>,
    }

    pub(crate) fn established_pair() -> EstablishedPair {
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
        // A resposta é o anúncio de suítes (§10.2), que estes testes não usam.
        pair.core_a
            .feed_handshake(pair.device_id_b.clone(), resp)
            .unwrap();

        pair
    }

    pub(crate) fn fid(bytes: &[u8]) -> [u8; FILE_ID_LEN] {
        bytes.try_into().unwrap()
    }

    pub(crate) fn write_temp_file(dir: &tempfile::TempDir, name: &str, content: &[u8]) -> String {
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

    /// Na LAN o emissor usa o maior símbolo do RaptorQ, só símbolos-fonte (modo
    /// offset), e o arquivo chega íntegro, passando pelo enquadramento TCP.
    #[test]
    fn lan_transfer_uses_lan_symbol_size_and_offset_mode() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let dir_dst = tempfile::tempdir().unwrap();

        let original: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
        let src_path = write_temp_file(&dir_src, "lan.bin", &original);

        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, true)
            .unwrap();

        let stored = pair
            .core_a
            .store
            .find_file_transfer(&fid(&started.file_id))
            .unwrap()
            .unwrap();
        let manifest = Manifest::decode(&stored.manifest_cbor).unwrap();
        assert_eq!(manifest.symbol_size, LAN_SYMBOL_SIZE);

        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();

        let mut symbols_sent = 0u32;
        for _ in 0..10_000 {
            let Some(wire_chunk) = pair
                .core_a
                .next_outgoing_wire_chunk(started.file_id.clone())
                .unwrap()
            else {
                break;
            };
            let mut framed = viska_proto::wire::framing::frame(&wire_chunk).unwrap();
            let wire_chunk = viska_proto::wire::framing::extract_frame(&mut framed)
                .unwrap()
                .expect("pacote de símbolo da LAN precisa passar pelo enquadramento TCP");
            symbols_sent += 1;
            pair.core_b.ingest_incoming_wire_bytes(wire_chunk).unwrap();
            if pair
                .core_b
                .transfer_progress(started.file_id.clone())
                .unwrap()
                .map(|p| p.is_complete)
                .unwrap_or(false)
            {
                break;
            }
            let sealed_feedback = pair
                .core_b
                .file_feedback(pair.device_id_a.clone(), started.file_id.clone())
                .unwrap();
            pair.core_a
                .decrypt_incoming(pair.device_id_b.clone(), sealed_feedback)
                .unwrap();
        }

        let expected_symbols = original.len().div_ceil(LAN_SYMBOL_SIZE as usize) as u32;
        assert_eq!(symbols_sent, expected_symbols, "sem símbolos de reparo na LAN");

        let dst_path = dir_dst.path().join("lan-recebido.bin");
        pair.core_b
            .finish_receive_file(
                pair.device_id_a.clone(),
                started.file_id.clone(),
                dst_path.to_str().unwrap().to_owned(),
            )
            .unwrap();
        assert_eq!(std::fs::read(&dst_path).unwrap(), original);
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
            let sealed_feedback = pair
                .core_b
                .file_feedback(pair.device_id_a.clone(), started.file_id.clone())
                .unwrap();

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
            .decrypt_incoming(pair.device_id_b.clone(), sealed_complete.unwrap())
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

            let sealed_feedback = pair
                .core_b
                .file_feedback(pair.device_id_a.clone(), started.file_id.clone())
                .unwrap();

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
            .decrypt_incoming(pair.device_id_b.clone(), sealed_complete.unwrap())
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

                let sealed_feedback = pair
                    .core_b
                    .file_feedback(pair.device_id_a.clone(), file_id.clone())
                    .unwrap();
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

    /// Leva a sessão de A com B a `Failed` por AEAD adulterado repetido (§11.2).
    pub(crate) fn force_session_failed(pair: &EstablishedPair) {
        // `core_b` precisa de cadeia de envio para adulterar mensagens a `core_a`.
        let hello = pair
            .core_a
            .seal_outgoing_text(pair.device_id_b.clone(), "oi".to_owned())
            .unwrap();
        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), hello.bytes.unwrap())
            .unwrap();
        for _ in 0..9 {
            let mut bytes = pair
                .core_b
                .seal_outgoing_text(pair.device_id_a.clone(), "x".to_owned())
                .unwrap()
                .bytes
                .unwrap();
            let last = bytes.len() - 1;
            bytes[last] ^= 0xff;
            let _ = pair.core_a.decrypt_incoming(pair.device_id_b.clone(), bytes);
        }
        assert!(pair.core_a.session_status(pair.device_id_b.clone()).unwrap().unwrap().state
            == SessionStateKind::Failed);
    }

    pub(crate) fn state_of(pair: &EstablishedPair, message_id: i64) -> DeliveryStateDto {
        pair.core_a
            .list_messages(pair.device_id_b.clone())
            .unwrap()
            .into_iter()
            .find(|m| m.id == message_id)
            .unwrap()
            .delivery_state
    }

    #[test]
    fn reset_session_keeps_unanswered_offer_for_resume() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);
        // O fim do bombeamento no Dart promove a mensagem a `Sent`.
        pair.core_a.mark_message_sent(started.message_id).unwrap();
        force_session_failed(&pair);

        pair.core_a.reset_session(pair.device_id_b.clone()).unwrap();

        assert_eq!(state_of(&pair, started.message_id), DeliveryStateDto::Sent);
        let row = pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().unwrap();
        assert!(!row.answered, "a oferta continua sem resposta e será reenviada na retomada");
    }

    #[test]
    fn reset_session_keeps_accepted_transfer() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);
        pair.core_a.mark_message_sent(started.message_id).unwrap();
        pair.core_b.accept_file_offer(started.file_id.clone()).unwrap();
        let feedback = pair
            .core_b
            .file_feedback(pair.device_id_a.clone(), started.file_id.clone())
            .unwrap();
        pair.core_a.decrypt_incoming(pair.device_id_b.clone(), feedback).unwrap();
        force_session_failed(&pair);

        pair.core_a.reset_session(pair.device_id_b.clone()).unwrap();

        assert_eq!(state_of(&pair, started.message_id), DeliveryStateDto::Sent);
        let row = pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().unwrap();
        assert!(row.answered);
        assert!(pair.core_a.transfer_progress(started.file_id.clone()).unwrap().is_some());
    }

    #[test]
    fn reset_session_keeps_answered_offer() {
        // Recusada: estado final, a linha já não existe.
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, rejected) = pair_with_pending_offer(&dir_src);
        let sealed = pair.core_b.reject_file_offer(rejected.file_id.clone()).unwrap().unwrap();
        pair.core_a.decrypt_incoming(pair.device_id_b.clone(), sealed).unwrap();

        // Concluída: o `FILE_COMPLETE` apaga a linha e o handle e a mensagem fica `Sent`.
        let src_path = write_temp_file(&dir_src, "feito.bin", &[3u8; 2_000]);
        let done = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();
        pair.core_a.mark_message_sent(done.message_id).unwrap();
        let complete = transfer::FileComplete { file_id: fid(&done.file_id) };
        pair.core_a.handle_incoming_file_complete(&complete.encode()).unwrap();
        assert!(pair.core_a.store.find_file_transfer(&fid(&done.file_id)).unwrap().is_none());

        force_session_failed(&pair);
        pair.core_a.reset_session(pair.device_id_b.clone()).unwrap();

        assert_eq!(state_of(&pair, rejected.message_id), DeliveryStateDto::Rejected);
        assert_eq!(state_of(&pair, done.message_id), DeliveryStateDto::Sent);
    }

    #[test]
    fn reset_session_noop_when_established() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);
        pair.core_a.mark_message_sent(started.message_id).unwrap();

        pair.core_a.reset_session(pair.device_id_b.clone()).unwrap();

        assert_eq!(state_of(&pair, started.message_id), DeliveryStateDto::Sent);
        let row = pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().unwrap();
        assert!(!row.answered);
    }

    #[test]
    fn reset_session_keeps_outgoing_transfer_running() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let src_path = write_temp_file(&dir_src, "a.bin", &[7u8; 4096]);
        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();
        force_session_failed(&pair);

        pair.core_a.reset_session(pair.device_id_b.clone()).unwrap();

        assert!(pair.core_a.transfer_progress(started.file_id.clone()).unwrap().is_some());
        assert_eq!(pair.core_a.list_active_file_transfer_ids().unwrap(), vec![started.file_id.clone()]);
        assert_eq!(state_of(&pair, started.message_id), DeliveryStateDto::Pending);
    }

    /// Testa que transferência multibloko (> 16 MiB no DataChannel WebRTC, D6)
    /// pausa sem feedback e completa com sucesso após envio de FILE_FEEDBACK (U-02).
    #[test]
    fn multiblock_file_completes_with_file_feedback() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let dir_dst = tempfile::tempdir().unwrap();

        // 16 MiB + 4096 B => 2 blocos: Bloco 0 (1024 símbolos) e Bloco 1 (1 símbolo).
        let file_len = (16 * 1024 * 1024) + 4096;
        let mut original = vec![0u8; file_len];
        for (i, byte) in original.iter_mut().enumerate() {
            *byte = (i % 251) as u8;
        }
        let src_path = write_temp_file(&dir_src, "arquivo_grande.bin", &original);

        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();

        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();

        let offers = pair
            .core_b
            .pending_file_offers(pair.device_id_a.clone())
            .unwrap();
        assert_eq!(offers.len(), 1);
        assert_eq!(offers[0].file_id, started.file_id);

        // 1. Transmite os símbolos-fonte do bloco 0 (1024 símbolos).
        for _ in 0..1024 {
            let wire_chunk = pair
                .core_a
                .next_outgoing_wire_chunk(started.file_id.clone())
                .unwrap()
                .expect("símbolo-fonte do bloco 0 deve existir");
            pair.core_b
                .ingest_incoming_wire_bytes(wire_chunk)
                .unwrap()
                .expect("wire chunk de bloco 0 deve ser aceito");
        }

        let progress_b = pair
            .core_b
            .transfer_progress(started.file_id.clone())
            .unwrap()
            .unwrap();
        assert_eq!(progress_b.blocks_done, 1);
        assert_eq!(progress_b.total_blocks, 2);
        assert!(!progress_b.is_complete);

        // Sem feedback, o emissor ainda considera o bloco 0 em andamento (U-02):
        // o progresso do emissor mostra blocks_done == 0.
        let progress_a = pair
            .core_a
            .transfer_progress(started.file_id.clone())
            .unwrap()
            .unwrap();
        assert_eq!(
            progress_a.blocks_done, 0,
            "emissor sem feedback não deve avançar para bloco 1"
        );

        // 2. Receptor envia FILE_FEEDBACK (§7.4, U-02).
        let sealed_feedback = pair
            .core_b
            .file_feedback(pair.device_id_a.clone(), started.file_id.clone())
            .unwrap();

        pair.core_a
            .decrypt_incoming(pair.device_id_b.clone(), sealed_feedback)
            .unwrap();

        // 3. Com o feedback ingerido, o emissor avança para o bloco 1!
        let progress_a_after = pair
            .core_a
            .transfer_progress(started.file_id.clone())
            .unwrap()
            .unwrap();
        assert_eq!(
            progress_a_after.blocks_done, 1,
            "emissor deve avançar para o bloco 1 após feedback"
        );

        // Transmite o bloco 1 (1 símbolo).
        let wire_chunk_b1 = pair
            .core_a
            .next_outgoing_wire_chunk(started.file_id.clone())
            .unwrap()
            .expect("símbolo do bloco 1 deve existir");
        pair.core_b
            .ingest_incoming_wire_bytes(wire_chunk_b1)
            .unwrap()
            .expect("wire chunk de bloco 1 deve ser aceito");

        let final_progress = pair
            .core_b
            .transfer_progress(started.file_id.clone())
            .unwrap()
            .unwrap();
        assert_eq!(final_progress.blocks_done, 2);
        assert_eq!(final_progress.total_blocks, 2);
        assert!(final_progress.is_complete);

        let dst_path = dir_dst.path().join("arquivo_grande_recebido.bin");
        let sealed_complete = pair
            .core_b
            .finish_receive_file(
                pair.device_id_a.clone(),
                started.file_id.clone(),
                dst_path.to_str().unwrap().to_owned(),
            )
            .unwrap();

        let received = std::fs::read(&dst_path).unwrap();
        assert_eq!(received.len(), original.len());
        assert_eq!(received, original);

        pair.core_a
            .decrypt_incoming(pair.device_id_b.clone(), sealed_complete.unwrap())
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
    fn file_metadata_above_limit_does_not_create_file_transfers_row_or_staging() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();

        // Limite padrão é 100 MiB.
        assert_eq!(
            pair.core_b.auto_accept_file_size_limit().unwrap(),
            DEFAULT_AUTO_ACCEPT_FILE_SIZE_LIMIT
        );

        // Configura teto de auto-aceite para 10 KB.
        pair.core_b.set_auto_accept_file_size_limit(10_000).unwrap();
        assert_eq!(pair.core_b.auto_accept_file_size_limit().unwrap(), 10_000);
        assert_eq!(
            pair.core_b
                .store
                .get_config(CONFIG_KEY_AUTO_ACCEPT_FILE_SIZE_LIMIT)
                .unwrap()
                .as_deref(),
            Some("10000")
        );

        // Arquivo com 20 KB (> 10 KB de teto).
        let original: Vec<u8> = (0..20_000u32).map(|i| (i % 251) as u8).collect();
        let src_path = write_temp_file(&dir_src, "arquivo_pesado.bin", &original);

        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();

        let opened = pair
            .core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();
        assert!(opened.is_none());

        // CRITÉRIO DE ACEITE DA ISSUE #23:
        // FILE_METADATA acima do limite NÃO cria linha em file_transfers.
        assert!(
            pair.core_b
                .store
                .find_file_transfer(&fid(&started.file_id))
                .unwrap()
                .is_none(),
            "FILE_METADATA acima do limite não deve criar linha em file_transfers"
        );
        assert!(
            pair.core_b
                .list_active_file_transfer_ids()
                .unwrap()
                .is_empty(),
            "nenhuma transferência deve estar ativa no banco"
        );

        // Também não deve alocar arquivo .staging em disco.
        let staging_file = pair
            .core_b
            .staging_dir
            .join(format!("{}.staging", hex::encode(&started.file_id)));
        assert!(
            !staging_file.exists(),
            "arquivo .staging não deve ser criado em disco sem confirmação do usuário"
        );

        // Não aparece em pending_file_offers (que lista transferências já em curso no banco).
        let pending = pair
            .core_b
            .pending_file_offers(pair.device_id_a.clone())
            .unwrap();
        assert!(pending.is_empty());

        // Oferta deve estar listada em unconfirmed_file_offers aguardando confirmação.
        let unconfirmed = pair
            .core_b
            .unconfirmed_file_offers(pair.device_id_a.clone())
            .unwrap();
        assert_eq!(unconfirmed.len(), 1);
        assert_eq!(unconfirmed[0].file_id, started.file_id);
        assert_eq!(unconfirmed[0].name, "arquivo_pesado.bin");
        assert_eq!(unconfirmed[0].file_size, 20_000);
    }

    #[test]
    fn unconfirmed_file_offer_can_be_accepted_and_completed() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let dir_dst = tempfile::tempdir().unwrap();

        pair.core_b.set_auto_accept_file_size_limit(10_000).unwrap();

        let original: Vec<u8> = (0..20_000u32).map(|i| (i % 251) as u8).collect();
        let src_path = write_temp_file(&dir_src, "aprovado.bin", &original);

        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();

        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();

        // Inicialmente retida:
        assert!(pair
            .core_b
            .store
            .find_file_transfer(&fid(&started.file_id))
            .unwrap()
            .is_none());

        // Usuário aceita a oferta:
        pair.core_b
            .accept_file_offer(started.file_id.clone())
            .unwrap();

        // Agora a linha em file_transfers e o arquivo .staging devem existir:
        assert!(pair
            .core_b
            .store
            .find_file_transfer(&fid(&started.file_id))
            .unwrap()
            .is_some());
        let staging_file = pair
            .core_b
            .staging_dir
            .join(format!("{}.staging", hex::encode(&started.file_id)));
        assert!(staging_file.exists());

        // Saiu de unconfirmed e entrou em pending_file_offers:
        assert!(pair
            .core_b
            .unconfirmed_file_offers(pair.device_id_a.clone())
            .unwrap()
            .is_empty());
        let pending = pair
            .core_b
            .pending_file_offers(pair.device_id_a.clone())
            .unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].file_id, started.file_id);

        // Transfere o arquivo normalmente:
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
                .unwrap();
        }

        let dst_path = dir_dst.path().join("aprovado_recebido.bin");
        pair.core_b
            .finish_receive_file(
                pair.device_id_a.clone(),
                started.file_id.clone(),
                dst_path.to_str().unwrap().to_owned(),
            )
            .unwrap();
        assert_eq!(std::fs::read(&dst_path).unwrap(), original);
    }

    /// Monta A (emissor) e B (receptor com auto-aceite baixo), com a oferta de
    /// A já retida em B. Devolve o par e o `SendFileStartedDto`.
    pub(crate) fn pair_with_pending_offer(dir_src: &tempfile::TempDir) -> (EstablishedPair, SendFileStartedDto) {
        let pair = established_pair();
        pair.core_b.set_auto_accept_file_size_limit(5_000).unwrap();
        let original: Vec<u8> = (0..15_000u32).map(|i| (i % 251) as u8).collect();
        let src_path = write_temp_file(dir_src, "recusado.bin", &original);
        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();
        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata.clone())
            .unwrap();
        (pair, started)
    }

    #[test]
    fn rejected_offer_ends_the_senders_transfer_and_marks_the_message() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);

        let sealed = pair
            .core_b
            .reject_file_offer(started.file_id.clone())
            .unwrap()
            .expect("sessão estabelecida sela o aviso");
        pair.core_a
            .decrypt_incoming(pair.device_id_b.clone(), sealed)
            .unwrap();

        assert!(pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_none());
        assert_eq!(
            pair.core_a.next_outgoing_wire_chunk(started.file_id.clone()).unwrap(),
            None
        );
        let timeline = pair.core_a.list_messages(pair.device_id_b.clone()).unwrap();
        assert_eq!(timeline[0].delivery_state, DeliveryStateDto::Rejected);

        // Um mark_sent tardio (fim do bombeamento no Dart) não apaga a recusa.
        pair.core_a.mark_message_sent(started.message_id).unwrap();
        let timeline = pair.core_a.list_messages(pair.device_id_b.clone()).unwrap();
        assert_eq!(timeline[0].delivery_state, DeliveryStateDto::Rejected);
    }

    #[test]
    fn rejected_offer_without_session_still_discards_locally() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);
        pair.core_b.lock_sessions().unwrap().clear();

        let sealed = pair.core_b.reject_file_offer(started.file_id.clone()).unwrap();

        assert!(sealed.is_none());
        assert!(pair
            .core_b
            .unconfirmed_file_offers(pair.device_id_a.clone())
            .unwrap()
            .is_empty());
    }

    #[test]
    fn rejected_offer_from_another_contact_or_unknown_file_id_changes_nothing() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);
        let other_contact = [0xEEu8; DEVICE_ID_LEN];

        // Outro contato citando um file_id que existe:
        pair.core_a
            .handle_incoming_file_reject(other_contact, &started.file_id)
            .unwrap();
        // file_id desconhecido, vindo do contato certo:
        pair.core_a
            .handle_incoming_file_reject(to_device_id(pair.device_id_b.clone()).unwrap(), &[0x77; FILE_ID_LEN])
            .unwrap();
        // Corpo com tamanho errado:
        assert!(pair
            .core_a
            .handle_incoming_file_reject(to_device_id(pair.device_id_b.clone()).unwrap(), &[0; 3])
            .is_err());

        assert!(pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_some());
        let timeline = pair.core_a.list_messages(pair.device_id_b.clone()).unwrap();
        assert_eq!(timeline[0].delivery_state, DeliveryStateDto::Pending);
    }

    #[test]
    fn rejected_offer_does_not_touch_a_receiving_transfer() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);
        // B ainda não aceitou; A forja um reject do file_id que B recebe.
        pair.core_b.accept_file_offer(started.file_id.clone()).unwrap();

        pair.core_b
            .handle_incoming_file_reject(to_device_id(pair.device_id_a.clone()).unwrap(), &started.file_id)
            .unwrap();

        assert!(pair.core_b.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_some());
    }

    #[test]
    fn unconfirmed_file_offer_can_be_rejected() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();

        pair.core_b.set_auto_accept_file_size_limit(5_000).unwrap();

        let original: Vec<u8> = (0..15_000u32).map(|i| (i % 251) as u8).collect();
        let src_path = write_temp_file(&dir_src, "rejeitado.bin", &original);

        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();

        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();

        assert_eq!(
            pair.core_b
                .unconfirmed_file_offers(pair.device_id_a.clone())
                .unwrap()
                .len(),
            1
        );

        // Usuário rejeita a oferta:
        pair.core_b
            .reject_file_offer(started.file_id.clone())
            .unwrap();

        // Oferta é removida da memória:
        assert!(pair
            .core_b
            .unconfirmed_file_offers(pair.device_id_a.clone())
            .unwrap()
            .is_empty());

        // Nenhuma linha criada em file_transfers nem em staging:
        assert!(pair
            .core_b
            .store
            .find_file_transfer(&fid(&started.file_id))
            .unwrap()
            .is_none());
        let staging_file = pair
            .core_b
            .staging_dir
            .join(format!("{}.staging", hex::encode(&started.file_id)));
        assert!(!staging_file.exists());
    }

    #[test]
    fn cancel_transfer_removes_unconfirmed_offer() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();

        pair.core_b.set_auto_accept_file_size_limit(5_000).unwrap();

        let original: Vec<u8> = (0..15_000u32).map(|i| (i % 251) as u8).collect();
        let src_path = write_temp_file(&dir_src, "cancelado.bin", &original);

        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();

        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();

        assert_eq!(
            pair.core_b
                .unconfirmed_file_offers(pair.device_id_a.clone())
                .unwrap()
                .len(),
            1
        );

        pair.core_b.cancel_transfer(started.file_id.clone()).unwrap();

        assert!(pair
            .core_b
            .unconfirmed_file_offers(pair.device_id_a.clone())
            .unwrap()
            .is_empty());
    }

    #[test]
    fn late_accept_on_lan_with_exhausted_sender_completes() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let dir_dst = tempfile::tempdir().unwrap();

        // Limite de 10 KB para reter o arquivo de 150 KB.
        pair.core_b.set_auto_accept_file_size_limit(10_000).unwrap();

        let original: Vec<u8> = (0..150_000u32).map(|i| (i % 251) as u8).collect();
        let src_path = write_temp_file(&dir_src, "lan_late_accept.bin", &original);

        // use_lan = true: ativa TransferMode::Offset (D6, D23).
        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, true)
            .unwrap();

        // Receptor recebe o FILE_METADATA e retém a oferta (sem auto-aceite).
        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();

        assert_eq!(
            pair.core_b
                .unconfirmed_file_offers(pair.device_id_a.clone())
                .unwrap()
                .len(),
            1
        );

        // Emissor bombeia todos os símbolos até next_outgoing_wire_chunk retornar None
        // ANTES de o receptor aceitar a oferta (reprodução do Bloqueante 1 da revisão).
        let mut pumped_before_accept = 0;
        while let Some(wire_chunk) = pair
            .core_a
            .next_outgoing_wire_chunk(started.file_id.clone())
            .unwrap()
        {
            // Receptor descarta silenciosamente porque a oferta ainda não foi aceita.
            let res = pair.core_b.ingest_incoming_wire_bytes(wire_chunk).unwrap();
            assert!(res.is_none());
            pumped_before_accept += 1;
        }
        assert!(pumped_before_accept > 0, "emissor deve ter bombeado símbolos");

        // Agora o usuário aceita tardiamente a oferta:
        pair.core_b
            .accept_file_offer(started.file_id.clone())
            .unwrap();

        // Loop de troca de feedback e chunks na LAN:
        for _ in 0..10_000 {
            let progress = pair
                .core_b
                .transfer_progress(started.file_id.clone())
                .unwrap();
            if progress.map(|p| p.is_complete).unwrap_or(false) {
                break;
            }

            // Receptor gera FILE_FEEDBACK e entrega ao emissor.
            if let Ok(sealed_fb) = pair
                .core_b
                .file_feedback(pair.device_id_a.clone(), started.file_id.clone())
            {
                pair.core_a
                    .decrypt_incoming(pair.device_id_b.clone(), sealed_fb)
                    .unwrap();
            }

            // Emissor (tendo reiniciado o bloco via ingest_feedback) volta a emitir!
            while let Some(wire_chunk) = pair
                .core_a
                .next_outgoing_wire_chunk(started.file_id.clone())
                .unwrap()
            {
                pair.core_b.ingest_incoming_wire_bytes(wire_chunk).unwrap();
            }
        }

        let dst_path = dir_dst.path().join("lan_late_accept_recebido.bin");
        pair.core_b
            .finish_receive_file(
                pair.device_id_a.clone(),
                started.file_id.clone(),
                dst_path.to_str().unwrap().to_owned(),
            )
            .unwrap();
        assert_eq!(std::fs::read(&dst_path).unwrap(), original);
    }

    #[test]
    fn late_accept_mid_block_on_lan_recovers_once_feedback_follows_exhaustion() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let dir_dst = tempfile::tempdir().unwrap();
        pair.core_b.set_auto_accept_file_size_limit(10_000).unwrap();

        let original: Vec<u8> = (0..650_000u32).map(|i| (i % 251) as u8).collect();
        let src_path = write_temp_file(&dir_src, "lan_mid_block.bin", &original);
        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, true)
            .unwrap();
        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();

        let dropped = pair
            .core_a
            .next_outgoing_wire_chunk(started.file_id.clone())
            .unwrap()
            .unwrap();
        assert!(pair.core_b.ingest_incoming_wire_bytes(dropped).unwrap().is_none());
        pair.core_b.accept_file_offer(started.file_id.clone()).unwrap();

        let deliver_feedback = || {
            let feedback = pair
                .core_b
                .file_feedback(pair.device_id_a.clone(), started.file_id.clone())
                .unwrap();
            pair.core_a
                .decrypt_incoming(pair.device_id_b.clone(), feedback)
                .unwrap();
        };
        let pump = || {
            while let Some(chunk) = pair
                .core_a
                .next_outgoing_wire_chunk(started.file_id.clone())
                .unwrap()
            {
                pair.core_b.ingest_incoming_wire_bytes(chunk).unwrap();
            }
        };
        let is_complete = || {
            pair.core_b
                .transfer_progress(started.file_id.clone())
                .unwrap()
                .unwrap()
                .is_complete
        };

        // O feedback que chega antes do esgotamento não reinicia o bloco. É
        // por isso que o receptor precisa continuar mandando sem chegar chunk.
        deliver_feedback();
        pump();
        assert!(!is_complete(), "falta o símbolo descartado antes do aceite");

        deliver_feedback();
        pump();
        assert!(is_complete());

        let dst_path = dir_dst.path().join("lan_mid_block_recebido.bin");
        pair.core_b
            .finish_receive_file(
                pair.device_id_a.clone(),
                started.file_id.clone(),
                dst_path.to_str().unwrap().to_owned(),
            )
            .unwrap();
        assert_eq!(std::fs::read(&dst_path).unwrap(), original);
    }

    #[test]
    fn accept_can_be_retried_after_staging_failure() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let dir_dst = tempfile::tempdir().unwrap();
        pair.core_b.set_auto_accept_file_size_limit(10_000).unwrap();

        let original: Vec<u8> = (0..20_000u32).map(|i| (i % 251) as u8).collect();
        let src_path = write_temp_file(&dir_src, "nova_tentativa.bin", &original);
        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();
        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();

        // Um arquivo no lugar do diretório faz a criação do .staging falhar.
        let staging = pair.core_b.staging_dir.clone();
        let _ = std::fs::remove_dir_all(&staging);
        std::fs::write(&staging, b"nao e um diretorio").unwrap();

        assert!(pair.core_b.accept_file_offer(started.file_id.clone()).is_err());
        assert!(
            pair.core_b
                .store
                .find_file_transfer(&fid(&started.file_id))
                .unwrap()
                .is_none(),
            "aceite que falhou não pode deixar linha em file_transfers"
        );
        assert_eq!(
            pair.core_b
                .unconfirmed_file_offers(pair.device_id_a.clone())
                .unwrap()
                .len(),
            1,
            "aceite que falhou não pode perder a oferta"
        );

        std::fs::remove_file(&staging).unwrap();
        pair.core_b.accept_file_offer(started.file_id.clone()).unwrap();
        assert!(pair
            .core_b
            .unconfirmed_file_offers(pair.device_id_a.clone())
            .unwrap()
            .is_empty());

        while let Some(chunk) = pair
            .core_a
            .next_outgoing_wire_chunk(started.file_id.clone())
            .unwrap()
        {
            pair.core_b.ingest_incoming_wire_bytes(chunk).unwrap();
        }
        let dst_path = dir_dst.path().join("nova_tentativa_recebido.bin");
        pair.core_b
            .finish_receive_file(
                pair.device_id_a.clone(),
                started.file_id.clone(),
                dst_path.to_str().unwrap().to_owned(),
            )
            .unwrap();
        assert_eq!(std::fs::read(&dst_path).unwrap(), original);
    }

    /// Retém em `core_b` uma oferta nova de `core_a` e devolve seu `file_id`.
    fn retain_offer(pair: &EstablishedPair, dir: &tempfile::TempDir, name: &str) -> Vec<u8> {
        let src_path = write_temp_file(dir, name, &[7u8; 2_000]);
        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();
        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();
        started.file_id
    }

    #[test]
    fn retained_offers_stop_at_the_per_contact_cap() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        pair.core_b.set_auto_accept_file_size_limit(1_000).unwrap();

        let file_ids: Vec<Vec<u8>> = (0..=MAX_UNCONFIRMED_OFFERS_PER_CONTACT)
            .map(|i| retain_offer(&pair, &dir_src, &format!("oferta_{i}.bin")))
            .collect();

        let retained = pair
            .core_b
            .unconfirmed_file_offers(pair.device_id_a.clone())
            .unwrap();
        assert_eq!(retained.len(), MAX_UNCONFIRMED_OFFERS_PER_CONTACT);
        assert!(
            retained.iter().all(|o| &o.file_id != file_ids.last().unwrap()),
            "a oferta acima do teto é a descartada, não uma já retida"
        );
    }

    #[test]
    fn retained_offers_stop_at_the_total_cap_across_contacts() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        pair.core_b.set_auto_accept_file_size_limit(1_000).unwrap();

        let template_id = fid(&retain_offer(&pair, &dir_src, "modelo.bin"));
        {
            let mut offers = pair.core_b.lock_unconfirmed_offers().unwrap();
            let (manifest, manifest_cbor, secret) = {
                let template = offers.get(&template_id).unwrap();
                (
                    template.manifest.clone(),
                    template.manifest_cbor.clone(),
                    template.transfer_secret.clone(),
                )
            };
            for i in 1..MAX_UNCONFIRMED_OFFERS_TOTAL {
                let mut file_id = [0u8; FILE_ID_LEN];
                file_id[..8].copy_from_slice(&(i as u64).to_be_bytes());
                let mut contact_device_id = [0xEE; DEVICE_ID_LEN];
                contact_device_id[0] = (i % MAX_UNCONFIRMED_OFFERS_PER_CONTACT) as u8;
                offers.insert(
                    file_id,
                    UnconfirmedOffer {
                        contact_device_id,
                        kind: TransferKind::File,
                        transfer_secret: secret.clone(),
                        manifest: manifest.clone(),
                        manifest_cbor: manifest_cbor.clone(),
                        received_at: 0,
                    },
                );
            }
            assert_eq!(offers.len(), MAX_UNCONFIRMED_OFFERS_TOTAL);
        }

        retain_offer(&pair, &dir_src, "acima_do_teto.bin");

        assert_eq!(
            pair.core_b.lock_unconfirmed_offers().unwrap().len(),
            MAX_UNCONFIRMED_OFFERS_TOTAL
        );
    }

    #[test]
    fn repeated_file_id_does_not_overwrite_retained_offer() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        pair.core_b.set_auto_accept_file_size_limit(1_000).unwrap();

        let file_id = fid(&retain_offer(&pair, &dir_src, "original.bin"));
        let body = {
            let mut offers = pair.core_b.lock_unconfirmed_offers().unwrap();
            let offer = offers.get_mut(&file_id).unwrap();
            offer.received_at = -1;
            transfer::encode_metadata_body(
                offer.kind,
                &offer.transfer_secret,
                &offer.manifest,
            )
            .unwrap()
        };
        let contact = to_device_id(pair.device_id_a.clone()).unwrap();

        pair.core_b.handle_incoming_file_metadata(contact, zeroize::Zeroizing::new(body)).unwrap();

        let offers = pair.core_b.lock_unconfirmed_offers().unwrap();
        assert_eq!(offers.len(), 1);
        assert_eq!(offers.get(&file_id).unwrap().received_at, -1);
    }

    /// Corpo de `FILE_METADATA` válido, mas com `name_encrypted` adulterado
    /// (a tag AEAD do nome não confere), e um `file_id` novo para não colidir
    /// com a oferta de onde foi derivado.
    fn undecryptable_name_body(pair: &EstablishedPair, dir: &tempfile::TempDir) -> (Vec<u8>, [u8; FILE_ID_LEN]) {
        let file_id = fid(&retain_offer(pair, dir, "ruim.bin"));
        let mut offer = pair.core_b.lock_unconfirmed_offers().unwrap().remove(&file_id).unwrap();
        offer.manifest.file_id = [0xEE; FILE_ID_LEN];
        offer.manifest.name_encrypted[0] ^= 0x01;
        let body = transfer::encode_metadata_body(offer.kind, &offer.transfer_secret, &offer.manifest).unwrap();
        (body, offer.manifest.file_id)
    }

    fn staging_entries(core: &Core) -> usize {
        std::fs::read_dir(&core.staging_dir).map_or(0, |d| d.count())
    }

    #[test]
    fn undecryptable_name_above_limit_is_not_retained() {
        let pair = established_pair();
        let dir = tempfile::tempdir().unwrap();
        pair.core_b.set_auto_accept_file_size_limit(1_000).unwrap();
        let (body, _) = undecryptable_name_body(&pair, &dir);
        let contact = to_device_id(pair.device_id_a.clone()).unwrap();

        assert!(pair.core_b.handle_incoming_file_metadata(contact, zeroize::Zeroizing::new(body)).is_err());

        assert!(pair.core_b.lock_unconfirmed_offers().unwrap().is_empty());
    }

    #[test]
    fn undecryptable_name_below_limit_creates_no_row_or_staging() {
        let pair = established_pair();
        let dir = tempfile::tempdir().unwrap();
        pair.core_b.set_auto_accept_file_size_limit(1_000).unwrap();
        let (body, _) = undecryptable_name_body(&pair, &dir);
        pair.core_b.set_auto_accept_file_size_limit(u64::MAX).unwrap();
        let contact = to_device_id(pair.device_id_a.clone()).unwrap();
        let staging_before = staging_entries(&pair.core_b);

        assert!(pair.core_b.handle_incoming_file_metadata(contact, zeroize::Zeroizing::new(body)).is_err());

        assert_eq!(staging_entries(&pair.core_b), staging_before);
        assert!(pair.core_b.pending_file_offers(pair.device_id_a.clone()).unwrap().is_empty());
        assert!(pair
            .core_b
            .store
            .list_file_transfers_for_contact(&contact, Direction::Receiving)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn undecryptable_name_in_retained_offer_does_not_hide_valid_offer() {
        let pair = established_pair();
        let dir = tempfile::tempdir().unwrap();
        pair.core_b.set_auto_accept_file_size_limit(1_000).unwrap();
        let valid = retain_offer(&pair, &dir, "boa.bin");
        // Simula uma oferta gravada antes da correção: nome ruim já retido.
        let (body, bad_id) = undecryptable_name_body(&pair, &dir);
        let (kind, secret, manifest) = transfer::decode_metadata_body(&body).unwrap();
        let manifest_cbor = manifest.encode().unwrap();
        pair.core_b.lock_unconfirmed_offers().unwrap().insert(
            bad_id,
            UnconfirmedOffer {
                contact_device_id: to_device_id(pair.device_id_a.clone()).unwrap(),
                kind,
                transfer_secret: secret,
                manifest,
                manifest_cbor,
                received_at: 0,
            },
        );

        let offers = pair.core_b.unconfirmed_file_offers(pair.device_id_a.clone()).unwrap();

        assert_eq!(offers.len(), 1);
        assert_eq!(offers[0].file_id, valid);
    }

    #[test]
    fn undecryptable_name_in_stored_row_does_not_fail_pending_file_offers() {
        let pair = established_pair();
        let dir = tempfile::tempdir().unwrap();
        pair.core_b.set_auto_accept_file_size_limit(1_000).unwrap();
        let (body, bad_id) = undecryptable_name_body(&pair, &dir);
        let (kind, secret, manifest) = transfer::decode_metadata_body(&body).unwrap();
        let contact = to_device_id(pair.device_id_a.clone()).unwrap();
        pair.core_b
            .store
            .insert_file_transfer(&bad_id, Direction::Receiving, &contact, &manifest.encode().unwrap(), &*secret, 0, kind)
            .unwrap();
        // Uma transferência boa do mesmo contato precisa continuar listada.
        pair.core_b.set_auto_accept_file_size_limit(u64::MAX).unwrap();
        let good = retain_offer(&pair, &dir, "boa.bin");

        let offers = pair.core_b.pending_file_offers(pair.device_id_a.clone()).unwrap();

        assert_eq!(offers.len(), 1);
        assert_eq!(offers[0].file_id, good);
    }

    #[test]
    fn accept_and_reject_of_unknown_offer_return_offer_not_found() {
        let pair = established_pair();

        let fake_fid = vec![42u8; FILE_ID_LEN];
        assert_eq!(
            pair.core_b.accept_file_offer(fake_fid.clone()),
            Err(FfiError::OfferNotFound)
        );
        assert_eq!(
            pair.core_b.reject_file_offer(fake_fid),
            Err(FfiError::OfferNotFound)
        );
    }

    #[test]
    fn auto_accept_limit_change_does_not_affect_retained_offers() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        pair.core_b.set_auto_accept_file_size_limit(1_000).unwrap();

        let file_id = retain_offer(&pair, &dir_src, "retida.bin");

        // O limite só é lido na chegada do FILE_METADATA: subir o teto depois
        // não promove a oferta já retida a transferência automática.
        pair.core_b
            .set_auto_accept_file_size_limit(u64::MAX)
            .unwrap();

        let retained = pair
            .core_b
            .unconfirmed_file_offers(pair.device_id_a.clone())
            .unwrap();
        assert_eq!(retained.len(), 1);
        assert_eq!(retained[0].file_id, file_id);
        assert!(pair
            .core_b
            .store
            .find_file_transfer(&fid(&file_id))
            .unwrap()
            .is_none());
    }

    #[test]
    fn auto_accept_limit_change_does_not_affect_transfer_in_progress() {
        let pair = established_pair();
        let dir_src = tempfile::tempdir().unwrap();
        let dir_dst = tempfile::tempdir().unwrap();
        pair.core_b
            .set_auto_accept_file_size_limit(u64::MAX)
            .unwrap();

        let original: Vec<u8> = (0..20_000u32).map(|i| (i % 251) as u8).collect();
        let src_path = write_temp_file(&dir_src, "em_andamento.bin", &original);
        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), src_path, false)
            .unwrap();
        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();
        assert!(pair
            .core_b
            .store
            .find_file_transfer(&fid(&started.file_id))
            .unwrap()
            .is_some());

        // Reduzir o teto a zero com a recepção já aceita não pode abortá-la.
        pair.core_b.set_auto_accept_file_size_limit(0).unwrap();

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
            pair.core_b.ingest_incoming_wire_bytes(wire_chunk).unwrap();
        }

        let dst_path = dir_dst.path().join("em_andamento_recebido.bin");
        pair.core_b
            .finish_receive_file(
                pair.device_id_a.clone(),
                started.file_id.clone(),
                dst_path.to_str().unwrap().to_owned(),
            )
            .unwrap();
        assert_eq!(std::fs::read(&dst_path).unwrap(), original);
    }

    #[test]
    fn lock_seals_a_file_reject_for_each_retained_offer() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_pending_offer(&dir_src);

        let notices = pair.core_b.lock().unwrap();

        assert_eq!(notices.len(), 1);
        assert_eq!(notices[0].peer_device_id, pair.device_id_a);
        pair.core_a
            .decrypt_incoming(pair.device_id_b.clone(), notices[0].bytes.clone())
            .unwrap();
        let timeline = pair.core_a.list_messages(pair.device_id_b.clone()).unwrap();
        assert_eq!(timeline[0].delivery_state, DeliveryStateDto::Rejected);
        assert!(pair.core_a.store.find_file_transfer(&fid(&started.file_id)).unwrap().is_none());
    }

    #[test]
    fn lock_without_an_established_session_returns_no_notice() {
        let dir_src = tempfile::tempdir().unwrap();
        let (pair, _started) = pair_with_pending_offer(&dir_src);
        pair.core_b.lock_sessions().unwrap().clear();

        assert!(pair.core_b.lock().unwrap().is_empty());
    }

    #[test]
    fn lock_without_retained_offers_returns_no_notice() {
        let pair = established_pair();

        assert!(pair.core_b.lock().unwrap().is_empty());
    }

    type SeenOffers = std::sync::Arc<std::sync::Mutex<Vec<TransferEventDto>>>;

    fn watch_offers(core: &Core) -> SeenOffers {
        let seen: SeenOffers = Default::default();
        let sink_seen = std::sync::Arc::clone(&seen);
        core.set_transfer_event_sink(Box::new(move |e| sink_seen.lock().unwrap().push(e)))
            .unwrap();
        seen
    }

    /// Par com B recebendo ofertas retidas (limite de auto-aceite baixo) e uma
    /// oferta de A para B já entregue.
    fn pair_with_retained_offer(dir: &tempfile::TempDir) -> (EstablishedPair, SendFileStartedDto) {
        let pair = established_pair();
        pair.core_b.set_auto_accept_file_size_limit(1_000).unwrap();
        let path = write_temp_file(dir, "grande.bin", &vec![7u8; 5_000]);
        let started = pair
            .core_a
            .start_send_file(pair.device_id_b.clone(), path, false)
            .unwrap();
        (pair, started)
    }

    #[test]
    fn retained_offer_emits_appeared_with_only_file_id_and_contact() {
        let dir = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_retained_offer(&dir);
        let seen = watch_offers(&pair.core_b);

        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();

        let seen = seen.lock().unwrap();
        assert_eq!(
            *seen,
            vec![TransferEventDto {
                peer_device_id: pair.device_id_a.clone(),
                file_id: started.file_id.clone(),
                kind: TransferEventKind::OfferAppeared,
            }]
        );
    }

    #[test]
    fn auto_accepted_offer_emits_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_retained_offer(&dir);
        pair.core_b.set_auto_accept_file_size_limit(1_000_000).unwrap();
        let seen = watch_offers(&pair.core_b);

        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();

        assert!(seen.lock().unwrap().is_empty());
    }

    #[test]
    fn subscribing_after_the_offer_arrived_replays_it() {
        let dir = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_retained_offer(&dir);
        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();

        let seen = watch_offers(&pair.core_b);

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].kind, TransferEventKind::OfferAppeared);
        assert_eq!(seen[0].file_id, started.file_id);
    }

    /// Entrega uma oferta retida a B, assina e descarta o replay, e roda `act`.
    fn gone_events_after(act: impl FnOnce(&EstablishedPair, &[u8])) -> (Vec<TransferEventDto>, Vec<u8>) {
        let dir = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_retained_offer(&dir);
        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata.clone())
            .unwrap();
        let seen = watch_offers(&pair.core_b);
        seen.lock().unwrap().clear();
        act(&pair, &started.file_id);
        // Repetir não pode avisar de novo: a oferta já não existe.
        let _ = pair.core_b.cancel_transfer(started.file_id.clone());
        let events = seen.lock().unwrap().clone();
        (events, started.file_id)
    }

    fn assert_single_gone(result: (Vec<TransferEventDto>, Vec<u8>)) {
        let (events, file_id) = result;
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, TransferEventKind::OfferGone);
        assert_eq!(events[0].file_id, file_id);
    }

    #[test]
    fn accepting_an_offer_emits_gone_once() {
        assert_single_gone(gone_events_after(|pair, id| {
            pair.core_b.accept_file_offer(id.to_vec()).unwrap();
        }));
    }

    #[test]
    fn rejecting_an_offer_emits_gone_once() {
        assert_single_gone(gone_events_after(|pair, id| {
            pair.core_b.reject_file_offer(id.to_vec()).unwrap();
        }));
    }

    #[test]
    fn cancelling_an_offer_emits_gone_once() {
        assert_single_gone(gone_events_after(|pair, id| {
            pair.core_b.cancel_transfer(id.to_vec()).unwrap();
        }));
    }

    #[test]
    fn failed_reject_of_unknown_offer_emits_nothing() {
        let pair = established_pair();
        let seen = watch_offers(&pair.core_b);
        assert!(pair.core_b.reject_file_offer(vec![3; FILE_ID_LEN]).is_err());
        assert!(seen.lock().unwrap().is_empty());
    }

    #[test]
    fn lock_emits_gone_for_every_retained_offer() {
        let dir = tempfile::tempdir().unwrap();
        let (pair, started) = pair_with_retained_offer(&dir);
        pair.core_b
            .decrypt_incoming(pair.device_id_a.clone(), started.sealed_metadata)
            .unwrap();
        let seen = watch_offers(&pair.core_b);
        seen.lock().unwrap().clear();

        pair.core_b.lock().unwrap();

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].kind, TransferEventKind::OfferGone);
    }
}
