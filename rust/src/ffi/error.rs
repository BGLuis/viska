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
    fn ponto_de_ordem_baixa_mapeia_para_forged_key() {
        // A distinção que mais importa nesta superfície: um QR forjado não
        // pode virar a mesma mensagem genérica que um QR mal lido pela
        // câmera (ver armadilha 4 do relatório da Fase 2).
        assert_eq!(FfiError::from(Error::LowOrderPoint), FfiError::ForgedKey);
    }

    #[test]
    fn variantes_de_leitura_de_qr_mapeiam_para_qr_malformed() {
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
    fn demais_variantes_mapeiam_para_as_categorias_esperadas() {
        assert_eq!(FfiError::from(Error::BadSignature), FfiError::QrBadSignature);
        assert_eq!(FfiError::from(Error::SelfPairing), FfiError::SelfPairing);
        assert_eq!(FfiError::from(Error::Store), FfiError::StoreFailure);
        assert_eq!(
            FfiError::from(Error::ContactNotFound),
            FfiError::ContactNotFound
        );

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
