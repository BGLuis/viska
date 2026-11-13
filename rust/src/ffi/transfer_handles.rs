//! Os handles de transferência em memória e as regras para pôr e tirar um do
//! mapa `Core::transfers` — `docs/protocol.md` §7.5.
//!
//! Quem inicia (`ffi::transfer`), retoma (`ffi::transfer_resume`) e encerra uma
//! transferência passa por aqui, e as garantias valem para todos:
//!
//! - Um handle só entra no mapa com a Core destrancada e a linha ainda no banco
//!   ([`Core::install_handle`]), conferidos sob a trava do mapa.
//! - Toda transferência acaba por [`Core::end_transfer`]: a linha antes do
//!   handle, o handle antes dos arquivos.
//! - Quem mexe no `.staging` sem handle no mapa (reconstruir, terminar) reserva
//!   o `file_id` antes ([`Core::claim_for_rebuild`], [`Core::take_for_finish`]).
//!   `StagingWriter::resume` corta o arquivo; duas reconstruções simultâneas, ou
//!   uma reconstrução durante o `finish`, cortariam páginas que outro escritor
//!   ou leitor está usando.

use std::collections::{HashMap, HashSet};
use std::sync::MutexGuard;

use crate::ffi::core::Core;
use crate::ffi::error::FfiError;
use viska_proto::file::manifest::{Manifest, FILE_ID_LEN, LAN_SYMBOL_SIZE};
use viska_proto::file::staging::{self, StagingReader};
use viska_proto::file::transfer::{ReceiveTransfer, SendTransfer, TransferKind, TransferMode};

/// Um lado (emissor ou receptor) de uma transferência em memória, indexado
/// por `file_id` em `Core::transfers`.
pub(super) enum TransferHandle {
    Send(OutgoingHandle),
    Receive(ReceiveTransfer),
}

/// Um envio em memória e o que o Rust precisa lembrar sobre ele entre um
/// `FILE_FEEDBACK` e outro.
pub(super) struct OutgoingHandle {
    pub(super) transfer: SendTransfer<StagingReader>,
    /// Geração da sessão com o contato do último feedback aceito, ou de quando
    /// o envio nasceu. Um receptor só fica para trás depois de trancar ou
    /// reabrir, o que sempre troca a sessão; um feedback atrasado da mesma
    /// sessão não faz o envio voltar (§7.5).
    pub(super) generation: u32,
    /// A oferta já teve resposta (§7.7 item 5), em cache para
    /// `Core::transfer_progress` não ir ao banco a cada consulta.
    pub(super) answered: bool,
}

impl OutgoingHandle {
    /// Um envio que lê da cópia cifrada em `outgoing/`, no modo que o
    /// manifesto implica.
    pub(super) fn new(
        manifest: Manifest,
        kind: TransferKind,
        transfer_secret: &[u8],
        copy: StagingReader,
        generation: u32,
        answered: bool,
    ) -> Self {
        let mode = mode_for(&manifest);
        Self {
            transfer: SendTransfer::new(manifest, kind, transfer_secret, copy).with_mode(mode),
            generation,
            answered,
        }
    }
}

/// Modo de envio que o manifesto implica: `symbol_size` da LAN é o único caso
/// por offset (§7.3, D23). Decidido no início do envio e mantido na retomada,
/// porque o tamanho de símbolo não muda depois da oferta.
fn mode_for(manifest: &Manifest) -> TransferMode {
    if manifest.symbol_size == LAN_SYMBOL_SIZE {
        TransferMode::Offset
    } else {
        TransferMode::Fountain
    }
}

/// A sessão cifra agora: estabelecida e sem candidata segurando o envio
/// (§11.4), que faria `encrypt_outgoing` recusar.
pub(super) fn can_seal_now(session: &viska_proto::session::Session) -> bool {
    session.is_established() && !session.is_renewing()
}

/// Resultado de tentar reservar um `file_id` para reconstruir o handle.
pub(super) enum Claim<'a> {
    /// O handle já está em memória: nada a reconstruir.
    Live,
    /// Outra chamada está reconstruindo ou terminando esta transferência.
    Busy,
    /// Reservado para quem chamou até o guarda sair de escopo.
    Claimed(ClaimGuard<'a>),
}

/// Reserva de um `file_id` sem handle no mapa; solta ao sair de escopo,
/// instalado o handle ou não.
pub(super) struct ClaimGuard<'a> {
    core: &'a Core,
    file_id: [u8; FILE_ID_LEN],
}

impl Drop for ClaimGuard<'_> {
    fn drop(&mut self) {
        // Trava envenenada só depois de um pânico, que já inutiliza a Core.
        if let Ok(mut claims) = self.core.transfer_claims.lock() {
            claims.remove(&self.file_id);
        }
    }
}

impl Core {
    pub(super) fn lock_transfers(
        &self,
    ) -> Result<MutexGuard<'_, HashMap<[u8; FILE_ID_LEN], TransferHandle>>, FfiError> {
        self.transfers.lock().map_err(|_| FfiError::Internal)
    }

    fn lock_claims(&self) -> Result<MutexGuard<'_, HashSet<[u8; FILE_ID_LEN]>>, FfiError> {
        self.transfer_claims.lock().map_err(|_| FfiError::Internal)
    }

    /// Reserva `file_id` para reconstruir o handle a partir do disco. Conferido
    /// e reservado sob a trava do mapa (ordem: `transfers` antes de
    /// `transfer_claims`), para que duas chamadas nunca reconstruam a mesma
    /// transferência ao mesmo tempo.
    pub(super) fn claim_for_rebuild(&self, file_id: [u8; FILE_ID_LEN]) -> Result<Claim<'_>, FfiError> {
        let transfers = self.lock_transfers()?;
        if transfers.contains_key(&file_id) {
            return Ok(Claim::Live);
        }
        if !self.lock_claims()?.insert(file_id) {
            return Ok(Claim::Busy);
        }
        Ok(Claim::Claimed(ClaimGuard { core: self, file_id }))
    }

    /// Tira o handle do mapa para terminar a transferência e deixa o `file_id`
    /// reservado enquanto o `finish` lê o staging: sem handle no mapa, uma
    /// retomada concorrente tentaria reconstruí-lo e cortaria o arquivo.
    pub(super) fn take_for_finish(
        &self,
        file_id: [u8; FILE_ID_LEN],
    ) -> Result<Option<(TransferHandle, ClaimGuard<'_>)>, FfiError> {
        let mut transfers = self.lock_transfers()?;
        let Some(handle) = transfers.remove(&file_id) else {
            return Ok(None);
        };
        // Um handle no mapa nunca convive com uma reserva: `install_handle` solta
        // a reserva de quem reconstruiu sob esta mesma trava.
        let fresh = self.lock_claims()?.insert(file_id);
        debug_assert!(fresh, "reserva de {} com handle no mapa", hex::encode(file_id));
        Ok(Some((handle, ClaimGuard { core: self, file_id })))
    }

    /// Põe um handle no mapa, a menos que a Core tenha trancado ou a
    /// transferência tenha acabado enquanto ele era montado. As duas checagens
    /// ficam sob a trava do mapa: `Core::lock` limpa o mapa de novo depois de
    /// fechar o banco, então esta inserção ou acontece antes dessa limpeza ou
    /// já vê o banco fechado; e [`Self::end_transfer`] apaga a linha antes de
    /// tirar o handle.
    ///
    /// `claim` é a reserva de quem reconstruiu ou terminou o handle; ela é solta
    /// aqui, sob a mesma trava em que o handle entra, para nunca haver reserva
    /// e handle ao mesmo tempo (que deixaria um terceiro reservar o `file_id`
    /// depois de o dono certo soltá-lo).
    pub(super) fn install_handle(
        &self,
        file_id: [u8; FILE_ID_LEN],
        handle: TransferHandle,
        claim: Option<ClaimGuard<'_>>,
    ) -> Result<bool, FfiError> {
        let mut transfers = self.lock_transfers()?;
        if self.is_locked() || !self.store.file_transfer_exists(&file_id)? {
            return Ok(false);
        }
        transfers.entry(file_id).or_insert(handle);
        drop(claim);
        Ok(true)
    }

    /// Último passo de toda transferência que acaba, por qualquer motivo:
    /// apaga a linha (o que destrói a chave, D15), descarta o handle e apaga o
    /// `.staging` e a cópia de envio. A linha vai antes do handle: uma
    /// reconstrução concorrente ou viu a linha e instalou um handle que este
    /// passo tira em seguida, ou já não a vê e não instala nada.
    pub(super) fn end_transfer(&self, file_id: &[u8; FILE_ID_LEN]) -> Result<(), FfiError> {
        self.store.delete_file_transfer(file_id)?;
        self.lock_transfers()?.remove(file_id);
        let _ = std::fs::remove_file(staging::staging_path(&self.staging_dir, file_id));
        let _ = std::fs::remove_file(staging::staging_path(&self.outgoing_dir, file_id));
        Ok(())
    }
}
