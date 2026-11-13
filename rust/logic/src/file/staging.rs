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
//! por quanto tempo o segredo de origem continua vivo é decidido em
//! `file::transfer` e na camada FFI (§7.5, D28). [`StagingWriter::resume`]
//! é o que deixa uma transferência retomada reabrir o mesmo arquivo.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use zeroize::{Zeroize, Zeroizing};

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

/// Tamanho em disco de uma página completa: plaintext, nonce e tag.
const SEALED_PAGE_LEN: u64 = (PAGE_LEN + aead::XNONCE_LEN + aead::TAG_LEN) as u64;

/// Tamanho em disco de um staging completo com `total_len` bytes de plaintext.
/// Um arquivo com outro tamanho foi cortado ou acrescido por fora.
pub fn sealed_len(total_len: u64) -> u64 {
    let page_len = PAGE_LEN as u64;
    let overhead = (aead::XNONCE_LEN + aead::TAG_LEN) as u64;
    let tail = total_len % page_len;
    (total_len / page_len) * SEALED_PAGE_LEN + if tail > 0 { tail + overhead } else { 0 }
}

/// Quantas páginas completas de [`PAGE_LEN`] já estão gravadas no staging de
/// `file_id`. A última página, menor, só é gravada por [`StagingWriter::finish`],
/// e o que sobra depois da última página inteira (gravação interrompida no meio)
/// não conta. Nada aqui decifra: quem retoma confere cada página ao reabrir.
pub fn full_pages_on_disk(staging_dir: &Path, file_id: &[u8; FILE_ID_LEN]) -> Result<u64> {
    let len = fs::metadata(staging_path(staging_dir, file_id))
        .map_err(|_| Error::Malformed("staging não encontrado para retomada"))?
        .len();
    Ok(len / SEALED_PAGE_LEN)
}

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

// O buffer guarda plaintext do arquivo ainda não cifrado: na retomada, até
// uma página inteira dele vem decifrada do disco.
impl Drop for StagingWriter {
    fn drop(&mut self) {
        self.buffer.zeroize();
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

    /// Reabre um staging já existente para continuar gravando depois de
    /// `keep_len` bytes de plaintext, descartando tudo o que vem depois.
    ///
    /// As páginas até `keep_len` são decifradas e entregues, em ordem, a
    /// `on_plaintext`: quem retoma precisa reconstruir o hash do conteúdo, e o
    /// staging é a única cópia dele. Uma página que não autentica derruba a
    /// retomada inteira com `AeadFailure`. `keep_len` não precisa cair em
    /// fronteira de página: o pedaço depois da última página inteira volta ao
    /// buffer em RAM e o arquivo é cortado no início dessa página, que será
    /// recifrada com nonce novo quando completar.
    pub fn resume(
        staging_dir: &Path,
        file_id: [u8; FILE_ID_LEN],
        key: Key,
        keep_len: u64,
        mut on_plaintext: impl FnMut(&[u8]),
    ) -> Result<Self> {
        let page_len = PAGE_LEN as u64;
        let kept_pages = keep_len / page_len;
        let tail_len = (keep_len % page_len) as usize;
        let pages_to_read = kept_pages + u64::from(tail_len > 0);
        if pages_to_read > full_pages_on_disk(staging_dir, &file_id)? {
            return Err(Error::Malformed("staging menor que o trecho a retomar"));
        }

        let path = staging_path(staging_dir, &file_id);
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .map_err(|_| Error::Malformed("falha reabrindo arquivo de staging"))?;

        let mut buffer = Vec::with_capacity(PAGE_LEN);
        for page_index in 0..pages_to_read {
            let mut page = Zeroizing::new(vec![0u8; SEALED_PAGE_LEN as usize]);
            file.read_exact(&mut page)
                .map_err(|_| Error::Malformed("staging truncado durante a retomada"))?;
            aead::open_xchacha(&key, &page_aad(&file_id, page_index), &mut page)?;
            if page_index < kept_pages {
                on_plaintext(&page);
            } else {
                // `get` com `tail_len` < `PAGE_LEN`, garantido pelo resto da divisão acima.
                let tail = page
                    .get(..tail_len)
                    .ok_or(Error::Malformed("página de staging menor que o esperado"))?;
                on_plaintext(tail);
                buffer.extend_from_slice(tail);
            }
        }

        file.set_len(kept_pages * SEALED_PAGE_LEN)
            .map_err(|_| Error::Malformed("falha cortando o staging na retomada"))?;
        file.seek(SeekFrom::End(0))
            .map_err(|_| Error::Malformed("falha posicionando o staging na retomada"))?;

        Ok(Self {
            file,
            path,
            key,
            file_id,
            buffer,
            next_page_index: kept_pages,
            bytes_written: kept_pages * page_len,
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
            let page: Zeroizing<Vec<u8>> = Zeroizing::new(self.buffer.drain(..PAGE_LEN).collect());
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
    ///
    /// Pode ser repetida depois de uma falha (disco cheio na última página): o
    /// buffer só é esvaziado depois de a página ir a disco, e cada tentativa
    /// corta antes o que uma escrita interrompida tenha deixado depois da
    /// última página inteira.
    pub fn finish(&mut self) -> Result<()> {
        if !self.buffer.is_empty() {
            self.file
                .set_len(self.next_page_index * SEALED_PAGE_LEN)
                .and_then(|()| self.file.seek(SeekFrom::End(0)).map(|_| ()))
                .map_err(|_| Error::Malformed("falha preparando a última página do staging"))?;
            let last = Zeroizing::new(self.buffer.clone());
            self.flush_page(&last)?;
            self.buffer.zeroize();
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
    /// Estado de [`Read`]: próxima página a decifrar e o plaintext da página
    /// corrente, ainda não entregue por inteiro.
    next_page: u64,
    page: Zeroizing<Vec<u8>>,
    page_pos: usize,
}

impl core::fmt::Debug for StagingReader {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("StagingReader")
            .field("total_len", &self.total_len)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
thread_local! {
    /// Quantas vezes `decrypt_to` rodou nesta thread — permite a um teste
    /// afirmar quantas leituras completas do staging um fluxo faz.
    pub(crate) static DECRYPT_PASSES: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

impl StagingReader {
    pub fn open(
        staging_dir: &Path,
        file_id: [u8; FILE_ID_LEN],
        key: Key,
        total_len: u64,
    ) -> Result<Self> {
        Self::open_with_version(staging_dir, file_id, key, total_len, 1)
    }

    pub fn open_with_version(
        staging_dir: &Path,
        file_id: [u8; FILE_ID_LEN],
        key: Key,
        total_len: u64,
        cipher_version: u8,
    ) -> Result<Self> {
        if crate::crypto::Suite::is_retired(cipher_version) {
            return Err(Error::SuiteRetired(cipher_version));
        }
        if cipher_version != 1 {
            return Err(Error::UnsupportedVersion(cipher_version));
        }
        let path = staging_path(staging_dir, &file_id);
        let file =
            File::open(&path).map_err(|_| Error::Malformed("staging não encontrado para leitura"))?;
        Ok(Self {
            file,
            key,
            file_id,
            total_len,
            next_page: 0,
            page: Zeroizing::new(Vec::new()),
            page_pos: 0,
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

    /// Decifra a página `page_index` inteira, conferindo a tag.
    fn read_page(&mut self, page_index: u64) -> Result<Zeroizing<Vec<u8>>> {
        let plaintext_len = self.page_plaintext_len(page_index);
        let mut buf = Zeroizing::new(vec![0u8; plaintext_len + aead::XNONCE_LEN + aead::TAG_LEN]);
        self.file
            .read_exact(&mut buf)
            .map_err(|_| Error::Malformed("staging truncado ou menor que o esperado"))?;
        aead::open_xchacha(&self.key, &page_aad(&self.file_id, page_index), &mut buf)?;
        Ok(buf)
    }

    /// Decifra o arquivo inteiro, na ordem, escrevendo em `out` — nunca
    /// retém mais que uma página em RAM de cada vez. Para no primeiro erro
    /// de autenticação (página adulterada ou chave errada): `out` pode ter
    /// recebido páginas anteriores já decididas como autênticas, mas o
    /// chamador nunca deve tratar um `Err` no meio como "arquivo parcialmente
    /// válido" — a verificação de integridade completa é a raiz de Merkle
    /// (`file::merkle`), conferida por
    /// `ReceiveTransfer::finish` sobre o plaintext hasheado na gravação, antes
    /// de chamar este método.
    pub fn decrypt_to(&mut self, mut out: impl Write) -> Result<()> {
        #[cfg(test)]
        DECRYPT_PASSES.with(|n| n.set(n.get() + 1));
        for page_index in 0..self.page_count() {
            let buf = self.read_page(page_index)?;
            out.write_all(&buf)
                .map_err(|_| Error::Malformed("falha escrevendo plaintext decifrado"))?;
        }
        Ok(())
    }
}

/// Leitura sequencial do plaintext, uma página em RAM por vez: é assim que o
/// emissor lê a cópia cifrada do arquivo-fonte (`outgoing/`) sem decifrá-la
/// inteira. Não se mistura com [`StagingReader::decrypt_to`] no mesmo valor:
/// os dois avançam o mesmo cursor do arquivo.
impl Read for StagingReader {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        if self.page_pos >= self.page.len() {
            if self.next_page >= self.page_count() {
                return Ok(0);
            }
            let page_index = self.next_page;
            // A causa do erro não sobe: uma página adulterada e um arquivo
            // truncado são a mesma falha para quem lê.
            self.page = self
                .read_page(page_index)
                .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidData))?;
            self.page_pos = 0;
            self.next_page += 1;
        }
        let available = self.page.get(self.page_pos..).unwrap_or_default();
        let n = available.len().min(out.len());
        // `n` não passa de nenhum dos dois comprimentos, pelo `min` acima.
        out[..n].copy_from_slice(&available[..n]);
        self.page_pos += n;
        Ok(n)
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

        let mut writer = StagingWriter::create(dir.path(), file_id, key.clone()).unwrap();
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
            let mut writer = StagingWriter::create(dir.path(), id, key).unwrap();
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

    #[test]
    fn staging_recorded_before_migration_resumes_and_merkle_root_matches() {
        let dir = tempfile::tempdir().unwrap();
        let file_id = [7u8; FILE_ID_LEN];
        let key = chave_de_teste(7);
        let original: Vec<u8> = (0..50_000u32).map(|i| (i % 251) as u8).collect();

        // 1. Grava o staging (formato V1)
        let mut writer = StagingWriter::create(dir.path(), file_id, key.clone()).unwrap();
        writer.write(&original).unwrap();
        writer.finish().unwrap();

        // 2. Abre usando a versão padrão migrada (1)
        let mut reader = StagingReader::open_with_version(
            dir.path(),
            file_id,
            key,
            original.len() as u64,
            1,
        )
        .unwrap();

        let mut decrypted = Vec::new();
        reader.decrypt_to(&mut decrypted).unwrap();
        assert_eq!(decrypted, original);

        // 3. Raiz de Merkle bate com a do conteúdo original
        let expected_root = crate::file::merkle::merkle_root(std::io::Cursor::new(&original)).unwrap();
        let actual_root = crate::file::merkle::merkle_root(std::io::Cursor::new(&decrypted)).unwrap();
        assert_eq!(actual_root, expected_root);
    }

    #[test]
    fn staging_with_unknown_version_returns_error() {
        let dir = tempfile::tempdir().unwrap();
        let file_id = [8u8; FILE_ID_LEN];
        let key = chave_de_teste(8);

        let res = StagingReader::open_with_version(
            dir.path(),
            file_id,
            key,
            100,
            9,
        );
        assert!(matches!(res, Err(Error::UnsupportedVersion(9))));
    }

    fn write_unfinished(dir: &Path, data: &[u8], tag: u8) {
        let mut writer = StagingWriter::create(dir, [tag; FILE_ID_LEN], chave_de_teste(tag)).unwrap();
        writer.write(data).unwrap();
        // Sem `finish`: simula o bloqueio no meio, com a página final só na RAM.
    }

    #[test]
    fn finish_can_run_again_without_duplicating_the_last_page() {
        let dir = tempfile::tempdir().unwrap();
        let original: Vec<u8> = (0..PAGE_LEN + 777).map(|i| (i % 241) as u8).collect();
        let mut writer = StagingWriter::create(dir.path(), [11; FILE_ID_LEN], chave_de_teste(11)).unwrap();
        writer.write(&original).unwrap();
        writer.finish().unwrap();
        writer.finish().unwrap();

        let on_disk = fs::metadata(staging_path(dir.path(), &[11; FILE_ID_LEN])).unwrap().len();
        assert_eq!(on_disk, sealed_len(original.len() as u64));
        let mut out = Vec::new();
        StagingReader::open(dir.path(), [11; FILE_ID_LEN], chave_de_teste(11), original.len() as u64)
            .unwrap()
            .decrypt_to(&mut out)
            .unwrap();
        assert_eq!(out, original);
    }

    #[test]
    fn finish_cuts_a_torn_last_page_before_writing_it_again() {
        let dir = tempfile::tempdir().unwrap();
        let original: Vec<u8> = (0..PAGE_LEN + 777).map(|i| (i % 239) as u8).collect();
        let mut writer = StagingWriter::create(dir.path(), [12; FILE_ID_LEN], chave_de_teste(12)).unwrap();
        writer.write(&original).unwrap();
        // Uma tentativa anterior que morreu no meio da última página: os bytes
        // saíram pelo próprio arquivo do escritor, que ficou adiante deles.
        writer.file.write_all(&[0xEE; 100]).unwrap();

        writer.finish().unwrap();

        let mut out = Vec::new();
        StagingReader::open(dir.path(), [12; FILE_ID_LEN], chave_de_teste(12), original.len() as u64)
            .unwrap()
            .decrypt_to(&mut out)
            .unwrap();
        assert_eq!(out, original);
    }

    #[test]
    fn sealed_len_matches_a_finished_staging() {
        let dir = tempfile::tempdir().unwrap();
        for (tag, len) in [(7u8, 0usize), (8, 10), (9, PAGE_LEN), (10, PAGE_LEN * 2 + 3)] {
            let mut writer = StagingWriter::create(dir.path(), [tag; FILE_ID_LEN], chave_de_teste(tag)).unwrap();
            writer.write(&vec![1u8; len]).unwrap();
            writer.finish().unwrap();
            let on_disk = fs::metadata(staging_path(dir.path(), &[tag; FILE_ID_LEN])).unwrap().len();
            assert_eq!(sealed_len(len as u64), on_disk, "len {len}");
        }
    }

    #[test]
    fn full_pages_on_disk_ignores_the_unflushed_tail() {
        let dir = tempfile::tempdir().unwrap();
        write_unfinished(dir.path(), &vec![1u8; PAGE_LEN * 3 + 500], 1);
        assert_eq!(full_pages_on_disk(dir.path(), &[1; FILE_ID_LEN]).unwrap(), 3);
    }

    #[test]
    fn resume_keeps_the_prefix_and_continues_appending() {
        let dir = tempfile::tempdir().unwrap();
        let original: Vec<u8> = (0..PAGE_LEN * 3 + 500).map(|i| (i % 251) as u8).collect();
        write_unfinished(dir.path(), &original, 2);

        let keep = PAGE_LEN + 100;
        let mut seen = Vec::new();
        let mut writer =
            StagingWriter::resume(dir.path(), [2; FILE_ID_LEN], chave_de_teste(2), keep as u64, |p| seen.extend_from_slice(p))
                .unwrap();
        assert_eq!(seen, original[..keep]);
        assert_eq!(writer.bytes_written(), PAGE_LEN as u64);
        writer.write(&original[keep..]).unwrap();
        writer.finish().unwrap();

        let mut out = Vec::new();
        StagingReader::open(dir.path(), [2; FILE_ID_LEN], chave_de_teste(2), original.len() as u64)
            .unwrap()
            .decrypt_to(&mut out)
            .unwrap();
        assert_eq!(out, original);
    }

    #[test]
    fn resume_rejects_a_length_beyond_what_is_on_disk() {
        let dir = tempfile::tempdir().unwrap();
        write_unfinished(dir.path(), &vec![3u8; PAGE_LEN * 2 + 10], 3);
        let err = StagingWriter::resume(dir.path(), [3; FILE_ID_LEN], chave_de_teste(3), (PAGE_LEN * 2 + 1) as u64, |_| {})
            .unwrap_err();
        assert!(matches!(err, Error::Malformed(_)));
    }

    #[test]
    fn resume_with_wrong_key_fails_without_cutting_the_file() {
        let dir = tempfile::tempdir().unwrap();
        write_unfinished(dir.path(), &vec![4u8; PAGE_LEN * 2], 4);
        let path = staging_path(dir.path(), &[4; FILE_ID_LEN]);
        let before = fs::metadata(&path).unwrap().len();
        let err = StagingWriter::resume(dir.path(), [4; FILE_ID_LEN], chave_de_teste(5), PAGE_LEN as u64, |_| {})
            .unwrap_err();
        assert!(matches!(err, Error::AeadFailure));
        assert_eq!(fs::metadata(&path).unwrap().len(), before);
    }

    #[test]
    fn read_in_small_pieces_matches_decrypt_to() {
        let dir = tempfile::tempdir().unwrap();
        let original: Vec<u8> = (0..PAGE_LEN * 2 + 777).map(|i| (i % 249) as u8).collect();
        let mut writer = StagingWriter::create(dir.path(), [6; FILE_ID_LEN], chave_de_teste(6)).unwrap();
        writer.write(&original).unwrap();
        writer.finish().unwrap();

        let mut reader =
            StagingReader::open(dir.path(), [6; FILE_ID_LEN], chave_de_teste(6), original.len() as u64).unwrap();
        let mut out = Vec::new();
        let mut piece = [0u8; 1000];
        loop {
            let n = reader.read(&mut piece).unwrap();
            if n == 0 {
                break;
            }
            out.extend_from_slice(&piece[..n]);
        }
        assert_eq!(out, original);
    }
}
