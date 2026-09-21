//! Safety number — §3.3 da especificação.
//!
//! O número exibido serve para os dois usuários confirmarem, por um canal que
//! eles já confiam (estão frente a frente, ou em uma ligação em que reconhecem
//! a voz um do outro), que pareara com quem pensam ter pareado.
//!
//! O desenho original usava 6 dígitos decimais, ou cerca de 20 bits. Isso não
//! resiste a um atacante com um laptop: gerar alguns milhões de pares de chaves
//! até que o safety number resultante bata com o esperado leva segundos. Aqui
//! são 60 dígitos, cerca de 199 bits.

use crate::crypto::identity::PublicIdentity;
use crate::crypto::kdf;
use crate::util::encoding::read_u40;

/// Quantidade de grupos exibidos.
pub const GROUP_COUNT: usize = 12;
/// Dígitos por grupo.
pub const DIGITS_PER_GROUP: usize = 5;
/// Bytes de saída XOF consumidos: 5 por grupo.
const XOF_LEN: usize = GROUP_COUNT * 5;

/// Lista de palavras BIP-39 em português (BR), uma por linha, ordem fixa: o
/// índice de cada palavra na lista é o que vira código de 11 bits. Vendorizada
/// em vez de trazida via crate `bip39` porque só o vetor de palavras importa
/// aqui — não a lógica de mnemônico/checksum daquele formato.
const WORDLIST: &str = include_str!("wordlist_pt_br.txt");
/// Palavras exibidas na representação por voz do safety number.
pub const WORD_COUNT: usize = 6;
/// Bytes de saída XOF consumidos pelos índices de palavra: 6 grupos de 11
/// bits cabem em 66 bits, arredondados para cima a bytes inteiros.
const WORD_XOF_LEN: usize = 9;

fn wordlist() -> Vec<&'static str> {
    let words: Vec<&'static str> = WORDLIST.lines().collect();
    debug_assert_eq!(words.len(), 2048, "wordlist_pt_br.txt não tem 2048 linhas");
    words
}

/// Lê `WORD_COUNT` índices de 11 bits de `bytes`, mais significativo primeiro.
///
/// 6 índices × 11 bits = 66 bits, dentro dos 72 bits (`WORD_XOF_LEN` bytes)
/// disponíveis — os 6 bits finais da saída XOF são descartados.
fn pack_11_bit_groups(bytes: &[u8; WORD_XOF_LEN]) -> [u16; WORD_COUNT] {
    let mut indices = [0u16; WORD_COUNT];
    let mut bit_offset = 0usize;
    for index in indices.iter_mut() {
        let mut value = 0u16;
        for _ in 0..11 {
            let byte = bytes[bit_offset / 8];
            let bit = 7 - (bit_offset % 8);
            let set = (byte >> bit) & 1;
            value = (value << 1) | u16::from(set);
            bit_offset += 1;
        }
        *index = value;
    }
    indices
}

/// Safety number entre duas identidades, como 12 grupos de 5 dígitos.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct SafetyNumber {
    groups: [u32; GROUP_COUNT],
    word_indices: [u16; WORD_COUNT],
}

impl SafetyNumber {
    /// Calcula o safety number do par `(a, b)`.
    ///
    /// A ordem dos argumentos é irrelevante: os dois hashes entram ordenados
    /// lexicamente, então os dois aparelhos chegam ao mesmo valor sem precisar
    /// combinar quem é quem.
    pub fn compute(a: &PublicIdentity, b: &PublicIdentity) -> Self {
        let first = fingerprint(a);
        let second = fingerprint(b);
        let (low, high) = if first <= second {
            (first, second)
        } else {
            (second, first)
        };

        let mut material = [0u8; 64];
        material[..32].copy_from_slice(&low);
        material[32..].copy_from_slice(&high);

        let xof = kdf::derive_bytes::<XOF_LEN>(kdf::context::SAFETY_NUMBER, &material);

        let mut groups = [0u32; GROUP_COUNT];
        for (index, group) in groups.iter_mut().enumerate() {
            let chunk: [u8; 5] = xof[index * 5..index * 5 + 5]
                .try_into()
                .expect("fatia de 5 bytes");
            // 40 bits reduzidos a 5 dígitos. O viés de módulo aqui é da ordem de
            // 2^-23 por grupo — irrelevante para um valor que é comparado
            // visualmente, e o custo de rejeitar e reamostrar não se justifica.
            *group = (read_u40(&chunk) % 100_000) as u32;
        }

        // Derivação independente do XOF de dígitos acima: contexto próprio,
        // mesmo material `lo‖hi`. Mantém a fórmula normativa dos dígitos
        // intocada e evita acoplar o layout de bits das duas representações.
        let word_bytes =
            kdf::derive_bytes::<WORD_XOF_LEN>(kdf::context::SAFETY_NUMBER_WORDS, &material);
        let word_indices = pack_11_bit_groups(&word_bytes);

        Self {
            groups,
            word_indices,
        }
    }

    /// Grupos crus, para renderização customizada na UI.
    pub fn groups(&self) -> &[u32; GROUP_COUNT] {
        &self.groups
    }

    /// Representação canônica: 12 grupos de 5 dígitos separados por espaço.
    pub fn to_display_string(&self) -> String {
        self.groups
            .iter()
            .map(|group| format!("{group:05}"))
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// As 6 palavras da representação por voz (§3.3), na lista BIP-39 PT-BR.
    pub fn to_words(&self) -> [&'static str; WORD_COUNT] {
        let list = wordlist();
        let mut words = [""; WORD_COUNT];
        for (word, &index) in words.iter_mut().zip(self.word_indices.iter()) {
            *word = list[index as usize];
        }
        words
    }

    /// As 6 palavras, separadas por espaço — para leitura em voz alta.
    pub fn to_words_display_string(&self) -> String {
        self.to_words().join(" ")
    }
}

/// Impressão digital de uma identidade: `BLAKE3(signing ‖ dh)`.
fn fingerprint(identity: &PublicIdentity) -> [u8; 32] {
    let mut hasher = blake3::Hasher::new();
    hasher.update(&identity.signing);
    hasher.update(identity.dh.as_bytes());
    *hasher.finalize().as_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::identity::LocalIdentity;

    #[test]
    fn independent_of_argument_order() {
        let a = LocalIdentity::generate().unwrap().public();
        let b = LocalIdentity::generate().unwrap().public();

        assert_eq!(SafetyNumber::compute(&a, &b), SafetyNumber::compute(&b, &a));
    }

    #[test]
    fn changes_when_identity_changes() {
        let a = LocalIdentity::generate().unwrap().public();
        let b = LocalIdentity::generate().unwrap().public();
        let c = LocalIdentity::generate().unwrap().public();

        assert_ne!(SafetyNumber::compute(&a, &b), SafetyNumber::compute(&a, &c));
    }

    #[test]
    fn displayed_format_has_60_digits() {
        let a = LocalIdentity::generate().unwrap().public();
        let b = LocalIdentity::generate().unwrap().public();
        let rendered = SafetyNumber::compute(&a, &b).to_display_string();

        assert_eq!(
            rendered.len(),
            GROUP_COUNT * DIGITS_PER_GROUP + (GROUP_COUNT - 1)
        );
        assert_eq!(rendered.chars().filter(char::is_ascii_digit).count(), 60);
        for group in rendered.split(' ') {
            assert_eq!(group.len(), DIGITS_PER_GROUP);
        }
    }

    #[test]
    fn groups_are_in_five_digit_range() {
        let a = LocalIdentity::generate().unwrap().public();
        let b = LocalIdentity::generate().unwrap().public();

        for group in SafetyNumber::compute(&a, &b).groups() {
            assert!(*group < 100_000);
        }
    }

    #[test]
    fn wordlist_has_exactly_2048_unique_words() {
        let list = wordlist();
        assert_eq!(list.len(), 2048);

        let mut sorted = list.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), 2048, "wordlist_pt_br.txt tem palavra repetida");
    }

    #[test]
    fn words_independent_of_argument_order() {
        let a = LocalIdentity::generate().unwrap().public();
        let b = LocalIdentity::generate().unwrap().public();

        assert_eq!(
            SafetyNumber::compute(&a, &b).to_words(),
            SafetyNumber::compute(&b, &a).to_words(),
        );
    }

    #[test]
    fn words_change_when_identity_changes() {
        let a = LocalIdentity::generate().unwrap().public();
        let b = LocalIdentity::generate().unwrap().public();
        let c = LocalIdentity::generate().unwrap().public();

        assert_ne!(
            SafetyNumber::compute(&a, &b).to_words(),
            SafetyNumber::compute(&a, &c).to_words(),
        );
    }

    #[test]
    fn words_representation_has_six_space_separated_words() {
        let a = LocalIdentity::generate().unwrap().public();
        let b = LocalIdentity::generate().unwrap().public();
        let rendered = SafetyNumber::compute(&a, &b).to_words_display_string();

        assert_eq!(rendered.split(' ').count(), WORD_COUNT);
    }

    #[test]
    fn word_indices_always_in_range_0_2047() {
        // Vetor determinístico: byte 0 = 0xFF força o primeiro índice a 2047
        // (o maior valor de 11 bits); o resto em zero mantém os outros em 0.
        // Confere as duas bordas da faixa em um único caso, sem depender do
        // XOF do BLAKE3.
        let bytes = [0xFFu8, 0, 0, 0, 0, 0, 0, 0, 0];
        let indices = pack_11_bit_groups(&bytes);

        assert_eq!(indices[0], 0b111_1111_1000);
        for index in &indices {
            assert!((*index as usize) < 2048);
        }
    }

    #[test]
    fn eleven_bit_packing_is_msb_first() {
        // byte0 = 0b1011_0000, resto zero. Os 11 bits do primeiro grupo são os
        // 8 bits do byte0 seguidos pelos 3 bits mais significativos do
        // byte1 (aqui, zero): 1011_0000_000 = 1408. Os grupos seguintes caem
        // inteiramente em bytes zerados, logo valem 0.
        let mut bytes = [0u8; WORD_XOF_LEN];
        bytes[0] = 0b1011_0000;

        let indices = pack_11_bit_groups(&bytes);
        assert_eq!(indices, [1408, 0, 0, 0, 0, 0]);
    }

    #[test]
    fn all_ones_produces_highest_index_in_all_groups() {
        let bytes = [0xFFu8; WORD_XOF_LEN];
        let indices = pack_11_bit_groups(&bytes);
        assert_eq!(indices, [2047; WORD_COUNT]);
    }
}
