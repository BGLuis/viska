//! Suítes criptográficas do protocolo Viska — `docs/protocol.md` §10 e D24.
//!
//! O identificador de suíte (`suite_id`) ocupa o byte 0 do QR Code e das mensagens
//! de handshake (`INIT`/`RESP`). A Suíte `0x01` (`V1`) corresponde à combinação
//! original de primitivas (§1: X25519 + ML-KEM-768, ChaCha20/XChaCha20-Poly1305,
//! BLAKE3, Ed25519) e permanece idêntica byte a byte ao formato congelado.

use crate::{Error, Result};

/// Identificador de suíte criptográfica (byte 0 do QR e do handshake PQXDH).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum Suite {
    V1 = 0x01,
    #[cfg(any(test, feature = "testing"))]
    TestV2 = 0x02,
}

#[cfg(any(test, feature = "testing"))]
thread_local! {
    static TEST_V2_ENABLED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static RETIRED_SUITES: std::cell::RefCell<std::collections::HashSet<u8>> = std::cell::RefCell::new(std::collections::HashSet::new());
}

#[cfg(any(test, feature = "testing"))]
pub fn set_test_suite_v2_enabled(enabled: bool) {
    TEST_V2_ENABLED.with(|c| c.set(enabled));
}

#[cfg(any(test, feature = "testing"))]
pub fn is_test_suite_v2_enabled() -> bool {
    TEST_V2_ENABLED.with(|c| c.get())
}

#[cfg(any(test, feature = "testing"))]
pub fn set_suite_retired(id: u8, retired: bool) {
    RETIRED_SUITES.with(|cell| {
        if retired {
            cell.borrow_mut().insert(id);
        } else {
            cell.borrow_mut().remove(&id);
        }
    });
}

impl Suite {
    /// Identificadores de suítes desativadas/aposentadas por este build do aplicativo (§10, D24).
    pub const RETIRED: &'static [u8] = &[];

    /// Verifica se uma suíte foi desativada/aposentada.
    pub fn is_retired(id: u8) -> bool {
        #[cfg(any(test, feature = "testing"))]
        if RETIRED_SUITES.with(|cell| cell.borrow().contains(&id)) {
            return true;
        }
        Self::RETIRED.contains(&id)
    }

    /// Identificador numérico da suíte no fio.
    pub const fn id(self) -> u8 {
        self as u8
    }

    /// Lista de todas as suítes suportadas por este build do aplicativo.
    pub const SUPPORTED: &'static [Suite] = &[Suite::V1];

    /// Suítes suportadas dinamicamente (inclui suítes de teste se habilitadas), excluindo desativadas.
    pub fn supported() -> Vec<Suite> {
        let mut suites = Vec::new();
        if !Self::is_retired(Suite::V1.id()) {
            suites.push(Suite::V1);
        }
        #[cfg(any(test, feature = "testing"))]
        if is_test_suite_v2_enabled() && !Self::is_retired(Suite::TestV2.id()) {
            suites.push(Suite::TestV2);
        }
        suites
    }

    /// Resolve a suíte a partir do identificador de 1 byte.
    /// Retorna `Error::SuiteRetired(id)` se a suíte foi desativada.
    /// Retorna `Error::UnsupportedVersion(id)` se o identificador não for conhecido/suportado.
    pub fn from_id(id: u8) -> Result<Self> {
        if Self::is_retired(id) {
            return Err(Error::SuiteRetired(id));
        }
        match id {
            0x01 => Ok(Self::V1),
            #[cfg(any(test, feature = "testing"))]
            0x02 if is_test_suite_v2_enabled() => Ok(Self::TestV2),
            other => Err(Error::UnsupportedVersion(other)),
        }
    }

    /// Comprimento esperado da mensagem de handshake `INIT` para esta suíte.
    pub const fn init_len(self) -> usize {
        match self {
            Self::V1 => 1218,
            #[cfg(any(test, feature = "testing"))]
            Self::TestV2 => 1218,
        }
    }

    /// Comprimento esperado da mensagem de handshake `RESP` para esta suíte.
    pub const fn resp_len(self) -> usize {
        match self {
            Self::V1 => 1122,
            #[cfg(any(test, feature = "testing"))]
            Self::TestV2 => 1122,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn v1_properties_match_protocol_spec() {
        let v1 = Suite::from_id(0x01).unwrap();
        assert_eq!(v1, Suite::V1);
        assert_eq!(v1.id(), 0x01);
        assert_eq!(v1.init_len(), 1218);
        assert_eq!(v1.resp_len(), 1122);
    }

    #[test]
    fn unknown_suite_id_is_unsupported() {
        set_test_suite_v2_enabled(false);
        assert!(matches!(
            Suite::from_id(0x00),
            Err(Error::UnsupportedVersion(0x00))
        ));
        assert!(matches!(
            Suite::from_id(0x02),
            Err(Error::UnsupportedVersion(0x02))
        ));
        assert!(matches!(
            Suite::from_id(0xff),
            Err(Error::UnsupportedVersion(0xff))
        ));
    }

    #[test]
    fn test_v2_can_be_enabled_in_tests() {
        set_test_suite_v2_enabled(false);
        assert!(Suite::from_id(0x02).is_err());

        set_test_suite_v2_enabled(true);
        let v2 = Suite::from_id(0x02).unwrap();
        assert_eq!(v2, Suite::TestV2);
        assert_eq!(v2.id(), 0x02);
        assert_eq!(v2.init_len(), 1218);
        assert_eq!(v2.resp_len(), 1122);
        assert_eq!(Suite::supported(), vec![Suite::V1, Suite::TestV2]);

        set_test_suite_v2_enabled(false);
        assert!(Suite::from_id(0x02).is_err());
    }
}
