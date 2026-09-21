//! Raiz de Merkle BLAKE3 do arquivo — `docs/protocol.md` §7.2.
//!
//! A raiz que trafega no manifesto (`FILE_METADATA`, §7.1) é `blake3::hash`
//! do plaintext completo do arquivo. Duas responsabilidades vivem aqui:
//!
//! 1. [`merkle_root`] — calcula essa raiz em streaming, sem nunca reter mais
//!    que um pedaço de leitura em RAM. Usada pelo emissor (preencher o campo
//!    do manifesto) e pelo receptor (checagem final, antes do commit do
//!    staging, §7.5). Isto sozinho já é suficiente para nunca montar o
//!    arquivo inteiro na memória volátil.
//!
//! 2. [`block_chaining_value`] — o *chaining value* (CV) que um trecho do
//!    arquivo, numa posição conhecida, ocuparia na árvore interna do BLAKE3.
//!    Usa `blake3::hazmat`, o módulo estável para manipular a árvore
//!    diretamente (sucessor do antigo `guts`, pensado para protocolos que
//!    precisam de acesso à estrutura interna — exatamente o nosso caso).
//!
//! **O que a peça 2 não resolve sozinha**: autenticar um source block *assim
//! que decodificado* (a promessa de §7.2 de detectar corrupção "no bloco",
//! não só ao final) exige comparar o CV computado contra um CV *esperado*
//! para aquele bloco — e não existe forma de obter esse valor esperado só a
//! partir da `merkle_root` final sem já ter processado o arquivo inteiro até
//! ali. A única saída criptográfica é o manifesto (ou um pacote logo depois
//! dele) carregar um CV de 32 B por bloco. Isso é uma mudança de formato de
//! fio sobre `docs/protocol.md` §7.1 hoje, e não foi decidida aqui — ver
//! `docs/reports/FASE-4-PIPELINE-DE-ARQUIVOS.md`. Por isso
//! `block_chaining_value` recebe posição e bytes e devolve o CV computado,
//! sem tentar adivinhar de onde viria um CV esperado para comparar.
//!
//! Todo bloco de arquivo, exceto possivelmente o último, tem tamanho que é
//! uma potência de dois múltipla de `CHUNK_LEN` (1024 B): `block_symbols` é
//! travado em potências de dois até 1.024 (D6) e `symbol_size` é 16384 ou
//! 65536 — ambos potências de dois (`wire::transport::Transport::buckets`).
//! Isso não é coincidência: é o que permite que blocos completos sejam
//! subárvores válidas do BLAKE3 na posição em que caem, sem exigir nenhum
//! ajuste fino de alinhamento por parte de quem chama.

use std::io::Read;

use blake3::hazmat::{left_subtree_len, max_subtree_len, ChainingValue, HasherExt};
use blake3::{Hash, Hasher, CHUNK_LEN};

use crate::{Error, Result};

/// Tamanho do bloco de leitura usado por [`merkle_root`] — não tem relação
/// com `symbol_size` nem com `CHUNK_LEN`; é só o quanto fica em RAM de cada
/// vez ao ler o `reader`. 64 KiB casa com o tamanho de página do staging
/// (§7.5, F3), então reaproveita o mesmo número em vez de inventar outro.
const READ_CHUNK_LEN: usize = 65536;

/// Calcula a raiz BLAKE3 de um stream inteiro, sem nunca reter mais que
/// [`READ_CHUNK_LEN`] bytes em RAM de cada vez.
///
/// `Hasher::update` já é streaming por natureza — não usa `hazmat` aqui,
/// porque não precisamos de nenhuma posição arbitrária: o stream é lido do
/// início ao fim, na ordem, exatamente como `Hasher` espera.
pub fn merkle_root(mut reader: impl Read) -> Result<Hash> {
    let mut hasher = Hasher::new();
    let mut buf = vec![0u8; READ_CHUNK_LEN];
    loop {
        let n = reader
            .read(&mut buf)
            .map_err(|_| Error::Malformed("falha lendo stream para calcular a raiz Merkle"))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize())
}

/// Compara uma raiz computada contra a raiz esperada (vinda do manifesto).
///
/// A raiz não é segredo — viaja em claro no manifesto antes da transferência
/// começar — então comparação em tempo constante não defende nada aqui que
/// já não seja público; usa [`crate::util::encoding::ct_eq`] mesmo assim,
/// por consistência com o resto do crate ao comparar hashes de 32 B.
pub fn verify_root(computed: &Hash, expected: &[u8; 32]) -> Result<()> {
    if crate::util::encoding::ct_eq(computed.as_bytes(), expected) {
        Ok(())
    } else {
        Err(Error::MerkleMismatch)
    }
}

/// O *chaining value* que o trecho `data`, começando em `offset` bytes desde
/// o início do arquivo, ocupa na árvore interna do BLAKE3 — não é, por si
/// só, comparável a uma raiz: só vira uma raiz depois de mesclado com o(s)
/// CV(s) irmão(s) via `blake3::hazmat::merge_subtrees_root`.
///
/// Erros aqui protegem contra o próprio `hazmat` entrar em pânico: as duas
/// funções que ele expõe para isso (`max_subtree_len`, dentro de
/// `blake3::hazmat`) fazem `assert!` sobre alinhamento em vez de devolver
/// `Result`, porque a API é para quem já garante isso por construção — mas
/// aqui `offset`/`data.len()` nascem de campos do manifesto, então tratamos
/// como dado de rede: nunca confiar no alinhamento sem checar antes.
pub fn block_chaining_value(offset: u64, data: &[u8]) -> Result<ChainingValue> {
    if data.is_empty() {
        return Err(Error::Malformed(
            "bloco de arquivo vazio não tem chaining value",
        ));
    }

    if offset > 0 {
        if offset % CHUNK_LEN as u64 != 0 {
            return Err(Error::Malformed(
                "offset de bloco não é múltiplo de CHUNK_LEN (1024 B) — não é uma posição válida na árvore BLAKE3",
            ));
        }
        // `max_subtree_len` só é `None` para offset == 0 (já tratado acima).
        let max_len = max_subtree_len(offset).expect("offset > 0 checado acima");
        if data.len() as u64 > max_len {
            return Err(Error::Malformed(
                "bloco maior do que a subárvore máxima válida nesta posição",
            ));
        }
    }

    Ok(Hasher::new()
        .set_input_offset(offset)
        .update(data)
        .finalize_non_root())
}

/// Ponto de corte que produz duas subárvores válidas para um input de
/// `total_len` bytes: o bloco esquerdo fica com `left_subtree_len(total_len)`
/// bytes, o direito com o restante. Exposto para quem monta pares de blocos
/// a mesclar via `blake3::hazmat::merge_subtrees_root` — sobretudo em teste,
/// para provar que o alinhamento importa de verdade (ver
/// `merge_com_split_errado_nao_bate_com_blake3_hash`).
pub fn left_split_len(total_len: u64) -> u64 {
    left_subtree_len(total_len)
}

pub use blake3::hazmat::{merge_subtrees_non_root, merge_subtrees_root};
pub use blake3::hazmat::Mode as HazmatMode;

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn root_via_hazmat_two_way_split(input: &[u8]) -> Hash {
        // Reproduz o exemplo da documentação do `blake3::hazmat`: split no
        // ponto que `left_subtree_len` indica, CV de cada metade, e o par
        // final vira a raiz — deve bater byte a byte com `blake3::hash`.
        let left_len = left_split_len(input.len() as u64) as usize;
        let left_cv = block_chaining_value(0, &input[..left_len]).unwrap();
        let right_cv = block_chaining_value(left_len as u64, &input[left_len..]).unwrap();
        merge_subtrees_root(&left_cv, &right_cv, HazmatMode::Hash)
    }

    #[test]
    fn merkle_root_matches_blake3_hash_for_various_sizes() {
        for len in [0usize, 1, 1023, 1024, 1025, 2048, 100_000, 500_003] {
            let data = vec![0x5au8; len];
            let esperado = blake3::hash(&data);
            let obtido = merkle_root(Cursor::new(&data)).unwrap();
            assert_eq!(obtido, esperado, "tamanho {len}");
        }
    }

    #[test]
    fn merkle_root_independent_of_read_chunk_size() {
        // Um `Read` que devolve no máximo 3 bytes por chamada, bem menor que
        // `READ_CHUNK_LEN` — prova que o resultado não depende de onde os
        // limites de `read()` caem, só do conteúdo.
        struct Trickle<'a>(&'a [u8]);
        impl<'a> Read for Trickle<'a> {
            fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
                let n = self.0.len().min(buf.len()).min(3);
                buf[..n].copy_from_slice(&self.0[..n]);
                self.0 = &self.0[n..];
                Ok(n)
            }
        }

        let data = vec![0x11u8; 10_007];
        let esperado = blake3::hash(&data);
        let obtido = merkle_root(Trickle(&data)).unwrap();
        assert_eq!(obtido, esperado);
    }

    #[test]
    fn verify_root_accepts_correct_root_and_rejects_any_other() {
        let data = b"conteudo do arquivo de teste".to_vec();
        let root = merkle_root(Cursor::new(&data)).unwrap();

        assert!(verify_root(&root, root.as_bytes()).is_ok());

        let mut errada = *root.as_bytes();
        errada[0] ^= 0xff;
        assert!(matches!(
            verify_root(&root, &errada),
            Err(Error::MerkleMismatch)
        ));
    }

    #[test]
    fn merged_block_chaining_value_matches_blake3_hash() {
        for len in [CHUNK_LEN as u64 + 1, 5_000, 1 << 20, (1 << 20) + 777] {
            let data = vec![0x7eu8; len as usize];
            let obtido = root_via_hazmat_two_way_split(&data);
            let esperado = blake3::hash(&data);
            assert_eq!(obtido, esperado, "tamanho {len}");
        }
    }

    #[test]
    fn block_chaining_value_with_correct_offset_fits_root() {
        // Três blocos de tamanho fixo (potência de dois de chunks) mais um
        // resto — o layout real de um arquivo particionado em source blocks
        // (D6), exceto pelo último bloco, que pode ser mais curto.
        let block_len = 4 * CHUNK_LEN; // 4096 B — potência de dois de chunks.
        let total_len = block_len * 2 + 500; // dois blocos completos + resto.
        let data: Vec<u8> = (0..total_len).map(|i| (i % 251) as u8).collect();

        // Årvore real do BLAKE3 para este tamanho não corta exatamente nos
        // limites de `block_len` em geral — este teste não assume isso; só
        // prova que o CV de um range que *é* uma subárvore válida (aqui, os
        // dois blocos completos juntos, mais o resto) mescla corretamente.
        let left_len = left_split_len(total_len as u64) as usize;
        let left_cv = block_chaining_value(0, &data[..left_len]).unwrap();
        let right_cv = block_chaining_value(left_len as u64, &data[left_len..]).unwrap();
        let root = merge_subtrees_root(&left_cv, &right_cv, HazmatMode::Hash);

        assert_eq!(root, blake3::hash(&data));
    }

    #[test]
    fn merge_with_wrong_split_does_not_match_blake3_hash() {
        // `hazmat` não valida que o split seja *o* split correto — só que
        // cada pedaço, isoladamente, é uma posição/tamanho estruturalmente
        // possível na árvore (o que `block_chaining_value` já checa via
        // `max_subtree_len`). Este teste escolhe um split que passa por essa
        // checagem estrutural mas não é o ponto de corte real
        // (`left_subtree_len`), provando que a checagem estrutural sozinha
        // não basta para a raiz bater — é preciso usar exatamente
        // `left_subtree_len`, não qualquer split "válido na forma".
        let data = vec![0x33u8; 10_000];
        let split_certo = left_split_len(data.len() as u64) as usize;

        // 9 * CHUNK_LEN: contador de chunk ímpar (9), então
        // `max_subtree_len` permite no máximo 1 chunk a partir daqui — o
        // resto (784 B) cabe, então a checagem estrutural passa, mas não é
        // `split_certo`.
        let split_errado = 9 * CHUNK_LEN;
        assert_ne!(split_certo, split_errado, "teste precisa de dois splits distintos");
        assert!(split_errado < data.len());

        let left_cv = block_chaining_value(0, &data[..split_errado]).unwrap();
        let right_cv = block_chaining_value(split_errado as u64, &data[split_errado..]).unwrap();
        let root_errada = merge_subtrees_root(&left_cv, &right_cv, HazmatMode::Hash);

        assert_ne!(root_errada, blake3::hash(&data));
    }

    #[test]
    fn block_chaining_value_rejects_misaligned_offset() {
        let data = vec![0u8; 100];
        assert!(matches!(
            block_chaining_value(1, &data),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn block_chaining_value_rejects_block_larger_than_maximum_subtree() {
        // offset = CHUNK_LEN (um chunk já consumido) só admite subárvore de
        // no máximo 1 chunk nessa posição (contador ímpar -> maior potência
        // de dois que divide é 1).
        let offset = CHUNK_LEN as u64;
        let bloco_grande_demais = vec![0u8; 2 * CHUNK_LEN];
        assert!(matches!(
            block_chaining_value(offset, &bloco_grande_demais),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn block_chaining_value_rejects_empty_block() {
        assert!(matches!(
            block_chaining_value(0, &[]),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn rejects_any_tampered_bit_in_content() {
        // Corromper 1 bit em qualquer posição do conteúdo muda a raiz — a
        // propriedade que faz a Merkle root servir de guarda de integridade.
        let original = vec![0x99u8; 300];
        let root_original = merkle_root(Cursor::new(&original)).unwrap();

        for index in 0..original.len() {
            for bit in 0..8u8 {
                let mut adulterado = original.clone();
                adulterado[index] ^= 1 << bit;
                let root_adulterada = merkle_root(Cursor::new(&adulterado)).unwrap();
                assert_ne!(
                    root_original, root_adulterada,
                    "byte {index} bit {bit} não mudou a raiz"
                );
            }
        }
    }
}
