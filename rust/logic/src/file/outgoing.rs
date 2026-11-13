//! Cópia cifrada do arquivo-fonte que o emissor guarda para retomar o envio
//! depois de bloqueio ou reinício — `docs/protocol.md` §7.5, D28.
//!
//! O envio nunca relê o arquivo original: o sistema pode apagá-lo (cache do
//! seletor de arquivos) e a pessoa pode alterá-lo. A cópia usa o mesmo formato
//! de página do staging do receptor, sob `K_outgoing`
//! ([`keys::derive_outgoing_staging_key`]), que nunca vai ao fio. Apagar a linha
//! da transferência no banco destrói a chave, e com ela a cópia.

use std::io::Read;
use std::path::Path;

use crate::file::keys;
use crate::file::manifest::{Manifest, FILE_ID_LEN};
use crate::file::merkle;
use crate::file::staging::{self, StagingReader, StagingWriter};
use crate::{Error, Result};

/// Grava em `outgoing_dir` a cópia cifrada do arquivo-fonte que o emissor
/// guarda para retomar o envio depois de bloqueio ou reinício (§7.5), e
/// devolve a raiz BLAKE3 e o tamanho do que foi copiado, numa só leitura de
/// `source`. O manifesto deve nascer destes dois valores, não de uma leitura
/// separada do original: só assim a raiz descreve exatamente o que será enviado.
pub fn stage_outgoing_copy(
    source: impl Read,
    outgoing_dir: &Path,
    file_id: [u8; FILE_ID_LEN],
    transfer_secret: &[u8],
) -> Result<([u8; 32], u64)> {
    let key = keys::derive_outgoing_staging_key(transfer_secret, &file_id);
    let mut tee = CopyingReader {
        inner: source,
        writer: StagingWriter::create(outgoing_dir, file_id, key)?,
        copied: 0,
        failed: false,
    };
    let root = merkle::merkle_root(&mut tee)?;
    if tee.failed {
        return Err(Error::Malformed("falha gravando a cópia do arquivo a enviar"));
    }
    let copied = tee.copied;
    tee.writer.finish()?;
    Ok((*root.as_bytes(), copied))
}

/// Abre para leitura a cópia que [`stage_outgoing_copy`] gravou, depois de
/// conferir que ela ainda bate com a raiz do manifesto: o arquivo em disco pode
/// ter sido adulterado ou cortado entre o bloqueio e a retomada, e mandar
/// conteúdo diferente do oferecido só seria detectado no fim, pelo receptor (D26).
pub fn open_outgoing_copy(
    outgoing_dir: &Path,
    manifest: &Manifest,
    transfer_secret: &[u8],
) -> Result<StagingReader> {
    let path = staging::staging_path(outgoing_dir, &manifest.file_id);
    let on_disk = std::fs::metadata(&path)
        .map_err(|_| Error::Malformed("cópia de envio não encontrada"))?
        .len();
    // Cortada ou acrescida por fora: já não é o que foi oferecido, mesmo que
    // as páginas que sobraram autentiquem.
    if on_disk != staging::sealed_len(manifest.file_size) {
        return Err(Error::MerkleMismatch);
    }
    // `decrypt_to`, não `Read`: preserva `AeadFailure` de uma página
    // adulterada, que quem chama trata como cópia perdida, diferente de uma
    // falha de E/S passageira.
    let mut hasher = blake3::Hasher::new();
    read_outgoing_copy(outgoing_dir, manifest, transfer_secret)?.decrypt_to(&mut hasher)?;
    merkle::verify_root(&hasher.finalize(), &manifest.merkle_root)?;
    read_outgoing_copy(outgoing_dir, manifest, transfer_secret)
}

/// Abre a cópia sem conferir a raiz — só para quem acabou de gravá-la com
/// [`stage_outgoing_copy`] e já tem a raiz dela em mãos. Uma página adulterada
/// ainda falha na leitura, pelo AEAD.
pub fn read_outgoing_copy(
    outgoing_dir: &Path,
    manifest: &Manifest,
    transfer_secret: &[u8],
) -> Result<StagingReader> {
    StagingReader::open(
        outgoing_dir,
        manifest.file_id,
        keys::derive_outgoing_staging_key(transfer_secret, &manifest.file_id),
        manifest.file_size,
    )
}

/// Lê de `inner` e grava cada pedaço lido na cópia cifrada — o que permite
/// calcular a raiz e copiar o arquivo na mesma passada.
struct CopyingReader<R: Read> {
    inner: R,
    writer: StagingWriter,
    copied: u64,
    /// `Read` só devolve `io::Error`, que `merkle_root` achata; isto preserva
    /// a causa (falha de gravação, não de leitura) para quem chamou.
    failed: bool,
}

impl<R: Read> Read for CopyingReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        // `n` vem do próprio `read`, que nunca passa de `buf.len()`.
        if self.writer.write(&buf[..n]).is_err() {
            self.failed = true;
            return Err(std::io::Error::other("falha gravando a cópia"));
        }
        self.copied += n as u64;
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::file::transfer::tests::{finish_with_fresh_sender, manifesto_de_teste};
    use crate::file::transfer::{ReceiveTransfer, TransferKind};
    use std::io::Cursor;

    #[test]
    fn outgoing_copy_feeds_a_complete_transfer() {
        let (manifest, original) = manifesto_de_teste(350_000, 1000, 100);
        let secret = b"segredo-de-transferencia-de-teste";
        let outgoing = tempfile::tempdir().unwrap();
        let staging_dir = tempfile::tempdir().unwrap();

        let (root, size) =
            stage_outgoing_copy(Cursor::new(original.clone()), outgoing.path(), manifest.file_id, secret).unwrap();
        assert_eq!(root, manifest.merkle_root);
        assert_eq!(size, original.len() as u64);
        // A cópia não fica em claro no disco.
        let on_disk = std::fs::read(staging::staging_path(outgoing.path(), &manifest.file_id)).unwrap();
        assert!(!on_disk.windows(64).any(|w| w == &original[1000..1064]));

        let copy = open_outgoing_copy(outgoing.path(), &manifest, secret).unwrap();
        let receiver = ReceiveTransfer::start(manifest.clone(), TransferKind::File, secret, staging_dir.path()).unwrap();
        let (destino, _) = finish_with_fresh_sender(&manifest, copy, secret, receiver, staging_dir.path());
        assert_eq!(destino, original);
    }

    #[test]
    fn outgoing_copy_uses_a_key_distinct_from_the_receiver_staging() {
        let (manifest, original) = manifesto_de_teste(70_000, 1000, 100);
        let secret = b"segredo-de-transferencia-de-teste";
        let outgoing = tempfile::tempdir().unwrap();
        stage_outgoing_copy(Cursor::new(original), outgoing.path(), manifest.file_id, secret).unwrap();
        let mut reader = StagingReader::open(
            outgoing.path(),
            manifest.file_id,
            staging::derive_staging_key(secret, &manifest.file_id),
            manifest.file_size,
        )
        .unwrap();
        assert!(reader.decrypt_to(std::io::sink()).is_err());
    }

    #[test]
    fn open_outgoing_copy_rejects_a_tampered_or_truncated_copy() {
        let (manifest, original) = manifesto_de_teste(350_000, 1000, 100);
        let secret = b"segredo-de-transferencia-de-teste";
        let outgoing = tempfile::tempdir().unwrap();
        let path = staging::staging_path(outgoing.path(), &manifest.file_id);

        stage_outgoing_copy(Cursor::new(original.clone()), outgoing.path(), manifest.file_id, secret).unwrap();
        let mut bytes = std::fs::read(&path).unwrap();
        bytes[70_000] ^= 1;
        std::fs::write(&path, &bytes).unwrap();
        assert!(matches!(
            open_outgoing_copy(outgoing.path(), &manifest, secret).unwrap_err(),
            Error::AeadFailure
        ));

        stage_outgoing_copy(Cursor::new(original.clone()), outgoing.path(), manifest.file_id, secret).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        std::fs::write(&path, &bytes[..bytes.len() - 10]).unwrap();
        assert!(matches!(
            open_outgoing_copy(outgoing.path(), &manifest, secret).unwrap_err(),
            Error::MerkleMismatch
        ));

        // Mesmo tamanho, outro conteúdo: só a raiz pega.
        let mut other = original.clone();
        other[5] ^= 1;
        stage_outgoing_copy(Cursor::new(other), outgoing.path(), manifest.file_id, secret).unwrap();
        assert!(matches!(
            open_outgoing_copy(outgoing.path(), &manifest, secret).unwrap_err(),
            Error::MerkleMismatch
        ));
    }

    #[test]
    fn missing_outgoing_copy_fails_to_open() {
        let (manifest, _) = manifesto_de_teste(1000, 1000, 100);
        let outgoing = tempfile::tempdir().unwrap();
        assert!(open_outgoing_copy(outgoing.path(), &manifest, b"s").is_err());
    }
}
