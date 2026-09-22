//! Enquadramento de transporte para o socket TCP local — `docs/protocol.md`
//! §6.4, D4 (Fase 6, F1).
//!
//! Só serialização, sem chave nem estado: uma travessia fina de
//! `wire::framing`, para que o `LanTransport` do lado Dart não precise
//! reimplementar o prefixo de comprimento nem a checagem de tamanho máximo
//! antes de alocar — única fonte de verdade continua em `viska_proto`.

use crate::ffi::error::FfiError;

/// Prefixa `envelope` com seu comprimento em big-endian, para envio pelo
/// socket TCP local.
pub fn frame_for_local_socket(envelope: Vec<u8>) -> Result<Vec<u8>, FfiError> {
    // Mapeamento explícito, não o `From<viska_proto::Error>` genérico de
    // `FfiError`: aquele mapeia `Error::Malformed` para `QrMalformed`, que só
    // faz sentido no contexto de leitura de QR (`ffi/error.rs`). Um
    // enquadramento de socket TCP que falha é um problema de transporte, sem
    // relação com QR nenhum — cabe em `Internal`, mesma categoria de
    // qualquer outra falha interna sem mensagem própria para a UI.
    viska_proto::wire::framing::frame(&envelope).map_err(|_| FfiError::Internal)
}

/// Extrai o próximo quadro completo de `buffer`, se já tiver chegado por
/// inteiro, devolvendo o quadro extraído e o restante do buffer.
///
/// `extracted: None` significa "ainda não chegaram bytes suficientes" — quem
/// chama só precisa acumular mais bytes lidos do socket em `remaining` e
/// tentar de novo. Erro (comprimento anunciado maior que o cabível) é
/// tratado como `FfiError::Internal`: um peer que anuncia isso está sendo
/// hostil ou está corrompido, e a única resposta correta (armadilha da Fase
/// 6, §4) é derrubar a conexão — não tentar de novo sobre o mesmo buffer.
pub fn extract_frame_from_local_socket_buffer(
    buffer: Vec<u8>,
) -> Result<(Option<Vec<u8>>, Vec<u8>), FfiError> {
    let mut buffer = buffer;
    // Mesmo raciocínio de `frame_for_local_socket`: mapeamento explícito
    // para `Internal`, não o `From` genérico pensado para QR.
    let extracted =
        viska_proto::wire::framing::extract_frame(&mut buffer).map_err(|_| FfiError::Internal)?;
    Ok((extracted, buffer))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn framed_frame_is_extracted_back_intact() {
        let envelope = b"envelope de teste".to_vec();
        let framed = frame_for_local_socket(envelope.clone()).unwrap();

        let (extracted, remaining) =
            extract_frame_from_local_socket_buffer(framed).unwrap();

        assert_eq!(extracted, Some(envelope));
        assert!(remaining.is_empty());
    }

    #[test]
    fn partial_buffer_extracts_nothing_and_preserves_bytes() {
        let mut framed = frame_for_local_socket(b"abc".to_vec()).unwrap();
        framed.truncate(framed.len() - 1);
        let original = framed.clone();

        let (extracted, remaining) =
            extract_frame_from_local_socket_buffer(framed).unwrap();

        assert_eq!(extracted, None);
        assert_eq!(remaining, original);
    }

    #[test]
    fn absurd_length_is_rejected() {
        let mut buffer = vec![0xff, 0xff, 0xff, 0xff];
        buffer.extend_from_slice(b"nao importa");

        assert_eq!(
            extract_frame_from_local_socket_buffer(buffer),
            Err(FfiError::Internal)
        );
    }
}
