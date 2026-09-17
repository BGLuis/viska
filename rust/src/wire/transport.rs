//! Buckets de padding por transporte — `docs/protocol.md` §6.3, D5.
//!
//! A propriedade que o protocolo quer é que um observador do fio veja no
//! máximo dois tamanhos possíveis de pacote, quaisquer que sejam o conteúdo e
//! o tipo real. O desenho original fixava um único par de buckets para todos
//! os transportes; D5 explica por que isso não sobrevive ao DataChannel
//! WebRTC (limite de mensagem negociado no SDP, tipicamente bem abaixo de
//! 64 KB, e uma mensagem grande bloqueia o stream SCTP inteiro enquanto é
//! remontada). Cada transporte ganha o próprio par, preservando a mesma
//! propriedade de indistinguibilidade dentro do seu próprio tráfego.

use crate::{Error, Result};

/// Transporte por onde um envelope vai trafegar.
///
/// Isto não é o transporte físico (WebRTC vs. TCP) por si só — é a escolha de
/// qual conjunto de buckets de padding se aplica, porque essa é a única
/// diferença que este módulo precisa enxergar.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    /// DataChannel WebRTC, usado na conexão remota via NAT traversal.
    DataChannel,
    /// Socket TCP na rede local, usado quando os dois aparelhos estão na mesma LAN.
    LocalSocket,
}

impl Transport {
    /// Os dois tamanhos de plaintext (antes do envelope) permitidos neste
    /// transporte, em ordem crescente.
    pub const fn buckets(self) -> [usize; 2] {
        match self {
            Transport::DataChannel => [1024, 16384],
            Transport::LocalSocket => [1024, 65536],
        }
    }

    /// O maior bucket deste transporte — o limite de tamanho de plaintext.
    pub const fn max_bucket(self) -> usize {
        self.buckets()[1]
    }

    /// Menor bucket que acomoda `len` bytes de plaintext sem padding, ou
    /// `Error::PayloadTooLarge` se `len` estourar até o maior bucket.
    pub(crate) fn bucket_for(self, len: usize) -> Result<usize> {
        self.buckets()
            .into_iter()
            .find(|&bucket| len <= bucket)
            .ok_or(Error::PayloadTooLarge {
                max: self.max_bucket(),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bucket_for_escolhe_o_menor_bucket_suficiente() {
        assert_eq!(Transport::DataChannel.bucket_for(1).unwrap(), 1024);
        assert_eq!(Transport::DataChannel.bucket_for(1024).unwrap(), 1024);
        assert_eq!(Transport::DataChannel.bucket_for(1025).unwrap(), 16384);
        assert_eq!(Transport::DataChannel.bucket_for(16384).unwrap(), 16384);
    }

    #[test]
    fn bucket_for_rejeita_alem_do_maior_bucket() {
        assert!(matches!(
            Transport::DataChannel.bucket_for(16385),
            Err(Error::PayloadTooLarge { max: 16384 })
        ));
        assert!(matches!(
            Transport::LocalSocket.bucket_for(65537),
            Err(Error::PayloadTooLarge { max: 65536 })
        ));
    }
}
