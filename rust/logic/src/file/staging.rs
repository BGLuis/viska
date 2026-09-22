//! Staging cifrado em disco — `docs/protocol.md` §7.5, D13.
//!
//! Bytes decodificados de um source block são gravados imediatamente em
//! `<staging_dir>/<hex(file_id)>.staging`, cifrados por página de 64 KB com
//! `crypto::aead::seal_xchacha` — nunca em claro, e nunca com o arquivo
//! inteiro em RAM: só a página corrente (≤ 64 KB) fica em memória entre uma
//! chamada de [`StagingWriter::write`] e a próxima.
//!
//! Ao abortar, quem chama solta o [`StagingWriter`] (via [`StagingWriter::abort`]
//! ou simplesmente descartando o valor) e a chave `K_staging` — que é
//! [`crate::crypto::kdf::Key`], `ZeroizeOnDrop` — é zerada da memória deste
//! processo. Isso só materializa a promessa de "resíduo em flash
//! criptograficamente inacessível" do §7.5 enquanto quem chama também parar
//! de conseguir *rederivar* a mesma chave — ou seja, enquanto o
//! `session_secret` usado em [`derive_staging_key`] também for esquecido do
//! lado de quem orquestra a transferência. Este módulo deriva e usa a chave;
//! ele não decide por quanto tempo o `session_secret` de origem continua
//! vivo, nem como uma transferência retomada volta a obter a mesma chave
//! depois de uma queda de conexão — isso é responsabilidade de
//! `file::transfer` (F4), que ainda não existe, e fica registrado aqui como
//! pendência em aberto, não resolvido em silêncio.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use crate::crypto::aead;
use crate::crypto::kdf::Key;
use crate::file::keys;
use crate::file::manifest::FILE_ID_LEN;
use crate::{Error, Result};

/// Tamanho de página de cifragem do staging (§7.5). Coincide com o maior
/// bucket de `wire::transport::Transport::LocalSocket` e com o pedaço de
/// leitura de `file::merkle::merkle_root`, mas por coincidência de "número
/// redondo conveniente" — não há acoplamento entre os três; mudar um não
/// exige mudar os outros.
pub const PAGE_LEN: usize = 65536;

/// Deriva `K_staging` a partir do segredo de transferência e do `file_id` —
/// fórmula exata de §7.5 (D15). Reexportado de [`keys::derive_staging_key`]
/// para quem só importa `staging` não precisar saber que a derivação mora
/// em `file::keys`. Determinística: o mesmo par `(transfer_secret, file_id)`
/// sempre produz a mesma chave, necessário para uma transferência retomável
/// reabrir o mesmo `.staging` — e é também por isso que a promessa de
/// "abortar destrói a chave" depende de quem orquestra a transferência
/// também esquecer `transfer_secret`, não só desta função.
pub fn derive_staging_key(transfer_secret: &[u8], file_id: &[u8; FILE_ID_LEN]) -> Key {
    keys::derive_staging_key(transfer_secret, file_id)
}

/// Caminho do arquivo de staging de uma transferência, dentro de
/// `staging_dir`. `file_id` vira hexadecimal — nomes de arquivo binários
/// crus são um risco de portabilidade sem benefício aqui.
pub fn staging_path(staging_dir: &Path, file_id: &[u8; FILE_ID_LEN]) -> PathBuf {
    staging_dir.join(format!("{}.staging", hex::encode(file_id)))
}

fn page_aad(file_id: &[u8; FILE_ID_LEN], page_index: u64) -> Vec<u8> {
    // Amarra cada página ao arquivo e à posição: uma página cifrada não pode
    // ser silenciosamente reaproveitada em outra posição ou em outra
    // transferência sem que a autenticação do AEAD rejeite.
    let mut aad = Vec::with_capacity(file_id.len() + 8);
    aad.extend_from_slice(file_id);
    aad.extend_from_slice(&page_index.to_be_bytes());
    aad
}

/// Escreve o plaintext de um arquivo, em ordem, cifrando por página de
/// [`PAGE_LEN`] bytes assim que cada página completa.
pub struct StagingWriter {
    file: File,
    path: PathBuf,
    key: Key,
    file_id: [u8; FILE_ID_LEN],
    buffer: Vec<u8>,
    next_page_index: u64,
    bytes_written: u64,
}

// `File` não implementa `Debug` de um jeito útil aqui, e a chave e o buffer
// pendente (bytes do arquivo do usuário ainda não cifrados) nunca devem
// aparecer em log — mesmo racional de `crypto::kdf::Key`.
impl core::fmt::Debug for StagingWriter {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("StagingWriter")
            .field("path", &self.path)
            .field("bytes_written", &self.bytes_written)
            .finish_non_exhaustive()
    }
}

impl StagingWriter {
    /// Cria (ou trunca, se já existir de uma tentativa anterior) o arquivo
    /// de staging para `file_id` dentro de `staging_dir`, criando o
    /// diretório se preciso.
    pub fn create(
        staging_dir: &Path,
        file_id: [u8; FILE_ID_LEN],
        key: Key,
    ) -> Result<Self> {
        fs::create_dir_all(staging_dir).map_err(|_| Error::Malformed("falha criando diretório de staging"))?;
        let path = staging_path(staging_dir, &file_id);
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)
            .map_err(|_| Error::Malformed("falha criando arquivo de staging"))?;

        Ok(Self {
            file,
            path,
            key,
            file_id,
            buffer: Vec::with_capacity(PAGE_LEN),
            next_page_index: 0,
            bytes_written: 0,
        })
    }

    /// Bytes de plaintext já gravados (cifrados) em disco, sem contar o que
    /// ainda está no buffer pendente — útil para relatar progresso.
    pub fn bytes_written(&self) -> u64 {
        self.bytes_written
    }

    /// Acrescenta plaintext ao staging, cifrando e gravando toda página
    /// completa que se forma. `plaintext` não precisa ter nenhuma relação de
    /// tamanho com [`PAGE_LEN`] — pode ser um source block inteiro (até
    /// dezenas de MB) ou um pedaço bem menor.
    pub fn write(&mut self, plaintext: &[u8]) -> Result<()> {
        self.buffer.extend_from_slice(plaintext);
        while self.buffer.len() >= PAGE_LEN {
            let page: Vec<u8> = self.buffer.drain(..PAGE_LEN).collect();
            self.flush_page(&page)?;
        }
        Ok(())
    }

    fn flush_page(&mut self, page_plaintext: &[u8]) -> Result<()> {
        let mut sealed = page_plaintext.to_vec();
        let aad = page_aad(&self.file_id, self.next_page_index);
        aead::seal_xchacha(&self.key, &aad, &mut sealed)?;
        self.file
            .write_all(&sealed)
            .map_err(|_| Error::Malformed("falha gravando página de staging"))?;
        self.bytes_written += page_plaintext.len() as u64;
        self.next_page_index += 1;
        Ok(())
    }

    /// Cifra e grava a última página (possivelmente menor que [`PAGE_LEN`],
    /// possivelmente vazia se o arquivo for vazio) e garante que os bytes
    /// cheguem ao disco antes de devolver.
    pub fn finish(mut self) -> Result<()> {
        if !self.buffer.is_empty() {
            let last = std::mem::take(&mut self.buffer);
            self.flush_page(&last)?;
        }
        self.file
            .sync_all()
            .map_err(|_| Error::Malformed("falha sincronizando staging para disco"))
    }

    /// Aborta a transferência: solta `self`, zerando `K_staging` (o `Key`
    /// interno é `ZeroizeOnDrop`), e tenta apagar o arquivo em disco. A
    /// exclusão é só limpeza de espaço — a garantia de segurança real já
    /// aconteceu ao zerar a chave, então uma falha ao apagar não é
    /// propagada como erro (ver doc do módulo em `docs/protocol.md` §7.5).
    pub fn abort(self) {
        let path = self.path.clone();
        drop(self);
        let _ = fs::remove_file(path);
    }
}

/// Lê um `.staging` de volta, decifrando página a página, na ordem.
pub struct StagingReader {
    file: File,
    key: Key,
    file_id: [u8; FILE_ID_LEN],
    total_len: u64,
}

impl core::fmt::Debug for StagingReader {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("StagingReader")
            .field("total_len", &self.total_len)
            .finish_non_exhaustive()
    }
}

impl StagingReader {
    pub fn open(
        staging_dir: &Path,
        file_id: [u8; FILE_ID_LEN],
        key: Key,
        total_len: u64,
    ) -> Result<Self> {
        let path = staging_path(staging_dir, &file_id);
        let file =
            File::open(&path).map_err(|_| Error::Malformed("staging não encontrado para leitura"))?;
        Ok(Self {
            file,
            key,
            file_id,
            total_len,
        })
    }

    /// Número de páginas — todas de [`PAGE_LEN`] bytes de plaintext, exceto
    /// possivelmente a última.
    fn page_count(&self) -> u64 {
        if self.total_len == 0 {
            0
        } else {
            self.total_len.div_ceil(PAGE_LEN as u64)
        }
    }

    fn page_plaintext_len(&self, page_index: u64) -> usize {
        let full_pages = self.total_len / PAGE_LEN as u64;
        if page_index < full_pages {
            PAGE_LEN
        } else {
            (self.total_len % PAGE_LEN as u64) as usize
        }
    }

    /// Decifra o arquivo inteiro, na ordem, escrevendo em `out` — nunca
    /// retém mais que uma página em RAM de cada vez. Para no primeiro erro
    /// de autenticação (página adulterada ou chave errada): `out` pode ter
    /// recebido páginas anteriores já decididas como autênticas, mas o
    /// chamador nunca deve tratar um `Err` no meio como "arquivo parcialmente
    /// válido" — a verificação de integridade completa é a raiz de Merkle
    /// (`file::merkle`), recomputada só depois que este método terminar com
    /// sucesso.
    pub fn decrypt_to(&mut self, mut out: impl Write) -> Result<()> {
        for page_index in 0..self.page_count() {
            let plaintext_len = self.page_plaintext_len(page_index);
            let encrypted_len = plaintext_len + aead::XNONCE_LEN + aead::TAG_LEN;

            let mut buf = vec![0u8; encrypted_len];
            self.file
                .read_exact(&mut buf)
                .map_err(|_| Error::Malformed("staging truncado ou menor que o esperado"))?;

            let aad = page_aad(&self.file_id, page_index);
            aead::open_xchacha(&self.key, &aad, &mut buf)?;

            out.write_all(&buf)
                .map_err(|_| Error::Malformed("falha escrevendo plaintext decifrado"))?;
        }
        Ok(())
    }
}

/// Remove todo `.staging` em `staging_dir` cujo `file_id` não esteja em
/// `active_file_ids` — chamado na inicialização (ver armadilha "`.staging`
/// sobrevive a crash" do relatório da Fase 4). Quem mantém a lista de
/// transferências ativas é `file::transfer`/a camada FFI (ainda não
/// existem); este módulo só sabe varrer e comparar nomes de arquivo.
pub fn sweep_orphaned(
    staging_dir: &Path,
    active_file_ids: &std::collections::HashSet<[u8; FILE_ID_LEN]>,
) -> Result<()> {
    let entries = match fs::read_dir(staging_dir) {
        Ok(entries) => entries,
        // Diretório de staging ainda não existe: não há nada para varrer,
        // não é um erro (é o estado normal antes da primeira transferência).
        Err(_) => return Ok(()),
    };

    for entry in entries {
        let entry = entry.map_err(|_| Error::Malformed("falha lendo diretório de staging"))?;
        let path = entry.path();
        let is_orphan = match file_id_from_staging_path(&path) {
            Some(file_id) => !active_file_ids.contains(&file_id),
            // Nome que não segue o padrão esperado: não é um `.staging`
            // nosso, não mexe.
            None => false,
        };
        if is_orphan {
            let _ = fs::remove_file(&path);
        }
    }
    Ok(())
}

fn file_id_from_staging_path(path: &Path) -> Option<[u8; FILE_ID_LEN]> {
    let name = path.file_name()?.to_str()?;
    let hex_part = name.strip_suffix(".staging")?;
    let bytes = hex::decode(hex_part).ok()?;
    bytes.try_into().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chave_de_teste(tag: u8) -> Key {
        derive_staging_key(&[tag; 32], &[tag; FILE_ID_LEN])
    }

    #[test]
    fn writes_in_misaligned_chunks_and_reads_back_identically() {
        let dir = tempfile::tempdir().unwrap();
        let file_id = [1u8; FILE_ID_LEN];
        let key = chave_de_teste(1);

        let original: Vec<u8> = (0..200_003u32).map(|i| (i % 253) as u8).collect();
        let mut writer = StagingWriter::create(dir.path(), file_id, key.clone()).unwrap();
        for pedaco in original.chunks(7_777) {
            // Tamanho de pedaço deliberadamente sem relação com PAGE_LEN.
            writer.write(pedaco).unwrap();
        }
        writer.finish().unwrap();

        let mut reader =
            StagingReader::open(dir.path(), file_id, key, original.len() as u64).unwrap();
        let mut lido = Vec::new();
        reader.decrypt_to(&mut lido).unwrap();

        assert_eq!(lido, original);
    }

    #[test]
    fn empty_file_works() {
        let dir = tempfile::tempdir().unwrap();
        let file_id = [2u8; FILE_ID_LEN];
        let key = chave_de_teste(2);

        let writer = StagingWriter::create(dir.path(), file_id, key.clone()).unwrap();
        writer.finish().unwrap();

        let mut reader = StagingReader::open(dir.path(), file_id, key, 0).unwrap();
        let mut lido = Vec::new();
        reader.decrypt_to(&mut lido).unwrap();
        assert!(lido.is_empty());
    }

    #[test]
    fn size_exactly_multiple_of_page_len() {
        let dir = tempfile::tempdir().unwrap();
        let file_id = [3u8; FILE_ID_LEN];
        let key = chave_de_teste(3);

        let original = vec![0x42u8; PAGE_LEN * 3];
        let mut writer = StagingWriter::create(dir.path(), file_id, key.clone()).unwrap();
        writer.write(&original).unwrap();
        writer.finish().unwrap();

        let mut reader =
            StagingReader::open(dir.path(), file_id, key, original.len() as u64).unwrap();
        let mut lido = Vec::new();
        reader.decrypt_to(&mut lido).unwrap();
        assert_eq!(lido, original);
    }

    #[test]
    fn different_key_fails_to_decrypt() {
        let dir = tempfile::tempdir().unwrap();
        let file_id = [4u8; FILE_ID_LEN];
        let key_certa = chave_de_teste(4);
        let key_errada = chave_de_teste(5);

        let original = vec![0x99u8; 10_000];
        let mut writer = StagingWriter::create(dir.path(), file_id, key_certa).unwrap();
        writer.write(&original).unwrap();
        writer.finish().unwrap();

        let mut reader =
            StagingReader::open(dir.path(), file_id, key_errada, original.len() as u64).unwrap();
        let mut lido = Vec::new();
        assert!(matches!(
            reader.decrypt_to(&mut lido),
            Err(Error::AeadFailure)
        ));
    }

    #[test]
    fn tampered_page_is_rejected_without_panic_or_wrong_plaintext() {
        let dir = tempfile::tempdir().unwrap();
        let file_id = [6u8; FILE_ID_LEN];
        let key = chave_de_teste(6);

        let original = vec![0x11u8; PAGE_LEN + 500];
        let mut writer = StagingWriter::create(dir.path(), file_id, key.clone()).unwrap();
        writer.write(&original).unwrap();
        writer.finish().unwrap();

        // Adultera um byte bem no meio do arquivo em disco.
        let path = staging_path(dir.path(), &file_id);
        let mut bytes = fs::read(&path).unwrap();
        let meio = bytes.len() / 2;
        bytes[meio] ^= 0xFF;
        fs::write(&path, &bytes).unwrap();

        let mut reader =
            StagingReader::open(dir.path(), file_id, key, original.len() as u64).unwrap();
        let mut lido = Vec::new();
        assert!(matches!(
            reader.decrypt_to(&mut lido),
            Err(Error::AeadFailure)
        ));
    }

    #[test]
    fn abort_deletes_staging_file() {
        let dir = tempfile::tempdir().unwrap();
        let file_id = [7u8; FILE_ID_LEN];
        let key = chave_de_teste(7);

        let mut writer = StagingWriter::create(dir.path(), file_id, key).unwrap();
        writer.write(&[1, 2, 3]).unwrap();
        let path = staging_path(dir.path(), &file_id);
        assert!(path.exists());

        writer.abort();
        assert!(!path.exists());
    }

    #[test]
    fn derive_staging_key_is_deterministic() {
        let a = derive_staging_key(b"segredo-de-sessao", &[9u8; FILE_ID_LEN]);
        let b = derive_staging_key(b"segredo-de-sessao", &[9u8; FILE_ID_LEN]);
        assert_eq!(a.as_bytes(), b.as_bytes());
    }

    #[test]
    fn derive_staging_key_changes_with_file_id() {
        let a = derive_staging_key(b"segredo-de-sessao", &[9u8; FILE_ID_LEN]);
        let b = derive_staging_key(b"segredo-de-sessao", &[10u8; FILE_ID_LEN]);
        assert_ne!(a.as_bytes(), b.as_bytes());
    }

    #[test]
    fn sweep_orphaned_removes_only_inactive_files() {
        let dir = tempfile::tempdir().unwrap();
        let ativo = [1u8; FILE_ID_LEN];
        let orfao = [2u8; FILE_ID_LEN];

        for id in [ativo, orfao] {
            let key = chave_de_teste(id[0]);
            let writer = StagingWriter::create(dir.path(), id, key).unwrap();
            writer.finish().unwrap();
        }

        let mut ativos = std::collections::HashSet::new();
        ativos.insert(ativo);
        sweep_orphaned(dir.path(), &ativos).unwrap();

        assert!(staging_path(dir.path(), &ativo).exists());
        assert!(!staging_path(dir.path(), &orfao).exists());
    }

    #[test]
    fn sweep_orphaned_on_nonexistent_directory_does_not_error() {
        let dir = tempfile::tempdir().unwrap();
        let caminho_inexistente = dir.path().join("nao-existe");
        assert!(sweep_orphaned(&caminho_inexistente, &Default::default()).is_ok());
    }

    #[test]
    fn sweep_orphaned_ignores_non_staging_files() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("nota.txt"), b"nao mexe aqui").unwrap();

        sweep_orphaned(dir.path(), &Default::default()).unwrap();

        assert!(dir.path().join("nota.txt").exists());
    }
}
