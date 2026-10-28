//! Tipos de pacote dentro do plaintext cifrado — `docs/protocol.md` §6.2.
//!
//! Este byte só existe depois que o AEAD abriu: nenhum observador do fio vê
//! diferença entre um `MSG_TEXT` e um `AUDIO_CHUNK` (D4). O enum aqui serve
//! só para a camada de sessão decidir para qual fila de aplicação entregar o
//! corpo já decifrado.

use crate::{Error, Result};

/// Tipo de pacote transportado dentro do plaintext interno (§6.1, campo
/// `packet_type`).
///
/// `0x01`/`0x02` são do handshake PQXDH (§4) e nunca aparecem aqui: naquele
/// ponto ainda não existe sessão, então ainda não existe envelope.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PacketType {
    MsgText,
    MsgReceipt,
    MsgTyping,
    MsgReaction,
    MsgRevoke,
    FileMetadata,
    FileSymbol,
    FileFeedback,
    FileComplete,
    AudioChunk,
    ControlPing,
    ControlRekem,
    Unknown(u8),
}

impl PacketType {
    /// Todas as variantes conhecidas, na ordem da spec. Usado pelos testes exaustivos.
    pub const ALL: [PacketType; 12] = [
        PacketType::MsgText,
        PacketType::MsgReceipt,
        PacketType::MsgTyping,
        PacketType::MsgReaction,
        PacketType::MsgRevoke,
        PacketType::FileMetadata,
        PacketType::FileSymbol,
        PacketType::FileFeedback,
        PacketType::FileComplete,
        PacketType::AudioChunk,
        PacketType::ControlPing,
        PacketType::ControlRekem,
    ];

    /// Byte no fio (dentro do plaintext cifrado) correspondente a esta variante.
    pub const fn to_u8(self) -> u8 {
        match self {
            Self::MsgText => 0x10,
            Self::MsgReceipt => 0x11,
            Self::MsgTyping => 0x12,
            Self::MsgReaction => 0x13,
            Self::MsgRevoke => 0x14,
            Self::FileMetadata => 0x20,
            Self::FileSymbol => 0x21,
            Self::FileFeedback => 0x22,
            Self::FileComplete => 0x23,
            Self::AudioChunk => 0x30,
            Self::ControlPing => 0x40,
            Self::ControlRekem => 0x41,
            Self::Unknown(val) => val,
        }
    }

    /// Decodifica um byte de `packet_type`.
    ///
    /// `0x01` e `0x02` recebem um erro dedicado em vez de caírem no caso
    /// genérico: são valores válidos do protocolo, só que de uma fase que não
    /// deveria nunca reaparecer aqui dentro. Um pacote assim quase certamente
    /// indica confusão entre o canal de handshake e o de sessão, não corrupção
    /// aleatória — vale a pena que a mensagem de erro diga isso.
    ///
    /// Códigos desconhecidos fora da tabela e de handshake retornam `Unknown(u8)`
    /// para permitir que o app avance o ratchet normalmente e descarte apenas o
    /// corpo sem derrubar a sessão (§6.2).
    pub fn from_u8(value: u8) -> Result<Self> {
        match value {
            0x10 => Ok(Self::MsgText),
            0x11 => Ok(Self::MsgReceipt),
            0x12 => Ok(Self::MsgTyping),
            0x13 => Ok(Self::MsgReaction),
            0x14 => Ok(Self::MsgRevoke),
            0x20 => Ok(Self::FileMetadata),
            0x21 => Ok(Self::FileSymbol),
            0x22 => Ok(Self::FileFeedback),
            0x23 => Ok(Self::FileComplete),
            0x30 => Ok(Self::AudioChunk),
            0x40 => Ok(Self::ControlPing),
            0x41 => Ok(Self::ControlRekem),
            0x01 | 0x02 => Err(Error::Malformed(
                "tipo de pacote pertence ao handshake (0x01/0x02) e nunca aparece dentro do envelope de sessão",
            )),
            other => Ok(Self::Unknown(other)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_for_all_variants() {
        for &tipo in &PacketType::ALL {
            assert_eq!(PacketType::from_u8(tipo.to_u8()).unwrap(), tipo);
        }
    }

    #[test]
    fn rejects_handshake_bytes() {
        assert!(matches!(
            PacketType::from_u8(0x01),
            Err(Error::Malformed(_))
        ));
        assert!(matches!(
            PacketType::from_u8(0x02),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn decodes_unknown_values() {
        for valor in [0x00, 0x03, 0x15, 0x1f, 0x24, 0x31, 0x42, 0x7f, 0xff] {
            let parsed = PacketType::from_u8(valor).unwrap();
            assert_eq!(parsed, PacketType::Unknown(valor));
            assert_eq!(parsed.to_u8(), valor);
        }
    }
}

