//! Handshake — AKE híbrido deniável, §4 da especificação.
//!
//! Não existe nenhuma assinatura aqui, de propósito. A autenticação vem do
//! fato de que a `IK_dh` X25519 de cada lado já foi obtida presencialmente
//! pelo QR Code (§3): os dois DH cruzados com essa chave de longo prazo
//! (`DH1` e `DH2` abaixo) provam posse do segredo sem produzir nada que um
//! terceiro possa verificar sozinho. Se este handshake assinasse o
//! transcript, qualquer um dos dois lados poderia depois provar a um
//! terceiro "conversei com fulano" — e é exatamente essa prova que o
//! protocolo existe para não deixar existir (D1). Por construção, R
//! consegue forjar sozinho um transcript inteiro e plausível de uma conversa
//! com I: nenhuma mensagem daqui é evidência de nada.
//!
//! Estrutura PQXDH: três acordos X25519 (estilo X3DH) mais um encapsulamento
//! ML-KEM-768, todos misturados numa única raiz. O papel de cada lado
//! (iniciador/respondedor) é decidido por quem chama — via
//! `PublicIdentity::is_before` — comparando as `IK_dh`; isso resolve
//! handshake simultâneo sem round-trip extra e não precisa ser reverificado
//! aqui: se os dois lados discordarem do papel um do outro, o resultado é
//! simplesmente duas raízes diferentes, o mesmo efeito de qualquer outra
//! adulteração (ver §4.4 — a confirmação de chave é implícita).

use crate::crypto::dh::{self, DhPublic, DhSecret};
use crate::crypto::identity::{LocalIdentity, PublicIdentity};
use crate::crypto::kdf;
use crate::crypto::kem::{
    self, Kem, KemCiphertext, KemPublicKey, KemSecretKey, KemSharedSecret, MlKem768,
};
use crate::{Error, Result, PROTOCOL_VERSION};
use zeroize::{Zeroize, ZeroizeOnDrop};

/// Deslocamento da versão do protocolo, comum às duas mensagens.
const VERSION_AT: usize = 0;
/// Deslocamento do tipo de mensagem, comum às duas mensagens.
const MSG_TYPE_AT: usize = 1;
/// Deslocamento da chave X25519 efêmera, comum às duas mensagens.
const EK_AT: usize = 2;
/// Deslocamento do material do KEM: `KEM_ek_I` na INIT, `KEM_ct` na RESP.
const KEM_MATERIAL_AT: usize = EK_AT + dh::KEY_LEN;

/// `msg_type` da mensagem INIT (§4.1).
const MSG_TYPE_INIT: u8 = 0x01;
/// `msg_type` da mensagem RESP (§4.2).
const MSG_TYPE_RESP: u8 = 0x02;

/// Tamanho da INIT: version(1) + msg_type(1) + `EK_I`(32) + `KEM_ek_I`(1184).
pub const INIT_LEN: usize = KEM_MATERIAL_AT + kem::PUBLIC_KEY_LEN;
/// Tamanho da RESP: version(1) + msg_type(1) + `EK_R`(32) + `KEM_ct`(1088).
pub const RESP_LEN: usize = KEM_MATERIAL_AT + kem::CIPHERTEXT_LEN;

const _: () = assert!(INIT_LEN == 1218);
const _: () = assert!(RESP_LEN == 1122);

/// Tamanho do transcript: `version ‖ IK_dh_I ‖ IK_dh_R ‖ EK_I ‖ EK_R ‖ KEM_ek_I ‖ KEM_ct`.
const TRANSCRIPT_LEN: usize = 1 + dh::KEY_LEN * 4 + kem::PUBLIC_KEY_LEN + kem::CIPHERTEXT_LEN;

/// Tamanho do material bruto que entra na KDF: `DH1 ‖ DH2 ‖ DH3 ‖ SS_KEM ‖ transcript`.
const MATERIAL_LEN: usize = dh::KEY_LEN * 4 + TRANSCRIPT_LEN;

/// Buffer intermediário da derivação da raiz.
///
/// Junta os três acordos X25519, o segredo do KEM e o transcript num único
/// array para uma só chamada de `derive_key`, exatamente como a fórmula de
/// §4.3. Ele carrega segredo em claro enquanto vive (`DH1..SS_KEM`, os
/// primeiros 128 bytes), então é zerado ao sair de escopo — o transcript em
/// si não é segredo, mas zerar o array inteiro é mais simples e mais barato
/// do que separar as duas metades.
#[derive(Zeroize, ZeroizeOnDrop)]
struct HandshakeMaterial([u8; MATERIAL_LEN]);

/// Monta o transcript vinculado à raiz (§4.3).
///
/// É a peça que faz qualquer adulteração de um único byte de INIT ou RESP
/// mudar `K_root_0`: o transcript entra na KDF junto com os segredos, então
/// dois lados que não viram exatamente os mesmos bytes chegam a raízes
/// diferentes, mesmo que os DH e o KEM tenham corrido normalmente.
#[allow(clippy::too_many_arguments)]
fn build_transcript(
    ik_dh_i: &DhPublic,
    ik_dh_r: &DhPublic,
    ek_i: &DhPublic,
    ek_r: &DhPublic,
    kem_ek_i: &KemPublicKey,
    kem_ct: &KemCiphertext,
) -> [u8; TRANSCRIPT_LEN] {
    let mut out = [0u8; TRANSCRIPT_LEN];
    let mut at = 0;

    out[at] = PROTOCOL_VERSION;
    at += 1;
    out[at..at + dh::KEY_LEN].copy_from_slice(ik_dh_i.as_bytes());
    at += dh::KEY_LEN;
    out[at..at + dh::KEY_LEN].copy_from_slice(ik_dh_r.as_bytes());
    at += dh::KEY_LEN;
    out[at..at + dh::KEY_LEN].copy_from_slice(ek_i.as_bytes());
    at += dh::KEY_LEN;
    out[at..at + dh::KEY_LEN].copy_from_slice(ek_r.as_bytes());
    at += dh::KEY_LEN;
    out[at..at + kem::PUBLIC_KEY_LEN].copy_from_slice(kem_ek_i.as_bytes());
    at += kem::PUBLIC_KEY_LEN;
    out[at..at + kem::CIPHERTEXT_LEN].copy_from_slice(kem_ct.as_bytes());
    at += kem::CIPHERTEXT_LEN;

    debug_assert_eq!(at, TRANSCRIPT_LEN);
    out
}

/// Deriva `K_root_0` a partir dos três acordos, do segredo do KEM e do
/// transcript (§4.3), com o contexto `viska-handshake-v1`.
fn derive_root(
    dh1: &dh::DhShared,
    dh2: &dh::DhShared,
    dh3: &dh::DhShared,
    ss_kem: &KemSharedSecret,
    transcript: &[u8; TRANSCRIPT_LEN],
) -> kdf::Key {
    let mut material = HandshakeMaterial([0u8; MATERIAL_LEN]);
    let mut at = 0;

    material.0[at..at + dh::KEY_LEN].copy_from_slice(dh1.as_bytes());
    at += dh::KEY_LEN;
    material.0[at..at + dh::KEY_LEN].copy_from_slice(dh2.as_bytes());
    at += dh::KEY_LEN;
    material.0[at..at + dh::KEY_LEN].copy_from_slice(dh3.as_bytes());
    at += dh::KEY_LEN;
    material.0[at..at + dh::KEY_LEN].copy_from_slice(ss_kem.as_bytes());
    at += dh::KEY_LEN;
    material.0[at..at + TRANSCRIPT_LEN].copy_from_slice(transcript);
    at += TRANSCRIPT_LEN;

    debug_assert_eq!(at, MATERIAL_LEN);
    kdf::derive(kdf::context::HANDSHAKE, &material.0)
}

/// Valida comprimento, versão e tipo de uma mensagem de handshake recebida.
///
/// Sem downgrade negociado, como em `pairing::decode_qr`: uma versão que este
/// binário não conhece é rejeitada, nunca aceita "no modo antigo".
fn validate_header(msg: &[u8], expected_len: usize, expected_type: u8) -> Result<()> {
    if msg.len() != expected_len {
        return Err(Error::BadLength {
            expected: expected_len,
            actual: msg.len(),
        });
    }

    let version = msg[VERSION_AT];
    if version != PROTOCOL_VERSION {
        return Err(Error::UnsupportedVersion(version));
    }

    if msg[MSG_TYPE_AT] != expected_type {
        return Err(Error::Malformed("tipo de mensagem de handshake inesperado"));
    }

    Ok(())
}

/// O que o handshake entrega para o ratchet (§5, implementado à parte).
///
/// Carrega exatamente o que o passo inicial do Double Ratchet precisa e nada
/// além disso — em particular, nenhuma chave de longo prazo:
///
/// - `root`: `K_root_0`, a raiz recém-derivada, ainda sem nenhum passo de
///   cadeia aplicado.
/// - `local_ephemeral`: a chave X25519 efêmera que este lado já trocou neste
///   handshake (`EK_I` para o iniciador, `EK_R` para o respondedor).
///   Candidata natural ao primeiro `DHs` do ratchet (§5.1): ela já foi
///   trocada, não precisa nascer de novo, e reaproveitá-la não reintroduz
///   segredo velho porque o contexto de derivação da raiz do handshake
///   (`viska-handshake-v1`) e o da cadeia raiz do ratchet
///   (`viska-root-chain-v1`) são domínios de KDF separados.
/// - `remote_ephemeral`: a chave X25519 efêmera pública do outro lado —
///   candidata natural ao primeiro `DHr`.
/// - `is_initiator`: quem foi o iniciador deste AKE. O ratchet precisa saber
///   isso para decidir quem faz o primeiro passo DH (§5.2) antes de poder
///   cifrar: só quem já tem o `DHr` do outro lado consegue.
#[derive(Debug)]
pub struct HandshakeOutcome {
    pub root: kdf::Key,
    pub local_ephemeral: DhSecret,
    pub remote_ephemeral: DhPublic,
    pub is_initiator: bool,
}

/// Estado do lado iniciador entre o envio da INIT e o recebimento da RESP.
///
/// O ponto de existir como struct em vez de duas funções soltas é impedir,
/// pelo sistema de tipos, que a raiz seja produzida sem uma RESP de verdade:
/// `finish` consome `self`, então um `Initiator` só serve para uma troca.
///
/// Não guarda a `LocalIdentity` (nem uma referência a ela): uma camada de
/// sessão precisa manter este estado vivo entre duas chamadas de FFI
/// separadas (abrir a sessão, e só bem depois processar a RESP que chegou
/// pela rede), e uma struct com lifetime não sobrevive a isso sem virar
/// autorreferencial — o que exigiria `unsafe`, proibido neste crate. `finish`
/// recebe `local` como parâmetro na hora, exatamente como `respond` já faz.
pub struct Initiator {
    /// `IK_dh` pública do par, já conhecida do pareamento.
    peer_dh: DhPublic,
    ek_secret: DhSecret,
    ek_public: DhPublic,
    kem_secret: KemSecretKey,
    kem_public: KemPublicKey,
}

impl Initiator {
    /// Inicia o handshake e produz a mensagem INIT (§4.1).
    ///
    /// Quem chama decide o papel de antemão comparando `IK_dh` com
    /// `PublicIdentity::is_before` — esta função não reafirma a checagem
    /// porque a segurança do protocolo não depende dela (ver o comentário de
    /// módulo): ela só existe para evitar round-trip extra em handshake
    /// simultâneo, não para impedir ataque nenhum.
    pub fn start(local: &LocalIdentity, peer: &PublicIdentity) -> Result<(Self, [u8; INIT_LEN])> {
        let _ = local;
        let ek_secret = DhSecret::generate()?;
        let ek_public = ek_secret.public();
        let kem_pair = MlKem768::generate()?;

        let mut init = [0u8; INIT_LEN];
        init[VERSION_AT] = PROTOCOL_VERSION;
        init[MSG_TYPE_AT] = MSG_TYPE_INIT;
        init[EK_AT..EK_AT + dh::KEY_LEN].copy_from_slice(ek_public.as_bytes());
        init[KEM_MATERIAL_AT..].copy_from_slice(kem_pair.public.as_bytes());

        let state = Self {
            peer_dh: peer.dh,
            ek_secret,
            ek_public,
            kem_secret: kem_pair.secret,
            kem_public: kem_pair.public,
        };

        Ok((state, init))
    }

    /// Consome a RESP (§4.2) e produz a raiz da sessão.
    ///
    /// Sem verificação de assinatura nenhuma: a autenticação inteira está em
    /// `local.dh().agree(..)` — se o outro lado não tiver a `IK_dh` privada
    /// que corresponde à chave obtida no QR, o `DH1` que ele computou do lado
    /// dele não bate com o nosso, e as duas raízes simplesmente divergem, sem
    /// que nenhum erro explícito seja necessário nem possível (D1, §4.4).
    pub fn finish(self, local: &LocalIdentity, resp: &[u8]) -> Result<HandshakeOutcome> {
        validate_header(resp, RESP_LEN, MSG_TYPE_RESP)?;

        let ek_r = DhPublic::from_slice(&resp[EK_AT..EK_AT + dh::KEY_LEN])?;
        let kem_ct = KemCiphertext::from_slice(&resp[KEM_MATERIAL_AT..])?;

        // DH1 = X25519(IK_dh_I, EK_R): autentica I para R.
        let dh1 = local.dh().agree(&ek_r)?;
        // DH2 = X25519(EK_I, IK_dh_R): autentica R para I.
        let dh2 = self.ek_secret.agree(&self.peer_dh)?;
        // DH3 = X25519(EK_I, EK_R): forward secrecy.
        let dh3 = self.ek_secret.agree(&ek_r)?;
        let ss_kem = MlKem768::decapsulate(&self.kem_secret, &kem_ct)?;

        let ik_dh_i = local.dh().public();
        let transcript = build_transcript(
            &ik_dh_i,
            &self.peer_dh,
            &self.ek_public,
            &ek_r,
            &self.kem_public,
            &kem_ct,
        );
        let root = derive_root(&dh1, &dh2, &dh3, &ss_kem, &transcript);

        Ok(HandshakeOutcome {
            root,
            local_ephemeral: self.ek_secret,
            remote_ephemeral: ek_r,
            is_initiator: true,
        })
    }
}

impl core::fmt::Debug for Initiator {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("Initiator")
            .field("peer_dh", &self.peer_dh)
            .field("ek_public", &self.ek_public)
            .field("ek_secret", &"<redigida>")
            .field("kem_secret", &"<redigida>")
            .finish()
    }
}

/// Processa a INIT (§4.1) e produz a RESP (§4.2) junto com a raiz da sessão.
///
/// Função livre, não struct de estado: o respondedor participa de uma única
/// troca e não precisa guardar nada entre mensagens além do que já sai
/// dentro de `HandshakeOutcome`.
pub fn respond(
    local: &LocalIdentity,
    peer: &PublicIdentity,
    init: &[u8],
) -> Result<(HandshakeOutcome, [u8; RESP_LEN])> {
    validate_header(init, INIT_LEN, MSG_TYPE_INIT)?;

    let ek_i = DhPublic::from_slice(&init[EK_AT..EK_AT + dh::KEY_LEN])?;
    let kem_ek_i = KemPublicKey::from_slice(&init[KEM_MATERIAL_AT..])?;

    let ek_secret = DhSecret::generate()?;
    let ek_r = ek_secret.public();
    let (kem_ct, ss_kem) = MlKem768::encapsulate(&kem_ek_i)?;

    // Mesmas três fórmulas de `Initiator::finish`, computadas do outro lado:
    // X25519 é comutativo em quem guarda o segredo, então
    // `ek_secret.agree(&peer.dh)` aqui é o mesmo valor que
    // `local_dh.agree(&ek_r)` calcula do lado do iniciador.
    let dh1 = ek_secret.agree(&peer.dh)?;
    let dh2 = local.dh().agree(&ek_i)?;
    let dh3 = ek_secret.agree(&ek_i)?;

    let ik_dh_r = local.dh().public();
    let transcript = build_transcript(&peer.dh, &ik_dh_r, &ek_i, &ek_r, &kem_ek_i, &kem_ct);
    let root = derive_root(&dh1, &dh2, &dh3, &ss_kem, &transcript);

    let mut resp = [0u8; RESP_LEN];
    resp[VERSION_AT] = PROTOCOL_VERSION;
    resp[MSG_TYPE_AT] = MSG_TYPE_RESP;
    resp[EK_AT..EK_AT + dh::KEY_LEN].copy_from_slice(ek_r.as_bytes());
    resp[KEM_MATERIAL_AT..].copy_from_slice(kem_ct.as_bytes());

    let outcome = HandshakeOutcome {
        root,
        local_ephemeral: ek_secret,
        remote_ephemeral: ek_i,
        is_initiator: false,
    };

    Ok((outcome, resp))
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

    /// Recria um `Initiator` com o mesmo material efêmero de `original`.
    ///
    /// Usado para testar várias RESPs adulteradas contra a mesma dupla de
    /// efêmeras sem regenerar chaves a cada iteração — regenerar produziria
    /// uma raiz diferente de qualquer forma, o que mascararia o efeito da
    /// adulteração em si.
    fn clone_initiator(original: &Initiator) -> Initiator {
        Initiator {
            peer_dh: original.peer_dh,
            ek_secret: DhSecret::from_bytes(original.ek_secret.to_bytes()),
            ek_public: original.ek_public,
            kem_secret: original.kem_secret.clone(),
            kem_public: original.kem_public.clone(),
        }
    }

    #[test]
    fn handshake_completo_produz_a_mesma_raiz_dos_dois_lados() {
        let (alice, bob) = pair();
        let (initiator, init) = Initiator::start(&alice, &bob.public()).unwrap();
        let (resp_outcome, resp) = respond(&bob, &alice.public(), &init).unwrap();
        let init_outcome = initiator.finish(&alice, &resp).unwrap();

        assert_eq!(init_outcome.root.as_bytes(), resp_outcome.root.as_bytes());
        assert!(init_outcome.is_initiator);
        assert!(!resp_outcome.is_initiator);
    }

    #[test]
    fn duas_execucoes_produzem_raizes_diferentes() {
        let (alice, bob) = pair();

        let (initiator1, init1) = Initiator::start(&alice, &bob.public()).unwrap();
        let (_, resp1) = respond(&bob, &alice.public(), &init1).unwrap();
        let root1 = initiator1.finish(&alice, &resp1).unwrap().root;

        let (initiator2, init2) = Initiator::start(&alice, &bob.public()).unwrap();
        let (_, resp2) = respond(&bob, &alice.public(), &init2).unwrap();
        let root2 = initiator2.finish(&alice, &resp2).unwrap().root;

        assert_ne!(root1.as_bytes(), root2.as_bytes());
    }

    #[test]
    fn terceiro_sem_a_chave_privada_correta_nao_deriva_a_mesma_raiz() {
        let (alice, bob) = pair();
        let eve = LocalIdentity::generate().unwrap();

        let (initiator, init) = Initiator::start(&alice, &bob.public()).unwrap();
        let (bob_outcome, resp) = respond(&bob, &alice.public(), &init).unwrap();
        let alice_outcome = initiator.finish(&alice, &resp).unwrap();
        assert_eq!(alice_outcome.root.as_bytes(), bob_outcome.root.as_bytes());

        // Eve observa a INIT inteira (é pública, ainda não há sessão) e tenta
        // bancar o respondedor sem ser dona da IK_dh que Bob apresentou no
        // QR. Mesmo com a mensagem completa em mãos, ela não chega à mesma
        // raiz, porque DH1 e DH2 dependem da IK_dh privada de Bob.
        let (eve_outcome, _eve_resp) = respond(&eve, &alice.public(), &init).unwrap();
        assert_ne!(eve_outcome.root.as_bytes(), alice_outcome.root.as_bytes());
    }

    #[test]
    fn adulterar_um_byte_da_init_diverge_a_raiz_ou_falha() {
        let (alice, bob) = pair();
        let (initiator, init) = Initiator::start(&alice, &bob.public()).unwrap();
        let (_, resp) = respond(&bob, &alice.public(), &init).unwrap();
        let correct_root = initiator.finish(&alice, &resp).unwrap().root;

        for index in 0..INIT_LEN {
            for bit in 0..8u8 {
                let mut tampered = init;
                tampered[index] ^= 1 << bit;
                if tampered == init {
                    continue;
                }

                if let Ok((outcome, _)) = respond(&bob, &alice.public(), &tampered) {
                    assert_ne!(
                        outcome.root.as_bytes(),
                        correct_root.as_bytes(),
                        "byte {index} bit {bit} da INIT não mudou a raiz"
                    );
                }
            }
        }
    }

    #[test]
    fn adulterar_um_byte_da_resp_diverge_a_raiz_ou_falha() {
        let (alice, bob) = pair();
        let (initiator, init) = Initiator::start(&alice, &bob.public()).unwrap();
        let (_, resp) = respond(&bob, &alice.public(), &init).unwrap();
        let correct_root = clone_initiator(&initiator).finish(&alice, &resp).unwrap().root;

        for index in 0..RESP_LEN {
            for bit in 0..8u8 {
                let mut tampered = resp;
                tampered[index] ^= 1 << bit;
                if tampered == resp {
                    continue;
                }

                if let Ok(outcome) = clone_initiator(&initiator).finish(&alice, &tampered) {
                    assert_ne!(
                        outcome.root.as_bytes(),
                        correct_root.as_bytes(),
                        "byte {index} bit {bit} da RESP não mudou a raiz"
                    );
                }
            }
        }
    }

    #[test]
    fn rejeita_tamanho_errado_na_init() {
        let (alice, bob) = pair();
        let (_, init) = Initiator::start(&alice, &bob.public()).unwrap();

        assert!(matches!(
            respond(&bob, &alice.public(), &init[..INIT_LEN - 1]),
            Err(Error::BadLength { .. })
        ));
    }

    #[test]
    fn rejeita_tamanho_errado_na_resp() {
        let (alice, bob) = pair();
        let (initiator, init) = Initiator::start(&alice, &bob.public()).unwrap();
        let (_, resp) = respond(&bob, &alice.public(), &init).unwrap();

        assert!(matches!(
            initiator.finish(&alice, &resp[..RESP_LEN - 1]),
            Err(Error::BadLength { .. })
        ));
    }

    #[test]
    fn rejeita_versao_desconhecida_na_init() {
        let (alice, bob) = pair();
        let (_, mut init) = Initiator::start(&alice, &bob.public()).unwrap();
        init[VERSION_AT] = 0x02;

        assert!(matches!(
            respond(&bob, &alice.public(), &init),
            Err(Error::UnsupportedVersion(0x02))
        ));
    }

    #[test]
    fn rejeita_versao_desconhecida_na_resp() {
        let (alice, bob) = pair();
        let (initiator, init) = Initiator::start(&alice, &bob.public()).unwrap();
        let (_, mut resp) = respond(&bob, &alice.public(), &init).unwrap();
        resp[VERSION_AT] = 0x02;

        assert!(matches!(
            initiator.finish(&alice, &resp),
            Err(Error::UnsupportedVersion(0x02))
        ));
    }

    #[test]
    fn rejeita_msg_type_errado_na_init() {
        let (alice, bob) = pair();
        let (_, mut init) = Initiator::start(&alice, &bob.public()).unwrap();
        init[MSG_TYPE_AT] = MSG_TYPE_RESP;

        assert!(matches!(
            respond(&bob, &alice.public(), &init),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn rejeita_msg_type_errado_na_resp() {
        let (alice, bob) = pair();
        let (initiator, init) = Initiator::start(&alice, &bob.public()).unwrap();
        let (_, mut resp) = respond(&bob, &alice.public(), &init).unwrap();
        resp[MSG_TYPE_AT] = MSG_TYPE_INIT;

        assert!(matches!(
            initiator.finish(&alice, &resp),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn rejeita_ek_de_ordem_baixa_na_init() {
        let (alice, bob) = pair();
        let (_, mut init) = Initiator::start(&alice, &bob.public()).unwrap();
        init[EK_AT..EK_AT + dh::KEY_LEN].copy_from_slice(&[0u8; dh::KEY_LEN]);

        assert!(matches!(
            respond(&bob, &alice.public(), &init),
            Err(Error::LowOrderPoint)
        ));
    }

    #[test]
    fn rejeita_ek_de_ordem_baixa_na_resp() {
        let (alice, bob) = pair();
        let (initiator, init) = Initiator::start(&alice, &bob.public()).unwrap();
        let (_, mut resp) = respond(&bob, &alice.public(), &init).unwrap();
        resp[EK_AT..EK_AT + dh::KEY_LEN].copy_from_slice(&[0u8; dh::KEY_LEN]);

        assert!(matches!(
            initiator.finish(&alice, &resp),
            Err(Error::LowOrderPoint)
        ));
    }
}
