//! Pareamento óptico — §3 da especificação.
//!
//! A raiz de confiança do Viska é física: os dois aparelhos ficam lado a lado e
//! cada um lê o QR Code do outro. Não existe autoridade certificadora, servidor
//! de cadastro nem diretório de chaves — e, por consequência, não existe um
//! ponto central que possa ser coagido a trocar uma chave por outra.
//!
//! O payload tem 145 bytes. A chave ML-KEM-768, com seus 1184 bytes, fica de
//! fora de propósito: um QR com mais de 1,2 KB vira uma matriz Versão 20+, que
//! falha com frequência em câmera de celular mediana e luz irregular. A chave
//! pós-quântica é trocada depois, no handshake, onde não há limite de tamanho.

use crate::crypto::dh::DhPublic;
use crate::crypto::identity::{
    LocalIdentity, PublicIdentity, DEVICE_ID_LEN, SIGNATURE_LEN, SIGNING_KEY_LEN,
};
use crate::crypto::kdf;
use crate::{Error, Result, PROTOCOL_VERSION};

/// Deslocamentos dos campos dentro do payload do QR.
const VERSION_AT: usize = 0;
const DEVICE_ID_AT: usize = 1;
const SIGNING_AT: usize = DEVICE_ID_AT + DEVICE_ID_LEN;
const DH_AT: usize = SIGNING_AT + SIGNING_KEY_LEN;
const SIGNATURE_AT: usize = DH_AT + crate::crypto::dh::KEY_LEN;

/// Bytes cobertos pela assinatura: tudo que vem antes dela.
const SIGNED_LEN: usize = SIGNATURE_AT;

/// Tamanho total do payload do QR Code.
pub const QR_PAYLOAD_LEN: usize = SIGNATURE_AT + SIGNATURE_LEN;

const _: () = assert!(QR_PAYLOAD_LEN == 145);

/// Serializa a identidade local no payload do QR Code.
pub fn encode_qr(identity: &LocalIdentity) -> [u8; QR_PAYLOAD_LEN] {
    let public = identity.public();
    let mut payload = [0u8; QR_PAYLOAD_LEN];

    payload[VERSION_AT] = PROTOCOL_VERSION;
    payload[DEVICE_ID_AT..SIGNING_AT].copy_from_slice(&public.device_id);
    payload[SIGNING_AT..DH_AT].copy_from_slice(&public.signing);
    payload[DH_AT..SIGNATURE_AT].copy_from_slice(public.dh.as_bytes());

    let digest = kdf::derive(kdf::context::QR_SIGNATURE, &payload[..SIGNED_LEN]);
    let signature = identity.sign(digest.as_bytes());
    payload[SIGNATURE_AT..].copy_from_slice(&signature);

    payload
}

/// Decodifica e valida um payload lido pela câmera.
///
/// `local` é a identidade deste aparelho, usada para detectar o caso em que o
/// usuário aponta a câmera para o próprio QR.
pub fn decode_qr(payload: &[u8], local: &PublicIdentity) -> Result<PublicIdentity> {
    if payload.len() != QR_PAYLOAD_LEN {
        return Err(Error::BadLength {
            expected: QR_PAYLOAD_LEN,
            actual: payload.len(),
        });
    }

    let version = payload[VERSION_AT];
    if version != PROTOCOL_VERSION {
        // Sem downgrade negociado: uma versão desconhecida para o fluxo aqui.
        // Negociar para baixo é uma vulnerabilidade, não uma funcionalidade.
        return Err(Error::UnsupportedVersion(version));
    }

    let mut device_id = [0u8; DEVICE_ID_LEN];
    device_id.copy_from_slice(&payload[DEVICE_ID_AT..SIGNING_AT]);

    let mut signing = [0u8; SIGNING_KEY_LEN];
    signing.copy_from_slice(&payload[SIGNING_AT..DH_AT]);

    let dh = DhPublic::from_slice(&payload[DH_AT..SIGNATURE_AT])?;

    let mut signature = [0u8; SIGNATURE_LEN];
    signature.copy_from_slice(&payload[SIGNATURE_AT..]);

    let candidate = PublicIdentity {
        device_id,
        signing,
        dh,
    };

    // A assinatura prova posse da chave privada e integridade dos bytes lidos.
    // Não é ela que impede man-in-the-middle — isso vem do canal óptico
    // presencial. Mas ela impede que um QR corrompido pela câmera ou adulterado
    // em uma foto encaminhada passe por válido.
    let digest = kdf::derive(kdf::context::QR_SIGNATURE, &payload[..SIGNED_LEN]);
    candidate.verify(digest.as_bytes(), &signature)?;

    // Apontar a câmera para o próprio QR não deve criar um contato consigo
    // mesmo: o resto do protocolo assume dois lados distintos.
    if candidate.signing == local.signing || candidate.dh == local.dh {
        return Err(Error::SelfPairing);
    }

    // Uma chave X25519 de ordem baixa no QR faria todo handshake futuro derivar
    // um segredo escolhido pelo atacante. Rejeitar aqui, no pareamento, custa
    // um DH descartável e fecha a porta de vez.
    let probe = crate::crypto::dh::DhSecret::generate()?;
    probe.agree(&candidate.dh)?;

    Ok(candidate)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> (LocalIdentity, LocalIdentity) {
        (
            LocalIdentity::generate().unwrap(),
            LocalIdentity::generate().unwrap(),
        )
    }

    #[test]
    fn payload_tem_145_bytes() {
        let (alice, _) = pair();
        assert_eq!(encode_qr(&alice).len(), 145);
    }

    #[test]
    fn scan_recupera_a_identidade_do_outro() {
        let (alice, bob) = pair();
        let scanned = decode_qr(&encode_qr(&alice), &bob.public()).unwrap();

        assert_eq!(scanned, alice.public());
    }

    #[test]
    fn rejeita_qualquer_bit_adulterado() {
        let (alice, bob) = pair();
        let original = encode_qr(&alice);

        // Vale para o payload inteiro, campo de assinatura incluído.
        for index in 0..QR_PAYLOAD_LEN {
            for bit in 0..8u8 {
                let mut tampered = original;
                tampered[index] ^= 1 << bit;
                if tampered == original {
                    continue;
                }
                assert!(
                    decode_qr(&tampered, &bob.public()).is_err(),
                    "byte {index} bit {bit} passou pela validação"
                );
            }
        }
    }

    #[test]
    fn rejeita_auto_pareamento() {
        let (alice, _) = pair();
        assert!(matches!(
            decode_qr(&encode_qr(&alice), &alice.public()),
            Err(Error::SelfPairing)
        ));
    }

    #[test]
    fn rejeita_tamanho_errado() {
        let (alice, bob) = pair();
        let payload = encode_qr(&alice);

        assert!(matches!(
            decode_qr(&payload[..144], &bob.public()),
            Err(Error::BadLength { .. })
        ));
    }

    #[test]
    fn rejeita_versao_desconhecida() {
        let (alice, bob) = pair();
        let mut payload = encode_qr(&alice);
        payload[VERSION_AT] = 0x02;

        assert!(matches!(
            decode_qr(&payload, &bob.public()),
            Err(Error::UnsupportedVersion(0x02))
        ));
    }

    #[test]
    fn rejeita_chave_x25519_de_ordem_baixa() {
        // Um QR forjado com chave DH de ordem baixa, reassinado para que a
        // assinatura confira: o único jeito de barrar é a checagem explícita.
        let (alice, bob) = pair();
        let mut payload = encode_qr(&alice);
        payload[DH_AT..SIGNATURE_AT].copy_from_slice(&[0u8; 32]);

        let digest = kdf::derive(kdf::context::QR_SIGNATURE, &payload[..SIGNED_LEN]);
        payload[SIGNATURE_AT..].copy_from_slice(&alice.sign(digest.as_bytes()));

        assert!(matches!(
            decode_qr(&payload, &bob.public()),
            Err(Error::LowOrderPoint)
        ));
    }
}
