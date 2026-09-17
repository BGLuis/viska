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

/// Safety number entre duas identidades, como 12 grupos de 5 dígitos.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct SafetyNumber([u32; GROUP_COUNT]);

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

        Self(groups)
    }

    /// Grupos crus, para renderização customizada na UI.
    pub fn groups(&self) -> &[u32; GROUP_COUNT] {
        &self.0
    }

    /// Representação canônica: 12 grupos de 5 dígitos separados por espaço.
    pub fn to_display_string(&self) -> String {
        self.0
            .iter()
            .map(|group| format!("{group:05}"))
            .collect::<Vec<_>>()
            .join(" ")
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
    fn independe_da_ordem_dos_argumentos() {
        let a = LocalIdentity::generate().unwrap().public();
        let b = LocalIdentity::generate().unwrap().public();

        assert_eq!(SafetyNumber::compute(&a, &b), SafetyNumber::compute(&b, &a));
    }

    #[test]
    fn muda_quando_uma_identidade_muda() {
        let a = LocalIdentity::generate().unwrap().public();
        let b = LocalIdentity::generate().unwrap().public();
        let c = LocalIdentity::generate().unwrap().public();

        assert_ne!(SafetyNumber::compute(&a, &b), SafetyNumber::compute(&a, &c));
    }

    #[test]
    fn formato_exibido_tem_60_digitos() {
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
    fn grupos_ficam_na_faixa_de_cinco_digitos() {
        let a = LocalIdentity::generate().unwrap().public();
        let b = LocalIdentity::generate().unwrap().public();

        for group in SafetyNumber::compute(&a, &b).groups() {
            assert!(*group < 100_000);
        }
    }
}
