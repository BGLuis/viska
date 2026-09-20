//! Contêiner Ogg-Opus mínimo, sem metadados de aparelho — `docs/protocol.md`
//! §6.6, D16.
//!
//! `record` grava através de `MediaRecorder`/`AVAudioRecorder`, que
//! acrescentam metadados por conta própria (D2.2 do relatório da Fase 5):
//! `ENCODER`, `creation_time`, identificador de aparelho, tipicamente dentro
//! do pacote `OpusTags` de um contêiner Ogg-Opus (RFC 7845 §5). A defesa
//! aqui é **subtração, não checagem**: [`strip_container`] desmonta o Ogg e
//! extrai só o essencial de `OpusHead` (canais, taxa de amostragem, pre-
//! skip) e os pacotes de áudio crus — `OpusTags` inteiro é descartado, nunca
//! copiado para [`RawOpusStream`]. Não há filtro de campo a campo a
//! esquecer: o campo que carregaria o metadado simplesmente não existe do
//! lado de cá.
//!
//! [`RawOpusStream::encode`]/[`RawOpusStream::decode`] são o formato interno
//! (não Ogg) que de fato vira o "arquivo" alimentado ao pipeline da Fase 4
//! (`file::transfer`) — grande-endian, no padrão do resto do crate.
//!
//! ## Reprodução: WAV, não Ogg — D18
//!
//! [`decode_to_wav`] é o que a fronteira FFI usa para reprodução
//! (`Core::decode_audio_to_wav`): decodifica os pacotes Opus para PCM
//! (`libopus` via a crate `audiopus`) e embrulha num WAV de 44 bytes de
//! cabeçalho. Não é Ogg-Opus remontado — descoberto ao integrar com
//! `just_audio`: `AVPlayer` (iOS) não sabe demuxar Ogg de jeito nenhum, com
//! ou sem suporte a Opus, e suporte a Opus em MP4 é inconsistente antes do
//! iOS 17. Decodificar para PCM/WAV elimina a ambiguidade de contêiner nas
//! duas plataformas ao custo de uma dependência nativa nova
//! (`audiopus`/`libopus`, licença BSD) — decisão registrada em D18.
//! [`rebuild_container`] (Ogg) continua existindo só como utilidade interna
//! de teste, para forjar fixtures de Ogg-Opus que exercitam
//! [`strip_container`]; nenhum código de produção a chama mais.
//!
//! Todo offset vindo de bytes externos usa `.get()`/`checked_add`, nunca
//! indexação direta, no padrão de `wire::plaintext::decode` — tanto
//! `strip_container` (Ogg de um par pareado, mas nunca confiável no formato)
//! quanto `RawOpusStream::decode` (nosso próprio formato, mas ainda
//! conteúdo de arquivo potencialmente adversarial, como qualquer outro).
//!
//! Uma particularidade deste módulo: os campos de `OpusHead`/`OpusTags` são
//! **little-endian** (RFC 7845), ao contrário de todo o resto do protocolo
//! Viska (big-endian) — imposto pelo formato externo, não uma escolha deste
//! código. Só [`strip_container`]/[`rebuild_container`]/[`write_page`] usam
//! little-endian; [`RawOpusStream::encode`]/[`decode`] (formato interno)
//! usam big-endian, como o resto do crate.

use crate::{Error, Result};

/// Magic do pacote de cabeçalho Opus (RFC 7845 §5.1).
const OPUS_HEAD_MAGIC: [u8; 8] = *b"OpusHead";
/// Magic do pacote de comentários Opus (RFC 7845 §5.2) — nunca copiado para
/// [`RawOpusStream`], só validado e descartado em [`strip_container`].
const OPUS_TAGS_MAGIC: [u8; 8] = *b"OpusTags";

const OGG_CAPTURE_PATTERN: [u8; 4] = *b"OggS";
/// `capture_pattern(4) ‖ version(1) ‖ header_type(1) ‖ granule(8) ‖
/// serial(4) ‖ sequence(4) ‖ crc(4) ‖ page_segments(1)` — RFC 3533 §6.
const OGG_HEADER_LEN: usize = 27;
const OGG_HEADER_TYPE_AT: usize = 5;
const OGG_PAGE_SEGMENTS_AT: usize = 26;

const HEADER_TYPE_CONTINUED: u8 = 0x01;
const HEADER_TYPE_BOS: u8 = 0x02;
const HEADER_TYPE_EOS: u8 = 0x04;

/// Um fluxo Opus livre de contêiner: só o essencial de `OpusHead` e a
/// sequência de pacotes de áudio crus. `OpusTags` nunca chega aqui.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawOpusStream {
    pub channels: u8,
    pub sample_rate: u32,
    pub pre_skip: u16,
    pub packets: Vec<Vec<u8>>,
}

const ENCODED_CHANNELS_AT: usize = 0;
const ENCODED_SAMPLE_RATE_AT: usize = ENCODED_CHANNELS_AT + 1;
const ENCODED_PRE_SKIP_AT: usize = ENCODED_SAMPLE_RATE_AT + 4;
const ENCODED_PACKET_COUNT_AT: usize = ENCODED_PRE_SKIP_AT + 2;
const ENCODED_PACKETS_AT: usize = ENCODED_PACKET_COUNT_AT + 4;

impl RawOpusStream {
    /// Formato interno (não Ogg, big-endian) — o que vira o "arquivo"
    /// alimentado ao pipeline da Fase 4.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(ENCODED_PACKETS_AT + self.packets.len() * 4);
        out.push(self.channels);
        out.extend_from_slice(&self.sample_rate.to_be_bytes());
        out.extend_from_slice(&self.pre_skip.to_be_bytes());
        out.extend_from_slice(&(self.packets.len() as u32).to_be_bytes());
        for packet in &self.packets {
            out.extend_from_slice(&(packet.len() as u32).to_be_bytes());
            out.extend_from_slice(packet);
        }
        out
    }

    /// `bytes` já passou pela verificação de raiz Merkle do pipeline de
    /// arquivo antes de chegar aqui, mas o conteúdo em si é tão
    /// potencialmente adversarial quanto o de qualquer arquivo recebido —
    /// por isso as mesmas checagens de `.get()`/`checked_add`.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let channels = *bytes
            .get(ENCODED_CHANNELS_AT)
            .ok_or(Error::Malformed("stream de áudio interno curto demais para channels"))?;
        let sample_rate = crate::util::encoding::read_u32(
            bytes
                .get(ENCODED_SAMPLE_RATE_AT..ENCODED_PRE_SKIP_AT)
                .ok_or(Error::Malformed(
                    "stream de áudio interno curto demais para sample_rate",
                ))?,
        )
        .expect("fatia de 4 bytes já garantida acima");
        let pre_skip = crate::util::encoding::read_u16(
            bytes
                .get(ENCODED_PRE_SKIP_AT..ENCODED_PACKET_COUNT_AT)
                .ok_or(Error::Malformed(
                    "stream de áudio interno curto demais para pre_skip",
                ))?,
        )
        .expect("fatia de 2 bytes já garantida acima");
        let packet_count = crate::util::encoding::read_u32(
            bytes
                .get(ENCODED_PACKET_COUNT_AT..ENCODED_PACKETS_AT)
                .ok_or(Error::Malformed(
                    "stream de áudio interno curto demais para packet_count",
                ))?,
        )
        .expect("fatia de 4 bytes já garantida acima");

        let mut offset = ENCODED_PACKETS_AT;
        let mut packets = Vec::new();
        for _ in 0..packet_count {
            let len_end = offset
                .checked_add(4)
                .ok_or(Error::Malformed("overflow lendo tamanho de pacote"))?;
            let len = crate::util::encoding::read_u32(
                bytes
                    .get(offset..len_end)
                    .ok_or(Error::Malformed("stream de áudio interno truncado no tamanho de um pacote"))?,
            )
            .expect("fatia de 4 bytes já garantida acima") as usize;
            offset = len_end;

            let data_end = offset
                .checked_add(len)
                .ok_or(Error::Malformed("overflow lendo dado de pacote"))?;
            let data = bytes
                .get(offset..data_end)
                .ok_or(Error::Malformed("stream de áudio interno truncado no dado de um pacote"))?
                .to_vec();
            offset = data_end;
            packets.push(data);
        }

        Ok(Self {
            channels,
            sample_rate,
            pre_skip,
            packets,
        })
    }
}

/// Remonta os pacotes Ogg completos de `bytes`, atravessando páginas quando
/// um pacote é maior que 255 bytes (lacing value 255 = "continua").
fn read_ogg_packets(bytes: &[u8]) -> Result<Vec<Vec<u8>>> {
    let mut packets = Vec::new();
    let mut current = Vec::new();
    let mut have_pending = false;
    let mut offset = 0usize;
    let mut first_page = true;

    while offset < bytes.len() {
        let header_end = offset
            .checked_add(OGG_HEADER_LEN)
            .ok_or(Error::Malformed("overflow calculando fim do cabeçalho Ogg"))?;
        let header = bytes
            .get(offset..header_end)
            .ok_or(Error::Malformed("página Ogg truncada no cabeçalho"))?;

        if header.get(0..4) != Some(&OGG_CAPTURE_PATTERN[..]) {
            return Err(Error::Malformed("assinatura OggS ausente"));
        }
        let header_type = header[OGG_HEADER_TYPE_AT];
        let page_segments = header[OGG_PAGE_SEGMENTS_AT] as usize;
        offset = header_end;

        if first_page && header_type & HEADER_TYPE_BOS == 0 {
            return Err(Error::Malformed("primeira página Ogg não é BOS"));
        }
        if header_type & HEADER_TYPE_CONTINUED != 0 && !have_pending {
            return Err(Error::Malformed(
                "página Ogg marcada como continuação sem pacote pendente",
            ));
        }
        first_page = false;

        let table_end = offset
            .checked_add(page_segments)
            .ok_or(Error::Malformed("overflow calculando fim da tabela de segmentos"))?;
        let segment_table = bytes
            .get(offset..table_end)
            .ok_or(Error::Malformed("tabela de segmentos Ogg truncada"))?;
        offset = table_end;

        for &seg_len in segment_table {
            let seg_len = seg_len as usize;
            let seg_end = offset
                .checked_add(seg_len)
                .ok_or(Error::Malformed("overflow lendo segmento Ogg"))?;
            let data = bytes
                .get(offset..seg_end)
                .ok_or(Error::Malformed("dado de segmento Ogg truncado"))?;
            offset = seg_end;

            current.extend_from_slice(data);
            have_pending = true;
            if seg_len < 255 {
                packets.push(std::mem::take(&mut current));
                have_pending = false;
            }
        }
    }

    if have_pending {
        return Err(Error::Malformed("pacote Ogg inacabado no fim do fluxo"));
    }

    Ok(packets)
}

/// Desmonta um Ogg-Opus e extrai só o essencial — ver doc do módulo.
pub fn strip_container(bytes: &[u8]) -> Result<RawOpusStream> {
    let mut packets = read_ogg_packets(bytes)?.into_iter();

    let head = packets
        .next()
        .ok_or(Error::Malformed("fluxo Ogg sem pacote OpusHead"))?;
    let tags = packets
        .next()
        .ok_or(Error::Malformed("fluxo Ogg sem pacote OpusTags"))?;

    if head.get(0..8) != Some(&OPUS_HEAD_MAGIC[..]) {
        return Err(Error::Malformed("primeiro pacote não é OpusHead"));
    }
    // `tags` é só validado — o conteúdo nunca é lido nem copiado para
    // nenhum campo de `RawOpusStream`. É isto que faz o descarte ser
    // subtração, não filtro: não existe campo aqui que pudesse carregar
    // `ENCODER`/`creation_time`/identificador de aparelho.
    if tags.get(0..8) != Some(&OPUS_TAGS_MAGIC[..]) {
        return Err(Error::Malformed("segundo pacote não é OpusTags"));
    }

    let channels = *head
        .get(9)
        .ok_or(Error::Malformed("OpusHead curto demais para channels"))?;
    let pre_skip_bytes: [u8; 2] = head
        .get(10..12)
        .ok_or(Error::Malformed("OpusHead curto demais para pre_skip"))?
        .try_into()
        .expect("fatia de 2 bytes já garantida acima");
    let sample_rate_bytes: [u8; 4] = head
        .get(12..16)
        .ok_or(Error::Malformed("OpusHead curto demais para sample_rate"))?
        .try_into()
        .expect("fatia de 4 bytes já garantida acima");

    Ok(RawOpusStream {
        channels,
        sample_rate: u32::from_le_bytes(sample_rate_bytes),
        pre_skip: u16::from_le_bytes(pre_skip_bytes),
        packets: packets.collect(),
    })
}

/// CRC-32 do Ogg (RFC 3533 apêndice A) — polinômio 0x04c11db7, sem reflexão,
/// diferente do CRC-32 comum (`zlib`/`png`). Só usado para produzir um Ogg
/// que tocadores de verdade aceitem; não é primitiva de segurança.
fn ogg_crc32(data: &[u8]) -> u32 {
    fn table_entry(i: u32) -> u32 {
        let mut r = i << 24;
        for _ in 0..8 {
            r = if r & 0x8000_0000 != 0 {
                (r << 1) ^ 0x04c1_1db7
            } else {
                r << 1
            };
        }
        r
    }

    let mut crc = 0u32;
    for &byte in data {
        crc = (crc << 8) ^ table_entry(((crc >> 24) ^ byte as u32) & 0xff);
    }
    crc
}

fn write_page(out: &mut Vec<u8>, header_type: u8, granule_position: i64, serial: u32, sequence: u32, packet: &[u8]) {
    let mut segment_table = Vec::new();
    let mut remaining = packet.len();
    while remaining >= 255 {
        segment_table.push(255u8);
        remaining -= 255;
    }
    segment_table.push(remaining as u8);

    let page_start = out.len();
    out.extend_from_slice(&OGG_CAPTURE_PATTERN);
    out.push(0); // version
    out.push(header_type);
    out.extend_from_slice(&granule_position.to_le_bytes());
    out.extend_from_slice(&serial.to_le_bytes());
    out.extend_from_slice(&sequence.to_le_bytes());
    let crc_at = out.len();
    out.extend_from_slice(&[0u8; 4]);
    out.push(segment_table.len() as u8);
    out.extend_from_slice(&segment_table);
    out.extend_from_slice(packet);

    let crc = ogg_crc32(&out[page_start..]);
    out[crc_at..crc_at + 4].copy_from_slice(&crc.to_le_bytes());
}

/// Remonta um Ogg-Opus mínimo, tocável, inteiramente em memória — nunca
/// gravado em disco por este código. `OpusTags` sintético: vendor fixo
/// (`"viska"`), zero comentários — nenhuma informação do gravador ou
/// aparelho originais sobrevive à viagem de ida (`strip_container`) e volta.
pub fn rebuild_container(stream: &RawOpusStream) -> Vec<u8> {
    // Serial fixo e arbitrário: não identifica aparelho nem sessão de
    // gravação, só precisa ser estável dentro deste único fluxo remontado.
    const SERIAL: u32 = 0x5649_534b;

    let mut out = Vec::new();
    let mut sequence = 0u32;

    let mut head = Vec::with_capacity(19);
    head.extend_from_slice(&OPUS_HEAD_MAGIC);
    head.push(1); // version
    head.push(stream.channels);
    head.extend_from_slice(&stream.pre_skip.to_le_bytes());
    head.extend_from_slice(&stream.sample_rate.to_le_bytes());
    head.extend_from_slice(&0i16.to_le_bytes()); // output gain
    head.push(0); // channel mapping family 0 (estéreo/mono padrão)
    write_page(&mut out, HEADER_TYPE_BOS, 0, SERIAL, sequence, &head);
    sequence += 1;

    let vendor = b"viska";
    let mut tags = Vec::new();
    tags.extend_from_slice(&OPUS_TAGS_MAGIC);
    tags.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    tags.extend_from_slice(vendor);
    tags.extend_from_slice(&0u32.to_le_bytes()); // zero comentários de usuário
    write_page(&mut out, 0, 0, SERIAL, sequence, &tags);
    sequence += 1;

    let mut granule: i64 = 0;
    let last_index = stream.packets.len().saturating_sub(1);
    for (index, packet) in stream.packets.iter().enumerate() {
        granule += 960; // aproximação de 20ms a 48kHz — só para tocar, não precisa ser exato.
        let header_type = if index == last_index && !stream.packets.is_empty() {
            HEADER_TYPE_EOS
        } else {
            0
        };
        write_page(&mut out, header_type, granule, SERIAL, sequence, packet);
        sequence += 1;
    }

    out
}

/// Maior quadro Opus possível — 120 ms a 48 kHz (RFC 6716 §2.1.4). Buffer de
/// saída do decodificador dimensionado para o pior caso, por quadro.
const MAX_FRAME_SAMPLES_PER_CHANNEL: usize = 5760;

fn to_audiopus_channels(channels: u8) -> Result<audiopus::Channels> {
    match channels {
        1 => Ok(audiopus::Channels::Mono),
        2 => Ok(audiopus::Channels::Stereo),
        _ => Err(Error::Malformed(
            "RawOpusStream.channels não suportado pelo decodificador (só mono ou estéreo)",
        )),
    }
}

fn to_audiopus_sample_rate(sample_rate: u32) -> Result<audiopus::SampleRate> {
    match sample_rate {
        8000 => Ok(audiopus::SampleRate::Hz8000),
        12000 => Ok(audiopus::SampleRate::Hz12000),
        16000 => Ok(audiopus::SampleRate::Hz16000),
        24000 => Ok(audiopus::SampleRate::Hz24000),
        48000 => Ok(audiopus::SampleRate::Hz48000),
        _ => Err(Error::Malformed(
            "RawOpusStream.sample_rate não suportado pelo decodificador Opus",
        )),
    }
}

/// Decodifica todos os pacotes de `stream` para PCM 16 bits intercalado,
/// descartando as `pre_skip` primeiras amostras por canal (RFC 7845 §4.2) —
/// amostras de "aquecimento" do codificador, nunca áudio de verdade.
pub fn decode_to_pcm(stream: &RawOpusStream) -> Result<Vec<i16>> {
    let channels = to_audiopus_channels(stream.channels)?;
    let sample_rate = to_audiopus_sample_rate(stream.sample_rate)?;
    let mut decoder = audiopus::coder::Decoder::new(sample_rate, channels)
        .map_err(|_| Error::Malformed("falha iniciando o decodificador Opus"))?;

    let channel_count = stream.channels as usize;
    let mut pcm = Vec::new();
    let mut buffer = vec![0i16; MAX_FRAME_SAMPLES_PER_CHANNEL * channel_count];
    for packet in &stream.packets {
        let samples_per_channel = decoder
            .decode(Some(packet.as_slice()), buffer.as_mut_slice(), false)
            .map_err(|_| Error::Malformed("pacote Opus não decodificou"))?;
        pcm.extend_from_slice(&buffer[..samples_per_channel * channel_count]);
    }

    let skip_samples = (stream.pre_skip as usize).saturating_mul(channel_count);
    if skip_samples < pcm.len() {
        pcm.drain(..skip_samples);
    } else {
        pcm.clear();
    }
    Ok(pcm)
}

const WAV_HEADER_LEN: u32 = 44;

/// Embrulha PCM 16 bits intercalado num WAV mínimo (cabeçalho de 44 bytes,
/// sem chunks extras) — formato sem ambiguidade de contêiner ou codec,
/// tocável em qualquer player de qualquer plataforma (D18).
pub fn build_wav(pcm: &[i16], sample_rate: u32, channels: u8) -> Vec<u8> {
    let channels = channels as u16;
    let bits_per_sample: u16 = 16;
    let byte_rate = sample_rate * channels as u32 * (bits_per_sample as u32 / 8);
    let block_align = channels * (bits_per_sample / 8);
    let data_len = (pcm.len() * 2) as u32;
    let riff_len = WAV_HEADER_LEN - 8 + data_len;

    let mut out = Vec::with_capacity(WAV_HEADER_LEN as usize + pcm.len() * 2);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&riff_len.to_le_bytes());
    out.extend_from_slice(b"WAVE");
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&channels.to_le_bytes());
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&block_align.to_le_bytes());
    out.extend_from_slice(&bits_per_sample.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for sample in pcm {
        out.extend_from_slice(&sample.to_le_bytes());
    }
    out
}

/// [`decode_to_pcm`] + [`build_wav`] — o que a fronteira FFI expõe como
/// `Core::decode_audio_to_wav` para reprodução (D18).
pub fn decode_to_wav(stream: &RawOpusStream) -> Result<Vec<u8>> {
    let pcm = decode_to_pcm(stream)?;
    Ok(build_wav(&pcm, stream.sample_rate, stream.channels))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream_de_teste() -> RawOpusStream {
        RawOpusStream {
            channels: 1,
            sample_rate: 48000,
            pre_skip: 312,
            packets: vec![
                vec![1, 2, 3, 4],
                vec![5; 300], // maior que 255 — exercita a continuação de lacing.
                vec![9, 9],
            ],
        }
    }

    /// Quadros Opus de verdade (não os bytes arbitrários de
    /// `stream_de_teste`, que só servem para exercitar o contêiner Ogg) —
    /// para testar o decodificador (D18) fim a fim, com o codec real.
    const FRAME_SAMPLES: usize = 960; // 20 ms a 48 kHz.

    fn stream_opus_real(pre_skip: u16, frames: usize) -> RawOpusStream {
        use audiopus::coder::Encoder;
        use audiopus::{Application, Channels, SampleRate};

        let encoder = Encoder::new(SampleRate::Hz48000, Channels::Mono, Application::Voip).unwrap();
        let mut packets = Vec::with_capacity(frames);
        for i in 0..frames {
            let pcm: Vec<i16> = (0..FRAME_SAMPLES)
                .map(|n| {
                    let t = (i * FRAME_SAMPLES + n) as f32;
                    ((t * 0.05).sin() * 4000.0) as i16
                })
                .collect();
            let mut out = vec![0u8; 4000];
            let len = encoder.encode(&pcm, &mut out).unwrap();
            out.truncate(len);
            packets.push(out);
        }
        RawOpusStream {
            channels: 1,
            sample_rate: 48000,
            pre_skip,
            packets,
        }
    }

    #[test]
    fn decode_to_pcm_produz_o_numero_certo_de_amostras_e_descarta_pre_skip() {
        let stream = stream_opus_real(FRAME_SAMPLES as u16, 5);
        let pcm = decode_to_pcm(&stream).unwrap();
        assert_eq!(pcm.len(), 5 * FRAME_SAMPLES - FRAME_SAMPLES);
    }

    #[test]
    fn decode_to_pcm_sem_pre_skip_mantem_todas_as_amostras() {
        let stream = stream_opus_real(0, 3);
        let pcm = decode_to_pcm(&stream).unwrap();
        assert_eq!(pcm.len(), 3 * FRAME_SAMPLES);
    }

    #[test]
    fn decode_to_pcm_rejeita_taxa_de_amostragem_nao_suportada() {
        let mut stream = stream_opus_real(0, 1);
        stream.sample_rate = 44100; // não é uma das cinco taxas que o Opus define.
        assert!(matches!(decode_to_pcm(&stream), Err(Error::Malformed(_))));
    }

    #[test]
    fn decode_to_pcm_rejeita_contagem_de_canais_nao_suportada() {
        let mut stream = stream_opus_real(0, 1);
        stream.channels = 3;
        assert!(matches!(decode_to_pcm(&stream), Err(Error::Malformed(_))));
    }

    #[test]
    fn decode_to_pcm_rejeita_pacote_vazio_sem_panico() {
        let mut stream = stream_opus_real(0, 1);
        stream.packets[0] = Vec::new();
        assert!(decode_to_pcm(&stream).is_err());
    }

    #[test]
    fn decode_to_wav_produz_cabecalho_riff_valido() {
        let stream = stream_opus_real(0, 2);
        let wav = decode_to_wav(&stream).unwrap();

        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(&wav[12..16], b"fmt ");
        assert_eq!(&wav[36..40], b"data");

        let declared_data_len = u32::from_le_bytes(wav[40..44].try_into().unwrap());
        assert_eq!(declared_data_len as usize, wav.len() - WAV_HEADER_LEN as usize);
    }

    #[test]
    fn build_wav_preenche_taxa_e_canais_no_cabecalho() {
        let pcm: Vec<i16> = vec![1, -1, 2, -2, 3, -3];
        let wav = build_wav(&pcm, 48000, 1);

        assert_eq!(wav.len(), WAV_HEADER_LEN as usize + pcm.len() * 2);
        let channels = u16::from_le_bytes(wav[22..24].try_into().unwrap());
        let sample_rate = u32::from_le_bytes(wav[24..28].try_into().unwrap());
        assert_eq!(channels, 1);
        assert_eq!(sample_rate, 48000);
    }

    #[test]
    fn build_wav_com_pcm_vazio_nao_panica() {
        let wav = build_wav(&[], 48000, 1);
        assert_eq!(wav.len(), WAV_HEADER_LEN as usize);
    }

    #[test]
    fn rebuild_e_strip_sao_inversos() {
        let original = stream_de_teste();
        let ogg = rebuild_container(&original);
        let recuperado = strip_container(&ogg).unwrap();
        assert_eq!(recuperado, original);
    }

    #[test]
    fn raw_opus_stream_encode_decode_ida_e_volta() {
        let original = stream_de_teste();
        let encoded = original.encode();
        let decoded = RawOpusStream::decode(&encoded).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn opustags_forjado_com_metadados_de_dispositivo_nao_sobrevive_ao_strip() {
        // Monta um Ogg-Opus válido à mão, com um OpusTags carregando
        // exatamente o tipo de metadado que a spec (§6.6, D16) proíbe.
        const SERIAL: u32 = 1;
        let mut ogg = Vec::new();

        let mut head = Vec::new();
        head.extend_from_slice(&OPUS_HEAD_MAGIC);
        head.push(1);
        head.push(1); // mono
        head.extend_from_slice(&0u16.to_le_bytes());
        head.extend_from_slice(&48000u32.to_le_bytes());
        head.extend_from_slice(&0i16.to_le_bytes());
        head.push(0);
        write_page(&mut ogg, HEADER_TYPE_BOS, 0, SERIAL, 0, &head);

        let comment = b"ENCODER=libopus 1.3.1;creation_time=2026-09-20T00:00:00Z;device=Pixel-9-Pro";
        let mut tags = Vec::new();
        tags.extend_from_slice(&OPUS_TAGS_MAGIC);
        tags.extend_from_slice(&5u32.to_le_bytes());
        tags.extend_from_slice(b"vazou");
        tags.extend_from_slice(&1u32.to_le_bytes());
        tags.extend_from_slice(&(comment.len() as u32).to_le_bytes());
        tags.extend_from_slice(comment);
        write_page(&mut ogg, 0, 0, SERIAL, 1, &tags);

        write_page(&mut ogg, HEADER_TYPE_EOS, 960, SERIAL, 2, &[1, 2, 3]);

        let stripped = strip_container(&ogg).unwrap();
        let serialized = stripped.encode();

        for proibido in [
            "ENCODER",
            "creation_time",
            "device",
            "Pixel-9-Pro",
            "vazou",
        ] {
            assert!(
                !serialized.windows(proibido.len()).any(|w| w == proibido.as_bytes()),
                "cadeia proibida {proibido:?} sobreviveu ao strip_container"
            );
        }
    }

    #[test]
    fn strip_container_rejeita_sem_assinatura_oggs() {
        assert!(matches!(
            strip_container(b"nao e um ogg"),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn strip_container_rejeita_primeira_pagina_sem_bos() {
        let mut ogg = Vec::new();
        write_page(&mut ogg, 0, 0, 1, 0, b"pacote qualquer");
        assert!(matches!(
            strip_container(&ogg),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn strip_container_rejeita_fluxo_sem_opustags() {
        let mut ogg = Vec::new();
        let mut head = Vec::new();
        head.extend_from_slice(&OPUS_HEAD_MAGIC);
        head.extend_from_slice(&[0u8; 11]);
        write_page(&mut ogg, HEADER_TYPE_BOS | HEADER_TYPE_EOS, 0, 1, 0, &head);

        assert!(matches!(
            strip_container(&ogg),
            Err(Error::Malformed(_))
        ));
    }

    proptest::proptest! {
        #[test]
        fn strip_container_nunca_entra_em_panico(bytes in proptest::collection::vec(proptest::prelude::any::<u8>(), 0..=4096)) {
            let _ = strip_container(&bytes);
        }

        #[test]
        fn raw_opus_stream_decode_nunca_entra_em_panico(bytes in proptest::collection::vec(proptest::prelude::any::<u8>(), 0..=4096)) {
            let _ = RawOpusStream::decode(&bytes);
        }
    }
}
