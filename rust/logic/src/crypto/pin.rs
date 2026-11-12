//! Derivação e verificação do PIN de desbloqueio (normal e de coação).
//!
//! O PIN é um portão de interface, não protege a chave mestra (que fica no
//! KeyStore/`keyring`). O que esta derivação protege é a **identidade** dos
//! dois PINs gravados em `security_config.json`, em texto claro: com SHA-256
//! rápido e um espaço de 10^4 a 10^8 candidatos, quem lê o arquivo descobria
//! em segundos qual PIN é o de coação, o que derrota o modo de coação
//! (`docs/threat-model.md` §3). Argon2id com custo de memória torna a varredura
//! cara, não inviável — o espaço continua pequeno.
//!
//! O formato gravado é a string PHC (`$argon2id$v=19$m=..,t=..,p=..$sal$hash`):
//! carrega algoritmo, parâmetros e sal, então subir o custo no futuro não exige
//! campo de versão — o hash é regravado no desbloqueio seguinte
//! ([`PinCheck::needs_rehash`]). O formato legado (SHA-256 hex de
//! `viska-pin-v1:<pin>`) ainda é aceito para migração.

use argon2::{Algorithm, Argon2, Params, PasswordHash, Version};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::util::encoding::ct_eq;
use crate::util::rng;
use crate::{Error, Result};

/// Custo de memória, em KiB (64 MiB). Escolhido pelo mantenedor sem medição em
/// aparelho modesto (issue #90); medir com o teste `#[ignore]` de benchmark.
pub const PIN_M_COST_KIB: u32 = 64 * 1024;
/// Passes sobre a memória.
pub const PIN_T_COST: u32 = 3;
/// Paralelismo. 1 porque o cálculo roda numa thread só do pool do FFI.
pub const PIN_P_COST: u32 = 1;

const SALT_LEN: usize = 16;
const OUTPUT_LEN: usize = 32;

const LEGACY_PREFIX: &[u8] = b"viska-pin-v1:";
const LEGACY_HEX_LEN: usize = 64;

// Sal fixo só para o cálculo de enchimento: o resultado é descartado, o que
// importa é gastar o mesmo trabalho que uma verificação real.
const DUMMY_SALT: [u8; SALT_LEN] = [0u8; SALT_LEN];

/// Qual PIN configurado coincidiu.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PinSlot {
    Normal,
    Duress,
}

/// Resultado de [`check_pin`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PinCheck {
    /// PIN que coincidiu, se algum.
    pub matched: Option<PinSlot>,
    /// O hash do PIN que coincidiu está no formato legado ou com parâmetros
    /// mais fracos que os atuais: quem chamou deve regravá-lo com
    /// [`hash_pin`], aproveitando que o PIN em claro está disponível agora.
    pub needs_rehash: bool,
}

/// Deriva o hash PHC de `pin` com sal aleatório novo do sistema operacional.
///
/// Sal por hash, não por instalação: os dois PINs nunca dividem sal, e não
/// existe campo separado de sal para manter.
pub fn hash_pin(pin: &[u8]) -> Result<String> {
    let salt = rng::array::<SALT_LEN>()?;
    let params = current_params()?;
    let ctx = Argon2::new(Algorithm::Argon2id, Version::V0x13, params.clone());
    let mut out = Zeroizing::new([0u8; OUTPUT_LEN]);
    ctx.hash_password_into(pin, &salt, out.as_mut())
        .map_err(|_| Error::InvalidState("derivação do PIN"))?;

    let phc = PasswordHash {
        algorithm: Algorithm::Argon2id.ident(),
        version: Some(Version::V0x13.into()),
        params: (&params)
            .try_into()
            .map_err(|_| Error::InvalidState("parâmetros do PIN"))?,
        salt: Some(
            argon2::password_hash::phc::Salt::new(&salt)
                .map_err(|_| Error::InvalidState("sal do PIN"))?,
        ),
        hash: Some(
            argon2::password_hash::phc::Output::new(out.as_ref())
                .map_err(|_| Error::InvalidState("saída do PIN"))?,
        ),
    };
    Ok(phc.to_string())
}

/// Confere `pin` contra os dois hashes gravados.
///
/// Sempre executa exatamente duas derivações Argon2id, uma por posição,
/// tenha ou não PIN de coação configurado e seja qual for o PIN digitado:
/// parar na primeira coincidência faria o PIN de coação responder mais rápido
/// que o normal, e quem cronometra o desbloqueio saberia qual foi digitado.
/// O custo por posição depende só do que está gravado, nunca do PIN.
///
/// Hash ausente, malformado ou com parâmetros acima dos atuais conta como não
/// coincidente (e ainda gasta a derivação de enchimento). Parâmetros acima dos
/// atuais são recusados porque o arquivo é editável por quem tem acesso ao
/// disco, e `m` arbitrário viraria uma alocação gigante no desbloqueio.
///
/// Se os dois coincidirem (só possível com arquivo adulterado, já que
/// `configurePins` recusa PINs iguais), a coação prevalece, como antes.
pub fn check_pin(pin: &[u8], normal: Option<&str>, duress: Option<&str>) -> PinCheck {
    let duress_outcome = verify_slot(pin, duress);
    let normal_outcome = verify_slot(pin, normal);

    let (matched, needs_rehash) = if duress_outcome.matched {
        (Some(PinSlot::Duress), duress_outcome.outdated)
    } else if normal_outcome.matched {
        (Some(PinSlot::Normal), normal_outcome.outdated)
    } else {
        (None, false)
    };
    PinCheck {
        matched,
        needs_rehash,
    }
}

/// Verdadeiro se `stored` está no formato legado SHA-256. A tela de PIN de
/// coação usa isso para pedir que o dono o redefina: só o PIN digitado pode ser
/// migrado, e o de coação raramente é digitado.
pub fn is_legacy_hash(stored: &str) -> bool {
    stored.len() == LEGACY_HEX_LEN && stored.bytes().all(|b| b.is_ascii_hexdigit())
}

struct SlotOutcome {
    matched: bool,
    outdated: bool,
}

fn verify_slot(pin: &[u8], stored: Option<&str>) -> SlotOutcome {
    let Some(stored) = stored else {
        dummy_derivation(pin);
        return SlotOutcome {
            matched: false,
            outdated: false,
        };
    };

    if is_legacy_hash(stored) {
        // O SHA-256 é instantâneo: sem a derivação de enchimento, um PIN legado
        // ficaria distinguível pelo tempo de um PIN já migrado.
        dummy_derivation(pin);
        return SlotOutcome {
            matched: legacy_matches(pin, stored),
            outdated: true,
        };
    }

    match parse_phc(stored) {
        Some(parsed) => {
            let ctx = Argon2::new(Algorithm::Argon2id, Version::V0x13, parsed.params);
            let mut out = Zeroizing::new([0u8; OUTPUT_LEN]);
            let matched = ctx
                .hash_password_into(pin, &parsed.salt[..parsed.salt_len], out.as_mut())
                .is_ok()
                && ct_eq(out.as_ref(), parsed.hash.as_ref());
            SlotOutcome {
                matched,
                outdated: parsed.outdated,
            }
        }
        None => {
            dummy_derivation(pin);
            SlotOutcome {
                matched: false,
                outdated: false,
            }
        }
    }
}

struct ParsedPhc {
    params: Params,
    salt: [u8; 64],
    salt_len: usize,
    hash: Zeroizing<[u8; OUTPUT_LEN]>,
    outdated: bool,
}

fn parse_phc(stored: &str) -> Option<ParsedPhc> {
    let phc = PasswordHash::new(stored).ok()?;
    if phc.algorithm != Algorithm::Argon2id.ident() {
        return None;
    }
    if phc.version != Some(Version::V0x13.into()) {
        return None;
    }
    let params = Params::try_from(&phc).ok()?;
    if params.m_cost() > PIN_M_COST_KIB
        || params.t_cost() > PIN_T_COST
        || params.p_cost() > PIN_P_COST
        || !params.keyid().is_empty()
        || !params.data().is_empty()
    {
        return None;
    }
    let salt_src = phc.salt?;
    let salt_bytes: &[u8] = salt_src.as_ref();
    // Mesmo piso do Argon2 (8 bytes); o teto vem do próprio `Salt` do PHC.
    if salt_bytes.len() < 8 {
        return None;
    }
    let mut salt = [0u8; 64];
    salt.get_mut(..salt_bytes.len())?
        .copy_from_slice(salt_bytes);

    let hash_src = phc.hash?;
    let mut hash = Zeroizing::new([0u8; OUTPUT_LEN]);
    if hash_src.len() != OUTPUT_LEN {
        return None;
    }
    hash.copy_from_slice(hash_src.as_bytes());

    let outdated = params.m_cost() < PIN_M_COST_KIB
        || params.t_cost() < PIN_T_COST
        || params.p_cost() < PIN_P_COST;
    Some(ParsedPhc {
        params,
        salt,
        salt_len: salt_bytes.len(),
        hash,
        outdated,
    })
}

fn legacy_matches(pin: &[u8], stored: &str) -> bool {
    let mut expected = Zeroizing::new([0u8; 32]);
    if hex::decode_to_slice(stored, expected.as_mut()).is_err() {
        return false;
    }
    let mut input = Zeroizing::new(Vec::with_capacity(LEGACY_PREFIX.len() + pin.len()));
    input.extend_from_slice(LEGACY_PREFIX);
    input.extend_from_slice(pin);
    let digest = Zeroizing::new(<[u8; 32]>::from(Sha256::digest(input.as_slice())));
    ct_eq(digest.as_ref(), expected.as_ref())
}

fn dummy_derivation(pin: &[u8]) {
    let Ok(params) = current_params() else {
        return;
    };
    let ctx = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut out = Zeroizing::new([0u8; OUTPUT_LEN]);
    // Resultado descartado de propósito; `black_box` impede que o otimizador
    // conclua que a derivação inteira é código morto.
    let _ = ctx.hash_password_into(pin, &DUMMY_SALT, out.as_mut());
    std::hint::black_box(out.as_ref());
}

fn current_params() -> Result<Params> {
    Params::new(PIN_M_COST_KIB, PIN_T_COST, PIN_P_COST, Some(OUTPUT_LEN))
        .map_err(|_| Error::InvalidState("parâmetros do PIN"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn legacy_hash(pin: &str) -> String {
        let mut input = LEGACY_PREFIX.to_vec();
        input.extend_from_slice(pin.as_bytes());
        hex::encode(Sha256::digest(&input))
    }

    fn phc_with_params(pin: &[u8], m: u32, t: u32, p: u32) -> String {
        let params = Params::new(m, t, p, Some(OUTPUT_LEN)).unwrap();
        let salt = [7u8; SALT_LEN];
        let ctx = Argon2::new(Algorithm::Argon2id, Version::V0x13, params.clone());
        let mut out = [0u8; OUTPUT_LEN];
        ctx.hash_password_into(pin, &salt, &mut out).unwrap();
        PasswordHash {
            algorithm: Algorithm::Argon2id.ident(),
            version: Some(Version::V0x13.into()),
            params: (&params).try_into().unwrap(),
            salt: Some(argon2::password_hash::phc::Salt::new(&salt).unwrap()),
            hash: Some(argon2::password_hash::phc::Output::new(&out).unwrap()),
        }
        .to_string()
    }

    #[test]
    fn hash_is_argon2id_phc_with_current_params() {
        let h = hash_pin(b"1234").unwrap();
        assert!(h.starts_with("$argon2id$v=19$m=65536,t=3,p=1$"), "{h}");
        let parsed = parse_phc(&h).expect("o próprio hash tem que ser aceito");
        assert!(!parsed.outdated);
        assert_eq!(parsed.salt_len, SALT_LEN);
    }

    #[test]
    fn pin_hashes_differ_across_installs_with_same_pin() {
        let a = hash_pin(b"1234").unwrap();
        let b = hash_pin(b"1234").unwrap();
        assert_ne!(
            a, b,
            "sal aleatório por hash tem que gerar strings distintas"
        );
        assert_eq!(
            check_pin(b"1234", Some(&a), None).matched,
            Some(PinSlot::Normal)
        );
        assert_eq!(
            check_pin(b"1234", Some(&b), None).matched,
            Some(PinSlot::Normal)
        );
    }

    #[test]
    fn matches_normal_and_duress_and_rejects_wrong_pin() {
        let normal = hash_pin(b"1234").unwrap();
        let duress = hash_pin(b"9999").unwrap();
        let check = |pin: &[u8]| check_pin(pin, Some(&normal), Some(&duress));
        assert_eq!(
            check(b"1234"),
            PinCheck {
                matched: Some(PinSlot::Normal),
                needs_rehash: false
            }
        );
        assert_eq!(check(b"9999").matched, Some(PinSlot::Duress));
        assert_eq!(
            check(b"0000"),
            PinCheck {
                matched: None,
                needs_rehash: false
            }
        );
    }

    #[test]
    fn duress_wins_when_both_slots_match() {
        let h = hash_pin(b"1234").unwrap();
        assert_eq!(
            check_pin(b"1234", Some(&h), Some(&h)).matched,
            Some(PinSlot::Duress)
        );
    }

    #[test]
    fn no_configured_pin_never_matches() {
        assert_eq!(
            check_pin(b"1234", None, None),
            PinCheck {
                matched: None,
                needs_rehash: false
            }
        );
    }

    #[test]
    fn accepts_legacy_hash_and_flags_rehash() {
        let legacy = legacy_hash("1234");
        assert!(is_legacy_hash(&legacy));
        assert_eq!(
            check_pin(b"1234", Some(&legacy), None),
            PinCheck {
                matched: Some(PinSlot::Normal),
                needs_rehash: true
            }
        );
        assert_eq!(check_pin(b"4321", Some(&legacy), None).matched, None);
        assert_eq!(
            check_pin(
                b"9999",
                Some(&hash_pin(b"1234").unwrap()),
                Some(&legacy_hash("9999"))
            ),
            PinCheck {
                matched: Some(PinSlot::Duress),
                needs_rehash: true
            }
        );
    }

    #[test]
    fn accepts_legacy_reference_value() {
        // sha256("viska-pin-v1:1234") em hex minúsculo, calculado fora deste
        // código (`sha256sum`), igual ao que o `crypto` do Dart gravava. Trava a
        // compatibilidade da migração com os arquivos que já existem.
        const STORED: &str = "57a7eaef7b07d67b536a9485609f91ed36efe6cef17b268190470d9f4afd8f2a";
        assert_eq!(
            check_pin(b"1234", Some(STORED), None).matched,
            Some(PinSlot::Normal)
        );
        assert_eq!(check_pin(b"1235", Some(STORED), None).matched, None);
    }

    #[test]
    fn weaker_params_match_and_flag_rehash() {
        let weak = phc_with_params(b"1234", 8 * 1024, 1, 1);
        assert_eq!(
            check_pin(b"1234", Some(&weak), None),
            PinCheck {
                matched: Some(PinSlot::Normal),
                needs_rehash: true
            }
        );
    }

    #[test]
    fn rejects_params_above_current() {
        let strong = phc_with_params(b"1234", 8 * 1024, PIN_T_COST + 1, 1);
        assert!(parse_phc(&strong).is_none());
        assert_eq!(check_pin(b"1234", Some(&strong), None).matched, None);
        let wide = format!(
            "$argon2id$v=19$m={},t=3,p=1$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            PIN_M_COST_KIB + 1
        );
        assert!(parse_phc(&wide).is_none());
    }

    #[test]
    fn rejects_other_algorithms_and_garbage() {
        let h = hash_pin(b"1234").unwrap();
        for bad in [
            h.replace("argon2id", "argon2i"),
            h.replace("v=19", "v=16"),
            String::new(),
            "lixo".into(),
            "$argon2id$".into(),
            "g".repeat(LEGACY_HEX_LEN),
        ] {
            assert_eq!(check_pin(b"1234", Some(&bad), None).matched, None, "{bad}");
        }
    }

    #[test]
    fn rejects_tampered_hash() {
        let h = hash_pin(b"1234").unwrap();
        let (prefix, last) = h.rsplit_once('$').unwrap();
        let mut bytes = last.as_bytes().to_vec();
        bytes[0] = if bytes[0] == b'A' { b'B' } else { b'A' };
        let tampered = format!("{prefix}${}", String::from_utf8(bytes).unwrap());
        assert_eq!(check_pin(b"1234", Some(&tampered), None).matched, None);
    }

    /// Mede o custo real no aparelho: `cargo test --release -- --ignored
    /// pin_kdf_benchmark --nocapture` (ou o equivalente no alvo Android).
    #[test]
    #[ignore]
    fn pin_kdf_benchmark() {
        let normal = hash_pin(b"12345678").unwrap();
        let duress = hash_pin(b"87654321").unwrap();
        let start = std::time::Instant::now();
        let _ = hash_pin(b"12345678").unwrap();
        let hash_time = start.elapsed();
        let start = std::time::Instant::now();
        let _ = check_pin(b"00000000", Some(&normal), Some(&duress));
        let check_time = start.elapsed();
        println!("hash_pin: {hash_time:?}; check_pin (duas derivações): {check_time:?}");
    }
}
