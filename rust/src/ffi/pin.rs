//! Derivação e verificação do PIN de desbloqueio — ver `viska_proto::crypto::pin`.
//!
//! **Exceção explícita à regra "nenhum segredo cruza o FFI"** (decisão do
//! mantenedor na issue #90): o PIN atravessa a fronteira no sentido Dart→Rust,
//! porque é digitado na interface e o Dart já o tem de qualquer forma. O
//! caminho inverso continua fechado: só volta a string PHC, que é gravada em
//! claro em `security_config.json` e não é segredo, ou o resultado da
//! comparação. Fazer a derivação aqui, e não em Dart, dá velocidade nativa ao
//! Argon2id (custo maior pelo mesmo tempo), sal do CSPRNG do sistema e
//! `zeroize` dos buffers.
//!
//! As funções não são `#[frb(sync)]`: cada derivação gasta 64 MiB e centenas
//! de milissegundos, e precisa rodar no pool do FFI, fora da thread de UI.

use viska_proto::crypto::pin::{self, PinSlot};
use zeroize::Zeroizing;

use crate::ffi::error::FfiError;

/// Qual PIN configurado coincidiu com o digitado.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PinMatchDto {
    NoMatch,
    Normal,
    Duress,
}

/// Resultado de [`pin_check`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PinCheckDto {
    pub matched: PinMatchDto,
    /// O hash que coincidiu está no formato legado ou com custo abaixo do
    /// atual: o Dart deve regravá-lo com [`pin_hash`] enquanto tem o PIN.
    pub needs_rehash: bool,
}

/// Deriva o hash PHC (Argon2id, sal aleatório novo) de `pin`.
pub fn pin_hash(pin: String) -> Result<String, FfiError> {
    let pin = Zeroizing::new(pin);
    Ok(pin::hash_pin(pin.as_bytes())?)
}

/// Confere `pin` contra os hashes gravados, sempre com o mesmo trabalho seja
/// qual for o PIN digitado (ver `viska_proto::crypto::pin::check_pin`).
pub fn pin_check(
    pin: String,
    normal_hash: Option<String>,
    duress_hash: Option<String>,
) -> PinCheckDto {
    let pin = Zeroizing::new(pin);
    let check = pin::check_pin(
        pin.as_bytes(),
        normal_hash.as_deref(),
        duress_hash.as_deref(),
    );
    PinCheckDto {
        matched: match check.matched {
            None => PinMatchDto::NoMatch,
            Some(PinSlot::Normal) => PinMatchDto::Normal,
            Some(PinSlot::Duress) => PinMatchDto::Duress,
        },
        needs_rehash: check.needs_rehash,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_ffi_surface() {
        let normal = pin_hash("1234".into()).unwrap();
        let duress = pin_hash("9999".into()).unwrap();
        let check = |p: &str| pin_check(p.into(), Some(normal.clone()), Some(duress.clone()));
        assert_eq!(check("1234").matched, PinMatchDto::Normal);
        assert_eq!(check("9999").matched, PinMatchDto::Duress);
        assert_eq!(check("0000").matched, PinMatchDto::NoMatch);
        assert!(!check("1234").needs_rehash);
    }
}
