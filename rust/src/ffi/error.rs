//! Erro que atravessa a fronteira FFI.
//!
//! Não é um espelho 1:1 de [`viska_proto::Error`]: aquele enum tem variantes do
//! ratchet e do AEAD que nunca deveriam aparecer nesta superfície, e expô-las
//! acoplaria a API pública do FFI aos detalhes internos do núcleo. Aqui só
//! entram as distinções que a UI realmente precisa tratar de forma diferente —
//! em especial `ForgedKey`, que sinaliza um QR forjado (ponto de ordem baixa),
//! não um erro de leitura como os outros.

/// Erro devolvido por uma chamada FFI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FfiError {
    /// Comprimento errado, versão desconhecida ou campo malformado.
    QrMalformed,
    /// A assinatura do payload não confere.
    QrBadSignature,
    /// O QR lido é o desta própria identidade.
    SelfPairing,
    /// Chave X25519 de ordem baixa — sinal de payload forjado, não de leitura
    /// ruim. Merece mensagem própria na UI (ver armadilha 4 do relatório).
    ForgedKey,
    /// Falha ao abrir, ler ou gravar no banco cifrado.
    StoreFailure,
    /// Nenhum contato com o `device_id` informado.
    ContactNotFound,
    /// O contador de envio da sessão cruzou o limiar de segurança — a UI
    /// precisa iniciar uma sessão nova (nova sinalização/handshake) com este
    /// contato, não é um erro para simplesmente relatar e ignorar.
    SessionExpired,
    /// Chamou `feed_handshake`/`decrypt_incoming` para um contato sem sessão
    /// aberta ainda. Não vem de `viska_proto::Error` — é puramente um erro de
    /// uso da API do FFI: quem chama precisa ter chamado `ensure_session`
    /// primeiro.
    NoActiveSession,
    /// Raiz de Merkle recomputada não bate com a do manifesto — arquivo
    /// corrompido ou adulterado em trânsito (§7.2/§7.5). Distinto de
    /// `Internal` porque a UI precisa oferecer "tentar de novo", não só
    /// relatar uma falha genérica.
    FileCorrupted,
    /// O núcleo ou banco está trancado (auto-lock ou segundo plano) e requer
    /// autenticação prévia para executar operações.
    Locked,
    /// Falha de autenticação ou decifragem AEAD.
    AeadFailure,
    /// Formato inválido ou corrompido.
    Malformed,
    /// Qualquer outra falha interna, sem informação útil para a UI.
    Internal,
}

impl From<viska_proto::Error> for FfiError {
    fn from(err: viska_proto::Error) -> Self {
        use viska_proto::Error;
        match err {
            Error::BadLength { .. }
            | Error::UnsupportedVersion(_)
            | Error::Malformed(_)
            | Error::InvalidPublicKey(_) => FfiError::QrMalformed,
            Error::BadSignature => FfiError::QrBadSignature,
            Error::SelfPairing => FfiError::SelfPairing,
            Error::LowOrderPoint => FfiError::ForgedKey,
            Error::Store => FfiError::StoreFailure,
            Error::ContactNotFound => FfiError::ContactNotFound,
            Error::NeedsRehandshake => FfiError::SessionExpired,
            Error::MerkleMismatch => FfiError::FileCorrupted,
            Error::Locked => FfiError::Locked,
            Error::AeadFailure
            | Error::InvalidState(_)
            | Error::UndecryptableMessage
            | Error::PayloadTooLarge { .. }
            | Error::Rng
            | Error::CounterOverflow => FfiError::Internal,
        }
    }
}

impl std::fmt::Display for FfiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Debug::fmt(self, f)
    }
}

impl std::error::Error for FfiError {}

#[cfg(test)]
mod tests {
    use super::*;
    use viska_proto::Error;

    #[test]
    fn low_order_point_maps_to_forged_key() {
        // A distinção que mais importa nesta superfície: um QR forjado não
        // pode virar a mesma mensagem genérica que um QR mal lido pela
        // câmera (ver armadilha 4 do relatório da Fase 2).
        assert_eq!(FfiError::from(Error::LowOrderPoint), FfiError::ForgedKey);
    }

    #[test]
    fn qr_reading_variants_map_to_qr_malformed() {
        for err in [
            Error::BadLength {
                expected: 145,
                actual: 1,
            },
            Error::UnsupportedVersion(0xff),
            Error::Malformed("teste"),
            Error::InvalidPublicKey("teste"),
        ] {
            assert_eq!(FfiError::from(err), FfiError::QrMalformed);
        }
    }

    #[test]
    fn remaining_variants_map_to_expected_categories() {
        assert_eq!(FfiError::from(Error::BadSignature), FfiError::QrBadSignature);
        assert_eq!(FfiError::from(Error::SelfPairing), FfiError::SelfPairing);
        assert_eq!(FfiError::from(Error::Store), FfiError::StoreFailure);
        assert_eq!(
            FfiError::from(Error::ContactNotFound),
            FfiError::ContactNotFound
        );
        assert_eq!(
            FfiError::from(Error::NeedsRehandshake),
            FfiError::SessionExpired
        );
        assert_eq!(
            FfiError::from(Error::MerkleMismatch),
            FfiError::FileCorrupted
        );
        assert_eq!(FfiError::from(Error::Locked), FfiError::Locked);

        for err in [
            Error::AeadFailure,
            Error::InvalidState("teste"),
            Error::UndecryptableMessage,
            Error::PayloadTooLarge { max: 0 },
            Error::Rng,
            Error::CounterOverflow,
        ] {
            assert_eq!(FfiError::from(err), FfiError::Internal);
        }
    }
}
