//! AEAD — ChaCha20-Poly1305 e XChaCha20-Poly1305, §1 e §6 de `docs/protocol.md`.
//!
//! Duas cifras, dois esquemas de nonce, cada um casado com seu caso de uso:
//!
//! - **ChaCha20-Poly1305** (nonce de 12 B) cifra as mensagens do ratchet. O
//!   nonce é determinístico — `0x00000000 ‖ 0x00000000 ‖ counter_be` — porque
//!   a chave de mensagem `MK` é de uso único (§5.3): não existe reuso de par
//!   (chave, nonce), então um nonce previsível não compromete nada.
//! - **XChaCha20-Poly1305** (nonce de 24 B) cifra símbolos de arquivo e o
//!   staging em repouso (§7.5). Transferências retomáveis não têm um
//!   contador confiável — blocos chegam fora de ordem, são reenviados,
//!   retomados depois de dias — então o nonce é sorteado e viaja junto com o
//!   ciphertext; 192 bits tornam a chance de colisão desprezível mesmo depois
//!   de bilhões de símbolos.
//!
//! Qualquer falha — tag adulterada, AAD trocado, chave errada, contador
//! errado, buffer curto demais — vira `Error::AeadFailure` sem distinção.
//! Isso já é o desenho da crate `aead`: o tipo de erro dela é uma struct
//! vazia, para não abrir um oráculo de padding/formato.

use crate::crypto::kdf::Key;
use crate::{Error, Result};
use chacha20poly1305::{
    AeadInOut, ChaCha20Poly1305, Key as CipherKey, KeyInit, Nonce, XChaCha20Poly1305, XNonce,
};

/// Tamanho da tag de autenticação Poly1305, comum às duas cifras.
pub const TAG_LEN: usize = 16;
/// Tamanho do nonce do ChaCha20-Poly1305 (mensagens do ratchet).
pub const NONCE_LEN: usize = 12;
/// Tamanho do nonce do XChaCha20-Poly1305 (arquivos e staging).
pub const XNONCE_LEN: usize = 24;

/// Reinterpreta a chave como o tipo da crate subjacente, sem copiar: ambos são
/// newtypes sobre `[u8; 32]`, então a conversão de referência é só um cast.
fn cipher_key(key: &Key) -> &CipherKey {
    key.as_bytes().into()
}

/// Nonce determinístico do ratchet: zeros ‖ contador big-endian (§6).
///
/// Não há material secreto aqui — o contador já viaja em claro no envelope,
/// é o próprio receptor quem precisa dele para derivar este nonce.
fn nonce_from_counter(counter: u32) -> Nonce {
    let mut bytes = [0u8; NONCE_LEN];
    bytes[NONCE_LEN - 4..].copy_from_slice(&counter.to_be_bytes());
    Nonce::from(bytes)
}

/// Cifra `buffer` em-lugar com ChaCha20-Poly1305, anexando a tag ao final.
///
/// `counter` é o `Ns`/`Nr` da cadeia do ratchet no momento desta mensagem.
/// Repetir um contador com a mesma chave de cadeia quebraria a cifra, mas
/// isso nunca acontece em uso correto: `MK` é derivada uma vez por contador e
/// descartada logo em seguida (§5.3).
pub fn seal(key: &Key, counter: u32, aad: &[u8], buffer: &mut Vec<u8>) -> Result<()> {
    let cipher = ChaCha20Poly1305::new(cipher_key(key));
    let nonce = nonce_from_counter(counter);
    cipher
        .encrypt_in_place(&nonce, aad, buffer)
        .map_err(|_| Error::AeadFailure)
}

/// Abre `buffer` (`ciphertext ‖ tag`) em-lugar, deixando o plaintext original.
pub fn open(key: &Key, counter: u32, aad: &[u8], buffer: &mut Vec<u8>) -> Result<()> {
    let cipher = ChaCha20Poly1305::new(cipher_key(key));
    let nonce = nonce_from_counter(counter);
    cipher
        .decrypt_in_place(&nonce, aad, buffer)
        .map_err(|_| Error::AeadFailure)
}

/// Cifra `buffer` em-lugar com XChaCha20-Poly1305, sorteando um nonce novo.
///
/// O nonce sorteado é prefixado ao resultado: `buffer` passa a conter
/// `nonce ‖ ciphertext ‖ tag`. Como não há contador confiável em
/// transferências retomáveis (§7.5), o nonce precisa viajar com o dado para
/// o receptor conseguir abrir.
pub fn seal_xchacha(key: &Key, aad: &[u8], buffer: &mut Vec<u8>) -> Result<()> {
    let cipher = XChaCha20Poly1305::new(cipher_key(key));
    let nonce_bytes = crate::util::rng::array::<XNONCE_LEN>()?;
    let nonce = XNonce::from(nonce_bytes);

    cipher
        .encrypt_in_place(&nonce, aad, buffer)
        .map_err(|_| Error::AeadFailure)?;
    buffer.splice(0..0, nonce_bytes);
    Ok(())
}

/// Abre `buffer` (`nonce ‖ ciphertext ‖ tag`) em-lugar com XChaCha20-Poly1305.
pub fn open_xchacha(key: &Key, aad: &[u8], buffer: &mut Vec<u8>) -> Result<()> {
    if buffer.len() < XNONCE_LEN {
        // Curto demais para nem conter um nonce: mesmo veredito de uma falha
        // de autenticação, para não distinguir os dois casos por fora.
        return Err(Error::AeadFailure);
    }
    let nonce_bytes: [u8; XNONCE_LEN] = buffer[..XNONCE_LEN]
        .try_into()
        .expect("comprimento checado acima");
    buffer.drain(..XNONCE_LEN);

    let cipher = XChaCha20Poly1305::new(cipher_key(key));
    let nonce = XNonce::from(nonce_bytes);
    cipher
        .decrypt_in_place(&nonce, aad, buffer)
        .map_err(|_| Error::AeadFailure)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ida_e_volta_chacha() {
        let key = Key::from_bytes([7u8; 32]);
        let aad = b"cabecalho-do-envelope";
        let original = b"mensagem do ratchet".to_vec();

        let mut buffer = original.clone();
        seal(&key, 42, aad, &mut buffer).unwrap();
        assert_ne!(buffer, original);

        open(&key, 42, aad, &mut buffer).unwrap();
        assert_eq!(buffer, original);
    }

    #[test]
    fn rejeita_ciphertext_adulterado() {
        let key = Key::from_bytes([1u8; 32]);
        let mut buffer = b"dados do ratchet".to_vec();
        seal(&key, 0, b"", &mut buffer).unwrap();

        buffer[0] ^= 0xff;

        assert!(matches!(
            open(&key, 0, b"", &mut buffer),
            Err(Error::AeadFailure)
        ));
    }

    #[test]
    fn rejeita_tag_adulterada() {
        let key = Key::from_bytes([2u8; 32]);
        let mut buffer = b"dados do ratchet".to_vec();
        seal(&key, 0, b"", &mut buffer).unwrap();

        let ultimo = buffer.len() - 1;
        buffer[ultimo] ^= 0xff;

        assert!(matches!(
            open(&key, 0, b"", &mut buffer),
            Err(Error::AeadFailure)
        ));
    }

    #[test]
    fn rejeita_aad_adulterado() {
        let key = Key::from_bytes([3u8; 32]);
        let mut buffer = b"dados do ratchet".to_vec();
        seal(&key, 0, b"aad-original", &mut buffer).unwrap();

        assert!(matches!(
            open(&key, 0, b"aad-trocado", &mut buffer),
            Err(Error::AeadFailure)
        ));
    }

    #[test]
    fn rejeita_contador_diferente() {
        let key = Key::from_bytes([4u8; 32]);
        let mut buffer = b"dados do ratchet".to_vec();
        seal(&key, 5, b"", &mut buffer).unwrap();

        assert!(matches!(
            open(&key, 6, b"", &mut buffer),
            Err(Error::AeadFailure)
        ));
    }

    #[test]
    fn rejeita_chave_diferente() {
        let key_a = Key::from_bytes([5u8; 32]);
        let key_b = Key::from_bytes([6u8; 32]);
        let mut buffer = b"dados do ratchet".to_vec();
        seal(&key_a, 0, b"", &mut buffer).unwrap();

        assert!(matches!(
            open(&key_b, 0, b"", &mut buffer),
            Err(Error::AeadFailure)
        ));
    }

    #[test]
    fn xchacha_ida_e_volta() {
        let key = Key::from_bytes([8u8; 32]);
        let original = b"symbol raptorq".to_vec();

        let mut buffer = original.clone();
        seal_xchacha(&key, b"file-id", &mut buffer).unwrap();
        assert_ne!(buffer, original);

        open_xchacha(&key, b"file-id", &mut buffer).unwrap();
        assert_eq!(buffer, original);
    }

    #[test]
    fn xchacha_nonces_aleatorios_produzem_ciphertexts_distintos() {
        let key = Key::from_bytes([9u8; 32]);
        let plaintext = b"mesmo plaintext, duas cifragens".to_vec();

        let mut a = plaintext.clone();
        let mut b = plaintext.clone();
        seal_xchacha(&key, b"", &mut a).unwrap();
        seal_xchacha(&key, b"", &mut b).unwrap();

        // Os nonces sorteados garantem ciphertexts distintos mesmo para o
        // mesmo plaintext e a mesma chave — mas ambos abrem corretamente,
        // porque cada um carrega seu próprio nonce.
        assert_ne!(a, b);

        open_xchacha(&key, b"", &mut a).unwrap();
        open_xchacha(&key, b"", &mut b).unwrap();
        assert_eq!(a, plaintext);
        assert_eq!(b, plaintext);
    }

    #[test]
    fn xchacha_rejeita_buffer_curto_demais_para_ter_nonce() {
        let key = Key::from_bytes([10u8; 32]);
        let mut buffer = vec![0u8; XNONCE_LEN - 1];

        assert!(matches!(
            open_xchacha(&key, b"", &mut buffer),
            Err(Error::AeadFailure)
        ));
    }

    /// Vetor oficial do RFC 8439 §2.8.2 para AEAD_CHACHA20_POLY1305.
    ///
    /// Prova que o encaixe com a crate `chacha20poly1305` — posição da tag,
    /// tratamento do AAD, nonce completo de 12 B — está correto e não é só
    /// autoconsistente com o resto deste arquivo.
    #[test]
    fn vetor_rfc8439_secao_2_8_2() {
        let mut key_bytes = [0u8; 32];
        hex::decode_to_slice(
            "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f",
            &mut key_bytes,
        )
        .unwrap();

        let mut nonce_bytes = [0u8; NONCE_LEN];
        hex::decode_to_slice("070000004041424344454647", &mut nonce_bytes).unwrap();

        let aad = hex::decode("50515253c0c1c2c3c4c5c6c7").unwrap();
        let plaintext = b"Ladies and Gentlemen of the class of '99: \
If I could offer you only one tip for the future, sunscreen would be it."
            .to_vec();

        let expected_ciphertext = hex::decode(
            "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d\
63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b\
3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d\
7bc3ff4def08e4b7a9de576d26586cec64b6116",
        )
        .unwrap();
        let expected_tag = hex::decode("1ae10b594f09e26a7e902ecbd0600691").unwrap();

        let cipher = ChaCha20Poly1305::new(&CipherKey::from(key_bytes));
        let nonce = Nonce::from(nonce_bytes);

        let mut buffer = plaintext.clone();
        cipher.encrypt_in_place(&nonce, &aad, &mut buffer).unwrap();
        assert_eq!(buffer[..expected_ciphertext.len()], expected_ciphertext[..]);
        assert_eq!(buffer[expected_ciphertext.len()..], expected_tag[..]);

        cipher.decrypt_in_place(&nonce, &aad, &mut buffer).unwrap();
        assert_eq!(buffer, plaintext);
    }
}
