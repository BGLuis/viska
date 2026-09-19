//! Plaintext interno do envelope — `docs/protocol.md` §6.1.
//!
//! Este é o corpo que a camada de sessão cifra com `crypto::aead::seal` e
//! insere no envelope. Este módulo não cifra nada e não conhece chaves: só
//! serializa e desserializa bytes de forma determinística. Isso é o que torna
//! `encode`/`decode` testáveis exaustivamente com property tests sem precisar
//! de nenhum material de chave.
//!
//! `dh_pub` do `RatchetHeader` **não** está aqui — ele vive no cabeçalho em
//! claro do envelope (`wire::envelope`, D14), porque `crypto::ratchet`
//! precisa dele para derivar a própria chave de decifragem antes de poder
//! abrir este plaintext. Ver a documentação de `envelope.rs` para o porquê.
//!
//! Layout, deslocamentos fixos:
//!
//! ```text
//! offset  tam  campo
//! 0       1    packet_type
//! 1       4    pn            u32 be
//! 5       2    body_len      u16 be
//! 7       1    flags         bit0 = carrega KEM_ek, bit1 = carrega KEM_ct
//! 8       ..   kem_material  0, 1184, 1088 ou 2272 bytes conforme flags
//! ..      ..   body          body_len bytes
//! ..      ..   padding       bytes aleatórios CSPRNG até o bucket
//! ```

use crate::crypto::kem::{KemCiphertext, KemPublicKey, CIPHERTEXT_LEN, PUBLIC_KEY_LEN};
use crate::util::encoding;
use crate::wire::packet_type::PacketType;
use crate::wire::transport::Transport;
use crate::{Error, Result};

const PACKET_TYPE_AT: usize = 0;
const PN_AT: usize = PACKET_TYPE_AT + 1;
const BODY_LEN_AT: usize = PN_AT + 4;
const FLAGS_AT: usize = BODY_LEN_AT + 2;
/// Deslocamento onde começa o material KEM opcional — o cabeçalho fixo termina aqui.
const KEM_MATERIAL_AT: usize = FLAGS_AT + 1;

const _: () = assert!(KEM_MATERIAL_AT == 8);

const FLAG_KEM_EK: u8 = 0b0000_0001;
const FLAG_KEM_CT: u8 = 0b0000_0010;
/// Qualquer bit fora de bit0/bit1. A spec não define significado para eles —
/// silenciar bits desconhecidos abriria espaço para uma extensão futura do
/// formato ser interpretada de forma incompatível por implementações antigas.
const FLAG_RESERVED_MASK: u8 = !(FLAG_KEM_EK | FLAG_KEM_CT);

/// O maior cabeçalho fixo possível: os dois flags de KEM setados ao mesmo tempo.
///
/// Uma mensagem de re-KEM em andamento pode legitimamente carregar `KEM_ek` e
/// `KEM_ct` juntos (§5.4): o par que dispara o rekem manda `KEM_ek` novo, e a
/// contraparte, se já estiver no meio de outro re-KEM, pode responder com
/// `KEM_ct` na mesma mensagem que carrega seu próprio `KEM_ek`.
pub const MAX_HEADER_LEN: usize = KEM_MATERIAL_AT + PUBLIC_KEY_LEN + CIPHERTEXT_LEN;

/// Plaintext interno do envelope, antes de cifrar e depois de decifrar.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InnerPlaintext {
    pub packet_type: PacketType,
    /// Número de mensagens da cadeia de envio anterior (`PN` do ratchet).
    pub pn: u32,
    /// Novo `KEM_ek` do emissor, presente quando este dispara um re-KEM (§5.4).
    pub kem_ek: Option<KemPublicKey>,
    /// `KEM_ct` de resposta a um `KEM_ek` recebido anteriormente.
    pub kem_ct: Option<KemCiphertext>,
    pub body: Vec<u8>,
}

impl InnerPlaintext {
    /// Serializa e preenche com padding CSPRNG até o bucket de `transport`.
    ///
    /// Erra com `Error::PayloadTooLarge` se o cabeçalho mais o corpo não
    /// couberem nem no maior bucket do transporte.
    pub fn encode(&self, transport: Transport) -> Result<Vec<u8>> {
        let kem_ek_len = if self.kem_ek.is_some() {
            PUBLIC_KEY_LEN
        } else {
            0
        };
        let kem_ct_len = if self.kem_ct.is_some() {
            CIPHERTEXT_LEN
        } else {
            0
        };
        let header_len = KEM_MATERIAL_AT + kem_ek_len + kem_ct_len;
        let unpadded_len = header_len + self.body.len();

        let bucket = transport.bucket_for(unpadded_len)?;

        // `bucket_for` já garantiu que `unpadded_len` cabe no maior bucket do
        // transporte, e o maior bucket (65536) cabe em u16 folgado, então esta
        // conversão nunca falha de fato — mas é melhor expressar isso como uma
        // asserção explícita do que silenciar um `as u16` que trunca em silêncio.
        let body_len: u16 = self
            .body
            .len()
            .try_into()
            .expect("bucket_for já garantiu que o corpo cabe em u16");

        let mut out = vec![0u8; bucket];
        out[PACKET_TYPE_AT] = self.packet_type.to_u8();
        out[PN_AT..BODY_LEN_AT].copy_from_slice(&self.pn.to_be_bytes());
        out[BODY_LEN_AT..FLAGS_AT].copy_from_slice(&body_len.to_be_bytes());

        let mut flags = 0u8;
        let mut offset = KEM_MATERIAL_AT;
        if let Some(ek) = &self.kem_ek {
            flags |= FLAG_KEM_EK;
            out[offset..offset + PUBLIC_KEY_LEN].copy_from_slice(ek.as_bytes());
            offset += PUBLIC_KEY_LEN;
        }
        if let Some(ct) = &self.kem_ct {
            flags |= FLAG_KEM_CT;
            out[offset..offset + CIPHERTEXT_LEN].copy_from_slice(ct.as_bytes());
            offset += CIPHERTEXT_LEN;
        }
        out[FLAGS_AT] = flags;

        out[offset..offset + self.body.len()].copy_from_slice(&self.body);
        offset += self.body.len();

        // Padding com CSPRNG, nunca zeros: bytes previsíveis dentro do
        // plaintext não quebram a cifra por si só, mas um padding sempre-zero
        // é uma marca que sobrevive a qualquer vazamento futuro de estrutura
        // do ciphertext, e o custo de sortear é irrelevante perto do resto do
        // trabalho de cifrar a mensagem.
        crate::util::rng::fill(&mut out[offset..])?;

        Ok(out)
    }

    /// Desserializa um plaintext já decifrado, descartando o padding.
    ///
    /// `bytes` vem de um adversário em potencial (é o resultado de abrir o
    /// AEAD, mas nada garante que o par do outro lado seja honesto ou que a
    /// versão dele do protocolo bata com esta). Toda extração de fatia aqui
    /// passa por `get`/`checked_add` — nunca por indexação direta — para que
    /// nenhuma entrada consiga provocar um panic por índice fora da faixa.
    pub fn decode(bytes: &[u8], transport: Transport) -> Result<Self> {
        if !transport.buckets().contains(&bytes.len()) {
            return Err(Error::Malformed(
                "comprimento do plaintext não é um bucket válido deste transporte",
            ));
        }
        // Os dois buckets de qualquer transporte (mínimo 1024) são maiores que
        // o cabeçalho fixo (40 bytes), então as fatias de tamanho fixo abaixo
        // nunca estouram — mas isso já foi validado acima, não presumido.

        let packet_type = PacketType::from_u8(bytes[PACKET_TYPE_AT])?;
        let pn = encoding::read_u32(&bytes[PN_AT..BODY_LEN_AT])
            .expect("comprimento do bucket garante 4 bytes disponíveis");
        let body_len = encoding::read_u16(&bytes[BODY_LEN_AT..FLAGS_AT])
            .expect("comprimento do bucket garante 2 bytes disponíveis")
            as usize;
        let flags = bytes[FLAGS_AT];

        if flags & FLAG_RESERVED_MASK != 0 {
            return Err(Error::Malformed(
                "bits reservados de flags setados no plaintext interno",
            ));
        }

        let mut offset = KEM_MATERIAL_AT;

        let kem_ek = if flags & FLAG_KEM_EK != 0 {
            let end = offset
                .checked_add(PUBLIC_KEY_LEN)
                .ok_or(Error::Malformed("overflow calculando o fim do KEM_ek"))?;
            let slice = bytes
                .get(offset..end)
                .ok_or(Error::Malformed("KEM_ek declarado, mas estoura o buffer"))?;
            offset = end;
            Some(KemPublicKey::from_slice(slice)?)
        } else {
            None
        };

        let kem_ct = if flags & FLAG_KEM_CT != 0 {
            let end = offset
                .checked_add(CIPHERTEXT_LEN)
                .ok_or(Error::Malformed("overflow calculando o fim do KEM_ct"))?;
            let slice = bytes
                .get(offset..end)
                .ok_or(Error::Malformed("KEM_ct declarado, mas estoura o buffer"))?;
            offset = end;
            Some(KemCiphertext::from_slice(slice)?)
        } else {
            None
        };

        let body_end = offset
            .checked_add(body_len)
            .ok_or(Error::Malformed("overflow calculando o fim do corpo"))?;
        let body = bytes
            .get(offset..body_end)
            .ok_or(Error::Malformed("body_len maior que o buffer disponível"))?
            .to_vec();

        Ok(Self {
            packet_type,
            pn,
            kem_ek,
            kem_ct,
            body,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn kem_ek_de_teste() -> KemPublicKey {
        KemPublicKey::from_slice(&[0xABu8; PUBLIC_KEY_LEN]).unwrap()
    }

    fn kem_ct_de_teste() -> KemCiphertext {
        KemCiphertext::from_slice(&[0xCDu8; CIPHERTEXT_LEN]).unwrap()
    }

    fn amostra(
        packet_type: PacketType,
        has_ek: bool,
        has_ct: bool,
        body: Vec<u8>,
    ) -> InnerPlaintext {
        InnerPlaintext {
            packet_type,
            pn: 7,
            kem_ek: has_ek.then(kem_ek_de_teste),
            kem_ct: has_ct.then(kem_ct_de_teste),
            body,
        }
    }

    #[test]
    fn ida_e_volta_para_cada_tipo_de_pacote_nos_dois_transportes() {
        for &tipo in &PacketType::ALL {
            for transport in [Transport::DataChannel, Transport::LocalSocket] {
                for (has_ek, has_ct) in [(false, false), (true, false), (false, true), (true, true)]
                {
                    let original = amostra(tipo, has_ek, has_ct, b"corpo de teste".to_vec());
                    let encoded = original.encode(transport).unwrap();

                    assert!(transport.buckets().contains(&encoded.len()));

                    let decoded = InnerPlaintext::decode(&encoded, transport).unwrap();
                    assert_eq!(decoded, original);
                }
            }
        }
    }

    #[test]
    fn corpo_grande_demais_e_rejeitado_com_payload_too_large() {
        let grande = vec![0u8; Transport::DataChannel.max_bucket() + 1];
        let pacote = amostra(PacketType::MsgText, false, false, grande);

        assert!(matches!(
            pacote.encode(Transport::DataChannel),
            Err(Error::PayloadTooLarge { max: 16384 })
        ));

        let grande_lan = vec![0u8; Transport::LocalSocket.max_bucket() + 1];
        let pacote_lan = amostra(PacketType::MsgText, false, false, grande_lan);
        assert!(matches!(
            pacote_lan.encode(Transport::LocalSocket),
            Err(Error::PayloadTooLarge { max: 65536 })
        ));
    }

    #[test]
    fn duas_codificacoes_tem_padding_diferente_mas_decodificam_igual() {
        let pacote = amostra(PacketType::MsgTyping, false, false, b"oi".to_vec());

        let a = pacote.encode(Transport::DataChannel).unwrap();
        let b = pacote.encode(Transport::DataChannel).unwrap();

        // Corpo minúsculo em um bucket de 1024: sobra bastante padding para
        // que uma colisão por acaso seja praticamente impossível.
        assert_ne!(a, b, "padding deveria variar entre duas codificações");

        assert_eq!(
            InnerPlaintext::decode(&a, Transport::DataChannel).unwrap(),
            pacote
        );
        assert_eq!(
            InnerPlaintext::decode(&b, Transport::DataChannel).unwrap(),
            pacote
        );
    }

    #[test]
    fn rejeita_bits_reservados_de_flags() {
        let pacote = amostra(PacketType::MsgText, false, false, b"x".to_vec());
        let mut encoded = pacote.encode(Transport::DataChannel).unwrap();
        encoded[FLAGS_AT] |= 0b0000_0100;

        assert!(matches!(
            InnerPlaintext::decode(&encoded, Transport::DataChannel),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn rejeita_body_len_maior_que_o_buffer_sem_panico() {
        let pacote = amostra(PacketType::MsgText, false, false, b"pequeno".to_vec());
        let mut encoded = pacote.encode(Transport::DataChannel).unwrap();
        encoded[BODY_LEN_AT..FLAGS_AT].copy_from_slice(&u16::MAX.to_be_bytes());

        assert!(matches!(
            InnerPlaintext::decode(&encoded, Transport::DataChannel),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn rejeita_comprimento_que_nao_e_bucket() {
        let pacote = amostra(PacketType::MsgText, false, false, b"x".to_vec());
        let mut encoded = pacote.encode(Transport::DataChannel).unwrap();
        encoded.push(0);

        assert!(matches!(
            InnerPlaintext::decode(&encoded, Transport::DataChannel),
            Err(Error::Malformed(_))
        ));
    }

    /// Estratégia de `PacketType` a partir do índice em `ALL`, para uso nos
    /// property tests abaixo.
    fn estrategia_packet_type() -> impl Strategy<Value = PacketType> {
        (0..PacketType::ALL.len()).prop_map(|i| PacketType::ALL[i])
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(128))]

        /// Para qualquer corpo e qualquer combinação de flags que caiba no
        /// transporte, `decode(encode(x)) == x` — e o resultado codificado tem
        /// exatamente um tamanho de bucket do DataChannel.
        #[test]
        fn ida_e_volta_property_datachannel(
            tipo in estrategia_packet_type(),
            pn in any::<u32>(),
            has_ek in any::<bool>(),
            has_ct in any::<bool>(),
            body in proptest::collection::vec(
                any::<u8>(),
                0..=(Transport::DataChannel.max_bucket() - MAX_HEADER_LEN),
            ),
        ) {
            let original = InnerPlaintext {
                packet_type: tipo,
                pn,
                kem_ek: has_ek.then(kem_ek_de_teste),
                kem_ct: has_ct.then(kem_ct_de_teste),
                body,
            };

            let encoded = original.encode(Transport::DataChannel).unwrap();
            prop_assert!(Transport::DataChannel.buckets().contains(&encoded.len()));

            let decoded = InnerPlaintext::decode(&encoded, Transport::DataChannel).unwrap();
            prop_assert_eq!(decoded, original);
        }

        /// Mesma propriedade, para o socket TCP local (bucket bem maior).
        #[test]
        fn ida_e_volta_property_local_socket(
            tipo in estrategia_packet_type(),
            pn in any::<u32>(),
            has_ek in any::<bool>(),
            has_ct in any::<bool>(),
            body in proptest::collection::vec(
                any::<u8>(),
                0..=(Transport::LocalSocket.max_bucket() - MAX_HEADER_LEN),
            ),
        ) {
            let original = InnerPlaintext {
                packet_type: tipo,
                pn,
                kem_ek: has_ek.then(kem_ek_de_teste),
                kem_ct: has_ct.then(kem_ct_de_teste),
                body,
            };

            let encoded = original.encode(Transport::LocalSocket).unwrap();
            prop_assert!(Transport::LocalSocket.buckets().contains(&encoded.len()));

            let decoded = InnerPlaintext::decode(&encoded, Transport::LocalSocket).unwrap();
            prop_assert_eq!(decoded, original);
        }

        /// O teste mais importante do módulo: `decode` processa bytes vindos
        /// de um adversário (o AEAD já abriu, mas nada garante que a outra
        /// ponta seja honesta ou fale a mesma versão do protocolo). Para
        /// qualquer entrada, o resultado é sempre `Ok` ou `Err` — nunca panic.
        #[test]
        fn decode_nunca_entra_em_panico(
            bytes in proptest::collection::vec(any::<u8>(), 0..=70_000),
            transport_e_data_channel in any::<bool>(),
        ) {
            let transport = if transport_e_data_channel {
                Transport::DataChannel
            } else {
                Transport::LocalSocket
            };
            let _ = InnerPlaintext::decode(&bytes, transport);
        }
    }
}
