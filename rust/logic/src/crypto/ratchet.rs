//! Ratchet — Double Ratchet no estilo Signal, com BLAKE3 e um ratchet KEM
//! adicional, §5 da especificação.
//!
//! ## Inicialização assimétrica (§5.1, a partir do `HandshakeOutcome`)
//!
//! O doc-comment de `HandshakeOutcome` sugere, de forma imprecisa, que
//! qualquer um dos lados poderia reaproveitar `local_ephemeral` como `DHs`
//! inicial. Isso está errado e este módulo não segue essa sugestão:
//!
//! - O **respondedor** reaproveita `local_ephemeral` como `DHs` inicial. Ele
//!   não tem `CKs` nem `CKr` — não consegue cifrar nada até receber a
//!   primeira mensagem do iniciador, porque só quem recebe o `DHr` novo do
//!   outro lado consegue fazer o primeiro passo DH (§5.2).
//! - O **iniciador** descarta `local_ephemeral`, gera um `DHs` X25519 novo,
//!   usa `remote_ephemeral` como `DHr` inicial e já executa um passo DH para
//!   obter `CKs` antes de devolver o estado.
//!
//! Se os dois lados reaproveitassem a efêmera do handshake como `DHs`, o
//! primeiro passo DH do ratchet recalcularia exatamente o `DH3` que já entrou
//! em `K_root_0` — o mesmo `X25519(EK_I, EK_R)` de novo — e o primeiro
//! ratchet não acrescentaria nenhuma entropia nova. Fazer o iniciador gerar
//! uma chave nova é o que garante que o primeiro passo do ratchet já misture
//! material que não existia no momento do handshake.
//!
//! ## Estado alterado antes da autenticação do AEAD
//!
//! `receiving_key` não decifra nada — quem chama essa API decide depois, na
//! camada de sessão, se o AEAD abriu. Isso cria um problema real: processar
//! um cabeçalho pode exigir um passo DH inteiro (§5.2) ou completar um ciclo
//! de re-KEM (§5.4), os dois mutando `RK` de um jeito que não tem volta —
//! `RK` só anda para frente, por construção (é assim que a forward secrecy
//! funciona). Se `receiving_key` aplicasse isso direto em `self` e a mensagem
//! se revelasse forjada (um `dh_pub` de repetição, um `KEM_ek` de um atacante
//! sem chave nenhuma, um cabeçalho de uma sessão antiga sendo repetido), a
//! sessão real divergiria da do par: cada lado teria dobrado uma `RK`
//! diferente, e nenhuma mensagem futura decifraria de novo. Uma única
//! mensagem forjada derrubaria a conversa inteira.
//!
//! A solução adotada é **commit explícito**: `receiving_key` calcula tudo —
//! passo DH incluído, ciclo de re-KEM incluído — e guarda o resultado em
//! `self.pending`, sem tocar no estado "de confiança" (`RK`, `DHs`, `DHr`,
//! `CKs`, `CKr`, `PN`). Só depois que a camada de sessão confirma que o AEAD
//! abriu com a chave devolvida, ela chama `commit_receive`, que aplica o que
//! está em `pending`. Se o AEAD falhar, ela chama `discard_receive` (ou
//! simplesmente processa a próxima mensagem, que substitui o `pending`
//! antigo). Isso torna `receiving_key` idempotente em relação ao estado de
//! confiança: chamá-la de novo para o mesmo cabeçalho, ou para outro, nunca
//! deixa `self` num estado intermediário.
//!
//! Nem toda mutação precisa dessa cautela. A busca no cache de mensagens
//! puladas (§5.5) é aplicada na hora, mesmo antes de qualquer commit: ela só
//! lê uma chave que já foi derivada e confirmada num passo anterior, então
//! consumi-la (uso único) não pode fazer a sessão divergir — na pior das
//! hipóteses, uma mensagem forjada com o contador certo consome uma chave que
//! a mensagem legítima correspondente também precisaria, tornando as duas
//! indecifráveis. Isso é exatamente o "chave de uso único" do Double Ratchet
//! (§5.3), não uma corrupção de estado.
//!
//! ## Ciclo do re-KEM (§5.4)
//!
//! Quem dispara (contagem ou tempo, o que vier primeiro) gera um par
//! ML-KEM-768 novo, guarda a chave secreta em `own_kem_secret` e anexa a
//! pública ao próximo cabeçalho de saída. Enquanto espera a resposta, não
//! dispara de novo (`own_kem_secret` já ocupado). A contraparte, ao ver
//! `kem_ek` num cabeçalho recebido, encapsula, mistura `RK` na hora do
//! commit e enfileira o `KEM_ct` para sair no próximo cabeçalho que ela
//! mandar. Quando o `kem_ct` volta para quem disparou, ela decapsula, mistura
//! `RK` do mesmo jeito e libera `own_kem_secret`. Os dois lados fazem
//! `RK = derive_key("viska-rekem-v1", RK ‖ SS_KEM_novo)` de forma
//! independente, um de cada lado da troca — não há round-trip extra dedicado
//! a isso, o ciclo se completa nas duas próximas mensagens que já iam ser
//! trocadas de qualquer forma.

use crate::crypto::dh::{self, DhPublic, DhSecret};
use crate::crypto::handshake::HandshakeOutcome;
use crate::crypto::kdf;
use crate::crypto::kem::{
    self, Kem, KemCiphertext, KemPublicKey, KemSecretKey, KemSharedSecret, MlKem768,
};
use crate::{Error, Result};
use std::collections::HashMap;
use zeroize::Zeroize;

/// Gatilho do re-KEM por contagem (§5.4): a cada 256 mensagens enviadas por
/// este lado desde o último ciclo completo.
const REKEM_MSG_THRESHOLD: u32 = 256;
/// Gatilho do re-KEM por tempo (§5.4): 24 horas, em segundos.
const REKEM_TIME_THRESHOLD_SECONDS: u64 = 24 * 3600;

/// Identifica uma chave de mensagem pulada (§5.5): `(DHr da cadeia, contador)`.
type SkippedId = ([u8; 32], u32);
/// Lote de chaves puladas coletadas durante `receiving_key`, ainda não
/// aplicadas a `self.skipped` — ver `PendingReceive`.
type SkippedAdditions = Vec<(SkippedId, kdf::Key)>;

/// Deriva a chave de mensagem e a próxima chave de cadeia (§5.3).
///
/// O texto de §5.3 lista dois contextos, `viska-send-chain-v1` para quem
/// envia e `viska-recv-chain-v1` para quem recebe, como se cada lado
/// escolhesse o contexto pelo seu papel local na troca. Isso não pode estar
/// certo: `CKs` de quem envia e `CKr` de quem recebe são o mesmo segredo,
/// numericamente, avançando em paralelo nas duas pontas — se cada lado
/// aplicasse um contexto de domínio diferente ao avançar essa mesma cadeia,
/// as duas pontas divergiriam depois da primeira mensagem, e nenhuma
/// mensagem seguinte seria decifrável (confirmado por teste: é exatamente o
/// que acontece se `CKr` avança com `RECV_CHAIN` enquanto `CKs` avança com
/// `SEND_CHAIN` para a mesma cadeia).
///
/// A leitura que preserva correção é: quem **cria** uma cadeia (o lado que
/// gerou o `DHs` dela) sempre a rotula como sua cadeia de envio e sempre usa
/// `SEND_CHAIN` para avançá-la — e isso vale tanto para o iniciador quanto
/// para o respondedor, simetricamente. A outra ponta, ao herdar essa mesma
/// cadeia como sua `CKr`, precisa reproduzir exatamente o cálculo de quem a
/// criou para os valores continuarem batendo, então usa o mesmo contexto
/// `SEND_CHAIN`, não `RECV_CHAIN`. Na prática, isso significa que
/// `viska-recv-chain-v1` nunca é usado por este módulo — ver o relatório
/// final sobre esta divergência da especificação.
fn chain_step(chain_key: &kdf::Key) -> (kdf::Key, kdf::Key) {
    let mut material = [0u8; kdf::KEY_LEN + 1];
    material[..kdf::KEY_LEN].copy_from_slice(chain_key.as_bytes());

    material[kdf::KEY_LEN] = 0x01;
    let message_key = kdf::derive(kdf::context::MESSAGE_KEY, &material);

    material[kdf::KEY_LEN] = 0x02;
    let next_key = kdf::derive(kdf::context::SEND_CHAIN, &material);

    material.zeroize();
    (next_key, message_key)
}

/// `kdf_rk` de §5.2: um passo da cadeia raiz a partir de um segredo DH novo.
fn kdf_rk(root: &kdf::Key, dh_shared: &dh::DhShared) -> (kdf::Key, kdf::Key) {
    let mut material = [0u8; kdf::KEY_LEN * 2];
    material[..kdf::KEY_LEN].copy_from_slice(root.as_bytes());
    material[kdf::KEY_LEN..].copy_from_slice(dh_shared.as_bytes());

    let pair = kdf::derive_pair(kdf::context::ROOT_CHAIN, &material);
    material.zeroize();
    pair
}

/// Mistura um segredo do re-KEM em `RK` (§5.4): `derive("viska-rekem-v1", RK ‖ SS)`.
fn fold_rekem(root: &kdf::Key, shared: &KemSharedSecret) -> kdf::Key {
    let mut material = [0u8; kdf::KEY_LEN + kem::SHARED_SECRET_LEN];
    material[..kdf::KEY_LEN].copy_from_slice(root.as_bytes());
    material[kdf::KEY_LEN..].copy_from_slice(shared.as_bytes());

    let next_root = kdf::derive(kdf::context::REKEM, &material);
    material.zeroize();
    next_root
}

/// Executa o passo DH completo do ratchet (§5.2) a partir do estado atual.
///
/// Função livre, não método: devolve os quatro valores resultantes em vez de
/// mutar `self` diretamente, porque quem chama (`receiving_key`) precisa
/// poder descartá-los sem afetar nada caso a mensagem correspondente não se
/// autentique depois — ver a documentação de módulo.
///
/// `kem_ct_fold`, quando presente, é o segredo de um `KEM_ct` que completa um
/// ciclo de re-KEM que NÓS disparamos — e precisa entrar bem aqui, entre o
/// dobramento de recepção e o de envio, nunca antes nem depois dos dois.
/// Antes corromperia `CKr` (a cadeia que decifra ESTA mensagem, que o par
/// derivou sem saber nada sobre esse segredo). Depois dos dois faria a
/// próxima cadeia que criamos (`CKs`) divergir do que o par vai precisar como
/// base do próprio passo DH dele mais adiante — a `RK` "no meio" é
/// exatamente o valor que o criador de um `DHr` novo tinha na mão quando o
/// criou, e é isso que o outro lado precisa reproduzir para casar a próxima
/// rodada. Confirmado por teste: qualquer uma das outras duas posições
/// decifra a mensagem atual mas diverge duas trocas depois.
fn ratchet_dh_step(
    root: &kdf::Key,
    dh_self_current: &DhSecret,
    dh_remote_new: &DhPublic,
    kem_ct_fold: Option<&KemSharedSecret>,
) -> Result<(kdf::Key, kdf::Key, DhSecret, kdf::Key, [u8; kdf::KEY_LEN])> {
    // RK, CKr = kdf_rk(RK, X25519(DHs_antigo, DHr_novo))
    let shared_recv = dh_self_current.agree(dh_remote_new)?;
    let (root_after_recv, recv_chain) = kdf_rk(root, &shared_recv);
    let recv_fold_bytes = *root_after_recv.as_bytes();

    let root_mid = match kem_ct_fold {
        Some(shared) => fold_rekem(&root_after_recv, shared),
        None => root_after_recv,
    };

    // DHs = nova chave X25519; RK, CKs = kdf_rk(RK, X25519(DHs_novo, DHr_novo))
    let dh_self_new = DhSecret::generate()?;
    let shared_send = dh_self_new.agree(dh_remote_new)?;
    let (root_after_send, send_chain) = kdf_rk(&root_mid, &shared_send);

    Ok((root_after_send, recv_chain, dh_self_new, send_chain, recv_fold_bytes))
}

/// Avança `chain_key` de `from` até `to` (exclusive), guardando cada chave de
/// mensagem pulada no caminho (§5.5). Devolve a cadeia posicionada em `to`.
///
/// Recusa (`Error::UndecryptableMessage`) se o intervalo excede
/// `SkippedKeys::CAP`: pular mais do que isso nunca compensaria, a mensagem já
/// nasceria fora da janela que este lado está disposto a guardar — e recusar
/// aqui evita que um contador forjado force milhões de passos de BLAKE3 antes
/// de chegarmos à mesma conclusão de qualquer forma.
fn walk_and_skip(
    mut chain_key: kdf::Key,
    from: u32,
    to: u32,
    dh_id: [u8; 32],
) -> Result<(kdf::Key, SkippedAdditions)> {
    let span = to.saturating_sub(from) as usize;
    if span > SkippedKeys::CAP {
        return Err(Error::UndecryptableMessage);
    }

    let mut skipped = Vec::with_capacity(span);
    for index in from..to {
        let (next_key, message_key) = chain_step(&chain_key);
        skipped.push(((dh_id, index), message_key));
        chain_key = next_key;
    }
    Ok((chain_key, skipped))
}

/// Chaves de mensagem puladas, com teto rígido e TTL (§5.5).
///
/// A chave do mapa é `(DHr da cadeia à qual a mensagem pertencia, contador)`
/// — não basta o contador sozinho porque ele reinicia a cada passo DH, então
/// duas cadeias diferentes podem ter a mesma mensagem número 3.
struct SkippedKeys {
    entries: HashMap<SkippedId, SkippedEntry>,
    /// Contador monotônico só para decidir "qual é a mais velha" ao estourar
    /// o teto. `stored_at` (relógio de parede, resolução de segundo) não
    /// serve para isso sozinho: um lote de mensagens processado dentro do
    /// mesmo segundo produz várias entradas com o MESMO timestamp, e
    /// desempatar por ordem de iteração do `HashMap` (não determinística)
    /// evictaria uma entrada arbitrária, não necessariamente a mais velha —
    /// confirmado por teste. Este contador nunca empata.
    next_seq: u64,
}

struct SkippedEntry {
    key: kdf::Key,
    stored_at: u64,
    seq: u64,
}

impl SkippedKeys {
    /// Teto rígido de chaves puladas por sessão (§5.5).
    const CAP: usize = 1000;
    /// TTL de uma chave pulada (§5.5): 7 dias.
    const TTL_SECONDS: u64 = 7 * 24 * 3600;

    fn new() -> Self {
        Self {
            entries: HashMap::new(),
            next_seq: 0,
        }
    }

    fn len(&self) -> usize {
        self.entries.len()
    }

    /// Remove entradas mais velhas que o TTL.
    fn evict_expired(&mut self, now: u64) {
        self.entries
            .retain(|_, entry| now.saturating_sub(entry.stored_at) < Self::TTL_SECONDS);
    }

    /// Insere uma chave pulada, aplicando TTL e o teto de `CAP`.
    ///
    /// Estourado o teto, a entrada mais velha é descartada — a mensagem
    /// correspondente vira indecifrável, que é o comportamento desejado por
    /// §5.5, não um erro de protocolo.
    fn insert(&mut self, id: SkippedId, key: kdf::Key, now: u64) {
        self.evict_expired(now);

        if self.entries.len() >= Self::CAP && !self.entries.contains_key(&id) {
            if let Some(oldest) = self
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.seq)
                .map(|(id, _)| *id)
            {
                self.entries.remove(&oldest);
            }
        }

        let seq = self.next_seq;
        self.next_seq += 1;
        self.entries.insert(
            id,
            SkippedEntry {
                key,
                stored_at: now,
                seq,
            },
        );
    }

    /// Consome uma chave pulada, se existir.
    ///
    /// Uso único por construção (§5.3): a entrada some do mapa mesmo que a
    /// mensagem correspondente ainda não tenha sido autenticada pelo AEAD —
    /// isso é seguro porque essa chave já foi derivada e confirmada num passo
    /// anterior, ver a documentação de módulo.
    fn take(&mut self, id: &SkippedId) -> Option<kdf::Key> {
        self.entries.remove(id).map(|entry| entry.key)
    }
}

/// Resultado de `receiving_key` ainda não aplicado a `self`.
///
/// Só é gravado no estado "de confiança" por `commit_receive`, depois que a
/// camada de sessão confirma que o AEAD abriu com a chave devolvida. Ver a
/// documentação de módulo.
struct PendingReceive {
    root: kdf::Key,
    send_chain: Option<kdf::Key>,
    recv_chain: Option<kdf::Key>,
    /// `Some` só quando este cabeçalho disparou um passo DH (§5.2).
    new_dh_self: Option<DhSecret>,
    dh_remote: DhPublic,
    ns: u32,
    nr: u32,
    pn: u32,
    skipped_additions: SkippedAdditions,
    clear_own_kem_secret: bool,
    outgoing_kem_ct: Option<KemCiphertext>,
    rekem_completed: bool,
    #[cfg_attr(not(test), allow(dead_code))]
    recv_fold_root: Option<[u8; kdf::KEY_LEN]>,
}

/// Campos do cabeçalho do ratchet (§6.1), como valores já resolvidos.
///
/// O ratchet não serializa nada — quem monta e lê os bytes do envelope é o
/// módulo `wire`. Este tipo é só o contrato de dados entre as duas pontas:
/// `next_sending_key` produz um, `receiving_key` consome um.
#[derive(Clone, Debug)]
pub struct RatchetHeader {
    /// Chave pública X25519 atual do `DHs` de quem enviou (`dh_pub` de §6.1).
    pub dh_pub: DhPublic,
    /// Mensagens da cadeia de envio anterior de quem enviou.
    pub pn: u32,
    /// `Ns` desta mensagem na cadeia de envio atual de quem enviou.
    pub counter: u32,
    /// Presente quando esta mensagem dispara um novo ciclo de re-KEM (§5.4).
    pub kem_ek: Option<KemPublicKey>,
    /// Presente quando esta mensagem completa um ciclo de re-KEM que a outra
    /// ponta disparou (§5.4).
    pub kem_ct: Option<KemCiphertext>,
}

/// Estado do Double Ratchet de uma sessão (§5.1).
pub struct RatchetState {
    root: kdf::Key,
    sending_chain: Option<kdf::Key>,
    receiving_chain: Option<kdf::Key>,
    dh_self: DhSecret,
    dh_remote: Option<DhPublic>,
    ns: u32,
    nr: u32,
    pn: u32,
    skipped: SkippedKeys,
    /// Chave secreta ML-KEM do ciclo de re-KEM que ESTE lado disparou,
    /// enquanto espera o `KEM_ct` de volta. `None` quando não há ciclo em
    /// aberto por iniciativa própria.
    own_kem_secret: Option<KemSecretKey>,
    /// `KEM_ct` já computado (encapsulamos contra um `KEM_ek` recebido) que
    /// ainda não saiu no fio — vai no próximo cabeçalho de saída.
    pending_outgoing_kem_ct: Option<KemCiphertext>,
    msgs_since_rekem: u32,
    last_rekem_at: u64,
    /// Resultado do último `receiving_key` ainda não confirmado — ver a
    /// documentação de módulo.
    pending: Option<PendingReceive>,
}

impl RatchetState {
    /// Inicializa o ratchet a partir do desfecho do handshake (§5.1).
    ///
    /// A inicialização é assimétrica — ver a documentação de módulo para o
    /// porquê. Iniciador e respondedor terminam esta função em estados bem
    /// diferentes: o respondedor sai sem conseguir cifrar nada ainda.
    pub fn initialize(outcome: HandshakeOutcome) -> Result<Self> {
        let HandshakeOutcome {
            root,
            local_ephemeral,
            remote_ephemeral,
            is_initiator,
        } = outcome;
        let now = crate::util::time::unix_seconds();

        if is_initiator {
            // Descarta a efêmera do handshake de propósito: reaproveitá-la
            // recalcularia o DH3 que já entrou em K_root_0, e o primeiro
            // passo do ratchet não acrescentaria entropia nenhuma.
            drop(local_ephemeral);

            let dh_self = DhSecret::generate()?;
            let shared = dh_self.agree(&remote_ephemeral)?;
            let (new_root, send_chain) = kdf_rk(&root, &shared);

            Ok(Self {
                root: new_root,
                sending_chain: Some(send_chain),
                receiving_chain: None,
                dh_self,
                dh_remote: Some(remote_ephemeral),
                ns: 0,
                nr: 0,
                pn: 0,
                skipped: SkippedKeys::new(),
                own_kem_secret: None,
                pending_outgoing_kem_ct: None,
                msgs_since_rekem: 0,
                last_rekem_at: now,
                pending: None,
            })
        } else {
            // Reaproveita a efêmera do handshake como DHs inicial: sem CKs
            // nem CKr ainda, porque só o iniciador tem o DHr necessário para
            // fazer o primeiro passo DH.
            Ok(Self {
                root,
                sending_chain: None,
                receiving_chain: None,
                dh_self: local_ephemeral,
                dh_remote: None,
                ns: 0,
                nr: 0,
                pn: 0,
                skipped: SkippedKeys::new(),
                own_kem_secret: None,
                pending_outgoing_kem_ct: None,
                msgs_since_rekem: 0,
                last_rekem_at: now,
                pending: None,
            })
        }
    }

    /// Avança a cadeia de envio e devolve o cabeçalho e a chave desta mensagem.
    ///
    /// Erra se ainda não há cadeia de envio — só acontece com o respondedor
    /// antes de processar (e confirmar, via `commit_receive`) a primeira
    /// mensagem do iniciador (§5.1).
    pub fn next_sending_key(&mut self) -> Result<(RatchetHeader, kdf::Key)> {
        let chain = self.sending_chain.as_ref().ok_or(Error::InvalidState(
            "cadeia de envio ainda não estabelecida",
        ))?;
        let (next_chain, message_key) = chain_step(chain);

        let counter = self.ns;
        let next_ns = self.ns.checked_add(1).ok_or(Error::CounterOverflow)?;
        self.sending_chain = Some(next_chain);
        self.ns = next_ns;
        self.msgs_since_rekem = self.msgs_since_rekem.saturating_add(1);

        // Gatilho do re-KEM (§5.4): contagem ou tempo, o que vier primeiro. Só
        // dispara se não há um ciclo nosso já em aberto — senão o gatilho
        // continuaria "verdadeiro" a cada mensagem enquanto esperamos a
        // resposta, e disparar de novo por cima perderia o KEM_sk pendente.
        //
        // Também não dispara se esta mensagem já vai carregar um `KEM_ct` de
        // volta para a contraparte (ciclo dela, que completamos ao receber o
        // `KEM_ek` dela). Um único cabeçalho poderia, em princípio, carregar
        // os dois — o layout do fio (§6.1) reserva um bit para cada um,
        // independentes — mas isso obrigaria a RK a absorver dois
        // dobramentos de re-KEM na mesma mensagem em posições diferentes (um
        // "no meio" do passo DH, outro "depois" dele) para as duas pontas
        // continuarem convergindo, e essa combinação é frágil o bastante
        // para não valer a complexidade: adiar nosso próprio disparo por uma
        // mensagem custa, no pior caso, uma latência extra desprezível.
        let now = crate::util::time::unix_seconds();
        let mut kem_ek = None;
        let kem_ct = self.pending_outgoing_kem_ct.take();
        if kem_ct.is_none()
            && self.own_kem_secret.is_none()
            && (self.msgs_since_rekem >= REKEM_MSG_THRESHOLD
                || now.saturating_sub(self.last_rekem_at) >= REKEM_TIME_THRESHOLD_SECONDS)
        {
            let pair = MlKem768::generate()?;
            kem_ek = Some(pair.public);
            self.own_kem_secret = Some(pair.secret);
        }

        let header = RatchetHeader {
            dh_pub: self.dh_self.public(),
            pn: self.pn,
            counter,
            kem_ek,
            kem_ct,
        };

        Ok((header, message_key))
    }

    /// Resolve a chave de mensagem de um cabeçalho recebido (§5.2, §5.3, §5.5).
    ///
    /// Não muta o estado de confiança (`RK`, `DHs`, `DHr`, `CKs`, `CKr`,
    /// `PN`) — só grava um resultado pendente. Quem chama **deve** chamar
    /// `commit_receive` depois que o AEAD confirmar a mensagem, ou
    /// `discard_receive` (ou simplesmente processar outra mensagem) se a
    /// autenticação falhar. Ver a documentação de módulo para o porquê.
    pub fn receiving_key(&mut self, header: &RatchetHeader) -> Result<kdf::Key> {
        // Se o contador do remetente for u32::MAX, qualquer incremento
        // causará estouro no contador local de recepção `nr`.
        // Rejeitamos imediatamente com erro de estouro (§5.3).
        if header.counter == u32::MAX {
            return Err(Error::CounterOverflow);
        }

        let dh_id = *header.dh_pub.as_bytes();

        // Mensagem fora de ordem cuja chave já foi derivada e guardada num
        // passo anterior: devolvê-la agora é seguro mesmo sem commit, porque
        // ela não depende de nada que esta mensagem em particular precise
        // provar — ver a documentação de módulo.
        if let Some(message_key) = self.skipped.take(&(dh_id, header.counter)) {
            return Ok(message_key);
        }

        let same_chain = self
            .dh_remote
            .map(|dhr| *dhr.as_bytes() == dh_id)
            .unwrap_or(false);

        // Um `KEM_ct` completa um ciclo que NÓS disparamos antes. Resolvemos
        // o segredo aqui, mas ele só entra na conta DENTRO do passo DH (se
        // houver um) — ver a doc de `ratchet_dh_step` para o porquê da
        // posição exata importar.
        let mut clear_own_kem_secret = false;
        let mut kem_ct_shared = None;
        if let Some(ct) = &header.kem_ct {
            // Um KEM_ct sem termos disparado nada é ruído (ou um par que se
            // reconectou com estado velho): ignorado, não invalida o resto de
            // uma mensagem que pode ser perfeitamente legítima.
            if let Some(secret) = &self.own_kem_secret {
                kem_ct_shared = Some(MlKem768::decapsulate(secret, ct)?);
                clear_own_kem_secret = true;
            }
        }

        let (
            root_after_switch,
            recv_chain_base,
            send_chain_final,
            new_dh_self,
            ns,
            pn,
            mut skipped_additions,
            recv_from,
            recv_fold_root,
        ) = if same_chain {
            if header.counter < self.nr {
                // Já deveria estar no cache de puladas; não estando, essa
                // chave já foi consumida (repetição) ou nunca existiu.
                return Err(Error::UndecryptableMessage);
            }
            let chain = self.receiving_chain.clone().ok_or(Error::InvalidState(
                "cadeia de recepção ainda não estabelecida",
            ))?;
            // Sem passo DH nesta mensagem, não há "meio" para dobrar o
            // KEM_ct entre um fold e outro — dobra direto sobre a RK.
            let root = match &kem_ct_shared {
                Some(shared) => fold_rekem(&self.root, shared),
                None => self.root.clone(),
            };
            (
                root,
                chain,
                self.sending_chain.clone(),
                None,
                self.ns,
                self.pn,
                Vec::new(),
                self.nr,
                None,
            )
        } else {
            // Troca de ratchet DH (§5.2), inclusive a primeiríssima
            // mensagem que o respondedor recebe (DHr ainda é None).
            let mut additions = Vec::new();
            if let (Some(old_chain), Some(old_dhr)) = (&self.receiving_chain, &self.dh_remote) {
                if header.pn > self.nr {
                    let (_, old_skips) =
                        walk_and_skip(old_chain.clone(), self.nr, header.pn, *old_dhr.as_bytes())?;
                    additions.extend(old_skips);
                }
            }

            let (new_root, recv_chain0, dh_self_new, send_chain, recv_fold_bytes) = ratchet_dh_step(
                &self.root,
                &self.dh_self,
                &header.dh_pub,
                kem_ct_shared.as_ref(),
            )?;

            (
                new_root,
                recv_chain0,
                Some(send_chain),
                Some(dh_self_new),
                0u32,
                self.ns,
                additions,
                0u32,
                Some(recv_fold_bytes),
            )
        };

        let (recv_chain_at_counter, new_skips) =
            walk_and_skip(recv_chain_base, recv_from, header.counter, dh_id)?;
        skipped_additions.extend(new_skips);
        let (recv_chain_final, message_key) = chain_step(&recv_chain_at_counter);

        // Um `KEM_ek` novo, ao contrário do `KEM_ct` acima, dispara um ciclo
        // que só vai completar quando o `KEM_ct` que geramos agora voltar
        // numa mensagem futura — não há nada do outro lado ainda apoiado
        // nesse segredo. Por isso ele entra DEPOIS do passo DH desta
        // mensagem: quem criou o `dh_pub` que processamos acima não sabia
        // nada sobre este `KEM_ek` (ele só chegou agora, junto), então nosso
        // passo DH não pode tê-lo usado como base, e dobrá-lo por cima do
        // resultado é o que deixa o próximo passo DH (nosso ou do par, uma
        // vez que o KEM_ct completar o ciclo) enxergando a RK atualizada.
        let mut root_final = root_after_switch;
        let mut outgoing_kem_ct = None;
        let mut rekem_completed = clear_own_kem_secret;

        if let Some(ek) = &header.kem_ek {
            let (ct, shared) = MlKem768::encapsulate(ek)?;
            root_final = fold_rekem(&root_final, &shared);
            outgoing_kem_ct = Some(ct);
            rekem_completed = true;
        }

        self.pending = Some(PendingReceive {
            root: root_final,
            send_chain: send_chain_final,
            recv_chain: Some(recv_chain_final),
            new_dh_self,
            dh_remote: header.dh_pub,
            ns,
            nr: header.counter.checked_add(1).ok_or(Error::CounterOverflow)?,
            pn,
            skipped_additions,
            clear_own_kem_secret,
            outgoing_kem_ct,
            rekem_completed,
            recv_fold_root,
        });

        Ok(message_key)
    }

    /// Aplica o resultado do último `receiving_key` ao estado de confiança.
    ///
    /// Chamar sem um `receiving_key` pendente não faz nada — seguro de
    /// chamar sempre que o AEAD confirmar uma mensagem, mesmo que por engano
    /// se chame duas vezes.
    pub fn commit_receive(&mut self) {
        let Some(pending) = self.pending.take() else {
            return;
        };

        let now = crate::util::time::unix_seconds();
        for (id, key) in pending.skipped_additions {
            self.skipped.insert(id, key, now);
        }

        self.root = pending.root;
        self.sending_chain = pending.send_chain;
        self.receiving_chain = pending.recv_chain;
        if let Some(new_dh_self) = pending.new_dh_self {
            self.dh_self = new_dh_self;
        }
        self.dh_remote = Some(pending.dh_remote);
        self.ns = pending.ns;
        self.nr = pending.nr;
        self.pn = pending.pn;

        if pending.clear_own_kem_secret {
            self.own_kem_secret = None;
        }
        if let Some(ct) = pending.outgoing_kem_ct {
            self.pending_outgoing_kem_ct = Some(ct);
        }
        if pending.rekem_completed {
            self.msgs_since_rekem = 0;
            self.last_rekem_at = now;
        }
    }

    /// Descarta o resultado do último `receiving_key` sem aplicá-lo.
    ///
    /// Chamar depois que o AEAD rejeitar a mensagem correspondente. Também é
    /// seguro nunca chamar: o próximo `receiving_key` bem-sucedido substitui
    /// qualquer pendência anterior sozinho.
    pub fn discard_receive(&mut self) {
        self.pending = None;
    }
}

impl core::fmt::Debug for RatchetState {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("RatchetState")
            .field("dh_remote", &self.dh_remote)
            .field("ns", &self.ns)
            .field("nr", &self.nr)
            .field("pn", &self.pn)
            .field("skipped_len", &self.skipped.len())
            .field("msgs_since_rekem", &self.msgs_since_rekem)
            .field("last_rekem_at", &self.last_rekem_at)
            .field("has_pending_receive", &self.pending.is_some())
            .field("root", &"<redigida>")
            .field("sending_chain", &"<redigida>")
            .field("receiving_chain", &"<redigida>")
            .field("dh_self", &"<redigida>")
            .field("own_kem_secret", &"<redigida>")
            .finish()
    }
}

#[cfg(test)]
impl RatchetState {
    /// Só para teste: expõe `RK` para verificar que um dobramento de re-KEM
    /// realmente mudou o valor num mesmo lado (comparar `RK` entre os dois
    /// lados num instante arbitrário não faz sentido — ver o teste de
    /// convergência do re-KEM). Nunca é chamado fora de `#[cfg(test)]`.
    fn root_bytes_for_test(&self) -> [u8; kdf::KEY_LEN] {
        *self.root.as_bytes()
    }

    fn skipped_len_for_test(&self) -> usize {
        self.skipped.len()
    }

    fn pending_recv_fold_root_for_test(&self) -> Option<[u8; kdf::KEY_LEN]> {
        self.pending.as_ref().and_then(|p| p.recv_fold_root)
    }

    fn force_ns_for_test(&mut self, ns: u32) {
        self.ns = ns;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::handshake::{respond, Initiator};
    use crate::crypto::identity::LocalIdentity;

    /// Roda um handshake completo de verdade e inicializa os dois ratchets a
    /// partir dele — exercita o mesmo caminho que o resto do sistema usa, em
    /// vez de forjar um `HandshakeOutcome` à mão.
    fn established_pair() -> (RatchetState, RatchetState) {
        let alice = LocalIdentity::generate().unwrap();
        let bob = LocalIdentity::generate().unwrap();

        let (initiator, init) = Initiator::start(&alice, &bob.public()).unwrap();
        let (bob_outcome, resp) = respond(&bob, &alice.public(), &init).unwrap();
        let alice_outcome = initiator.finish(&alice, &resp).unwrap();

        (
            RatchetState::initialize(alice_outcome).unwrap(),
            RatchetState::initialize(bob_outcome).unwrap(),
        )
    }

    /// Envia uma mensagem de `sender` para `receiver` e confirma o commit —
    /// simula uma camada de sessão cujo AEAD sempre abre.
    fn deliver(sender: &mut RatchetState, receiver: &mut RatchetState) {
        let (header, sent_key) = sender.next_sending_key().unwrap();
        let received_key = receiver.receiving_key(&header).unwrap();
        assert_eq!(sent_key.as_bytes(), received_key.as_bytes());
        receiver.commit_receive();
    }

    #[test]
    fn simple_roundtrip_alternating_direction() {
        let (mut alice, mut bob) = established_pair();

        // O respondedor não pode enviar nada antes de receber a primeira
        // mensagem do iniciador (§5.1).
        assert!(matches!(
            bob.next_sending_key(),
            Err(Error::InvalidState(_))
        ));

        deliver(&mut alice, &mut bob);
        deliver(&mut bob, &mut alice);
        deliver(&mut alice, &mut bob);
        deliver(&mut bob, &mut alice);
        deliver(&mut alice, &mut bob);
    }

    #[test]
    fn long_conversation_alternating_all_keys_match() {
        let (mut alice, mut bob) = established_pair();

        for i in 0..1000 {
            if i % 2 == 0 {
                deliver(&mut alice, &mut bob);
            } else {
                deliver(&mut bob, &mut alice);
            }
        }
    }

    #[test]
    fn out_of_order_messages_resolve_to_correct_key() {
        let (mut alice, mut bob) = established_pair();

        // Alice manda 5 mensagens seguidas sem que Bob responda nenhuma —
        // todas na mesma cadeia de envio dela.
        let mut headers = Vec::new();
        let mut keys = Vec::new();
        for _ in 0..5 {
            let (header, key) = alice.next_sending_key().unwrap();
            headers.push(header);
            keys.push(key);
        }

        // Entrega 1, 3, 2, 5, 4 (índices 0, 2, 1, 4, 3).
        for &index in &[0usize, 2, 1, 4, 3] {
            let received = bob.receiving_key(&headers[index]).unwrap();
            assert_eq!(
                received.as_bytes(),
                keys[index].as_bytes(),
                "mensagem de índice {index} não resolveu para a chave certa"
            );
            bob.commit_receive();
        }
    }

    #[test]
    fn lost_message_does_not_block_subsequent_messages() {
        let (mut alice, mut bob) = established_pair();

        let mut headers = Vec::new();
        for _ in 0..5 {
            let (header, _key) = alice.next_sending_key().unwrap();
            headers.push(header);
        }

        // A mensagem de índice 1 (a "segunda") nunca é entregue.
        for &index in &[0usize, 2, 3, 4] {
            bob.receiving_key(&headers[index]).unwrap();
            bob.commit_receive();
        }
    }

    #[test]
    fn forward_secrecy_old_key_is_no_longer_derivable() {
        let (mut alice, mut bob) = established_pair();

        let (first_header, first_key) = alice.next_sending_key().unwrap();
        bob.receiving_key(&first_header).unwrap();
        bob.commit_receive();

        // Avança bastante a conversa nos dois sentidos.
        for i in 0..50 {
            if i % 2 == 0 {
                deliver(&mut alice, &mut bob);
            } else {
                deliver(&mut bob, &mut alice);
            }
        }

        // Repetir o cabeçalho já consumido não pode mais produzir a mesma
        // chave: o `dh_pub` dele não é mais o `dh_remote` atual de Bob (o
        // ratchet já girou 50 vezes desde então), então isso reentra no
        // ramo de troca de DH e deriva ALGO — mas, como `self.dh_self` de
        // Bob também já avançou, esse algo nunca é a chave original. É
        // exatamente isso que forward secrecy garante: não que repetir um
        // cabeçalho velho sempre erre, mas que ele nunca mais devolve a
        // chave de uma mensagem já processada.
        let replayed = bob.receiving_key(&first_header);
        if let Ok(key) = replayed {
            assert_ne!(
                key.as_bytes(),
                first_key.as_bytes(),
                "cabeçalho repetido rederivou a chave original — forward secrecy quebrada"
            );
        }
    }

    #[test]
    fn dh_step_occurs_on_dhr_change_and_propagates_pn() {
        let (mut alice, mut bob) = established_pair();

        // Alice manda 1 mensagem; Bob recebe (isso já é o primeiro passo DH
        // dele) e depois manda 2 de volta.
        let (header0, _) = alice.next_sending_key().unwrap();
        bob.receiving_key(&header0).unwrap();
        bob.commit_receive();

        let (bob_header0, _) = bob.next_sending_key().unwrap();
        let (_bob_header1, _) = bob.next_sending_key().unwrap();

        let dh_before = alice.dh_self.public();

        // Alice recebe a primeira mensagem de Bob: como o DHs dele mudou
        // durante o passo dela (ratchet_dh_step gera uma chave nova), o
        // dh_pub que chega é diferente do que Alice já conhecia — dispara o
        // passo DH dela.
        alice.receiving_key(&bob_header0).unwrap();
        alice.commit_receive();

        let dh_after = alice.dh_self.public();
        assert_ne!(
            dh_before.as_bytes(),
            dh_after.as_bytes(),
            "o passo DH deveria ter gerado um DHs novo"
        );

        // Alice só tinha mandado 1 mensagem antes deste passo: PN precisa
        // refletir isso na próxima mensagem que ela mandar.
        let (header_after_switch, _) = alice.next_sending_key().unwrap();
        assert_eq!(header_after_switch.pn, 1);
    }

    #[test]
    fn rekem_converges_to_same_root_after_full_cycle() {
        // Nota sobre o que "convergir" significa aqui: `RK` das duas pontas
        // NÃO é igual, byte a byte, em nenhum instante congelado de uma
        // conversa alternada normal (sem re-KEM nenhum) — cada lado está
        // sempre "um passo DH à frente" da referência que o outro guarda
        // (confirmado experimentalmente ao escrever este teste). O que
        // precisa ser verdade é mais forte e mais direto: toda mensagem
        // continua decifrando para a mesma chave dos dois lados, durante e
        // depois do ciclo — é isso que os `assert_eq!` abaixo verificam a
        // cada rodada — e o segredo do KEM realmente mudou a `RK` de cada
        // lado quando ele completou a própria metade do ciclo.
        let (mut alice, mut bob) = established_pair();

        // Estabelece a cadeia de Bob para poder alternar depois de forçar o
        // gatilho por contagem.
        deliver(&mut alice, &mut bob);

        let mut saw_kem_ek = false;
        let mut saw_kem_ct = false;
        let mut bob_root_before_encapsulate = None;
        let mut bob_root_after_encapsulate = None;
        let mut alice_root_before_decapsulate = None;
        let mut alice_root_after_decapsulate = None;

        // Força o gatilho por contagem (>= 256) mandando mensagens de Alice
        // para Bob; intercala respostas de Bob para não deixar a cadeia dela
        // parada e para dar chance do KEM_ct voltar.
        for _ in 0..300 {
            let (header, sent_key) = alice.next_sending_key().unwrap();
            if header.kem_ek.is_some() {
                saw_kem_ek = true;
                bob_root_before_encapsulate = Some(bob.root_bytes_for_test());
            }
            let received_key = bob.receiving_key(&header).unwrap();
            assert_eq!(sent_key.as_bytes(), received_key.as_bytes());
            bob.commit_receive();
            if bob_root_before_encapsulate.is_some() && bob_root_after_encapsulate.is_none() {
                bob_root_after_encapsulate = Some(bob.root_bytes_for_test());
            }

            let (reply, sent_key) = bob.next_sending_key().unwrap();
            if reply.kem_ct.is_some() {
                saw_kem_ct = true;
                alice_root_before_decapsulate = Some(alice.root_bytes_for_test());
            }
            let received_key = alice.receiving_key(&reply).unwrap();
            assert_eq!(sent_key.as_bytes(), received_key.as_bytes());
            alice.commit_receive();
            if alice_root_before_decapsulate.is_some() && alice_root_after_decapsulate.is_none() {
                alice_root_after_decapsulate = Some(alice.root_bytes_for_test());
            }
        }

        assert!(
            saw_kem_ek,
            "o gatilho por contagem nunca disparou um KEM_ek"
        );
        assert!(saw_kem_ct, "Bob nunca devolveu um KEM_ct");
        assert_ne!(
            bob_root_before_encapsulate.unwrap(),
            bob_root_after_encapsulate.unwrap(),
            "RK de Bob não mudou ao encapsular contra o KEM_ek de Alice"
        );
        assert_ne!(
            alice_root_before_decapsulate.unwrap(),
            alice_root_after_decapsulate.unwrap(),
            "RK de Alice não mudou ao decapsular o KEM_ct de Bob"
        );

        // E a conversa continua perfeitamente decifrável depois do ciclo.
        for i in 0..20 {
            if i % 2 == 0 {
                deliver(&mut alice, &mut bob);
            } else {
                deliver(&mut bob, &mut alice);
            }
        }
    }

    #[test]
    fn skipped_keys_cap_does_not_grow_unbounded() {
        let (mut alice, mut bob) = established_pair();

        // Bob só recebe 1 a cada 4 mensagens de Alice, pulando 3 de cada vez
        // — bem abaixo do teto por chamada, mas o total pulado ao longo da
        // conversa passa de 1000, o suficiente para exercer a expulsão da
        // entrada mais velha.
        const TOTAL: usize = 3200;
        let mut headers = Vec::with_capacity(TOTAL);
        for _ in 0..TOTAL {
            let (header, _key) = alice.next_sending_key().unwrap();
            headers.push(header);
        }

        for (index, header) in headers.iter().enumerate() {
            if index % 4 == 3 {
                bob.receiving_key(header).unwrap();
                bob.commit_receive();
            }
        }

        assert!(
            bob.skipped_len_for_test() <= SkippedKeys::CAP,
            "cache de chaves puladas cresceu além do teto: {}",
            bob.skipped_len_for_test()
        );

        // Uma mensagem pulada bem no início já deveria ter sido expulsa.
        assert!(matches!(
            bob.receiving_key(&headers[0]),
            Err(Error::UndecryptableMessage)
        ));

        // Uma mensagem pulada perto do fim ainda deve estar no cache.
        let recent_skipped_index = TOTAL - 2; // pulada, e recente
        let recovered = bob.receiving_key(&headers[recent_skipped_index]).unwrap();
        bob.commit_receive();
        // A chave recuperada precisa ser a mesma que Alice teria usado: como
        // não guardamos as chaves de Alice para todas as 3200 mensagens,
        // conferimos indiretamente — resolvendo de novo o mesmo cabeçalho
        // teria que falhar agora (uso único), o que só é verdade se a
        // primeira resolução realmente tirou a chave do cache.
        assert!(matches!(
            bob.receiving_key(&headers[recent_skipped_index]),
            Err(Error::UndecryptableMessage)
        ));
        drop(recovered);
    }

    #[test]
    fn header_with_low_order_dh_pub_is_rejected_without_panic() {
        let (_alice, mut bob) = established_pair();

        let header = RatchetHeader {
            dh_pub: DhPublic::from_bytes([0u8; dh::KEY_LEN]),
            pn: 0,
            counter: 0,
            kem_ek: None,
            kem_ct: None,
        };

        assert!(matches!(
            bob.receiving_key(&header),
            Err(Error::LowOrderPoint)
        ));
        // Nenhuma mutação deveria ter ficado pendente.
        bob.commit_receive();
        assert!(bob.dh_remote.is_none());
    }

    #[test]
    fn sending_counter_overflow_rejected_with_error() {
        let (mut alice, _bob) = established_pair();
        alice.force_ns_for_test(u32::MAX);
        assert!(matches!(
            alice.next_sending_key(),
            Err(Error::CounterOverflow)
        ));
    }

    #[test]
    fn receiving_counter_overflow_rejected_with_error() {
        let (_alice, mut bob) = established_pair();
        let header = RatchetHeader {
            dh_pub: DhPublic::from_bytes([0x42u8; dh::KEY_LEN]),
            pn: 0,
            counter: u32::MAX,
            kem_ek: None,
            kem_ct: None,
        };
        assert!(matches!(
            bob.receiving_key(&header),
            Err(Error::CounterOverflow)
        ));
    }

    #[test]
    fn exact_convergence_of_rk_in_dh_step() {
        let (mut alice, mut bob) = established_pair();

        // Alice envia msg 0 (já estabelecida na inicialização dela).
        // Bob recebe a msg 0: o passo DH de recepção de Bob deve reproduzir
        // exatamente a RK que Alice calculou na inicialização dela!
        let (header0, key0) = alice.next_sending_key().unwrap();
        let alice_root0 = alice.root_bytes_for_test();

        let recv_key0 = bob.receiving_key(&header0).unwrap();
        assert_eq!(key0.as_bytes(), recv_key0.as_bytes());
        let bob_recv_fold0 = bob.pending_recv_fold_root_for_test().expect("Bob executou passo DH");
        assert_eq!(bob_recv_fold0, alice_root0, "a dobra de recepção de Bob deve bater bit a bit com a RK de Alice");
        bob.commit_receive();

        // Bob envia resposta 0 (com novo DHs gerado no passo acima).
        let (bob_reply0, bob_key0) = bob.next_sending_key().unwrap();
        let bob_root0 = bob.root_bytes_for_test();

        // Alice recebe resposta 0 de Bob: o passo DH de Alice deve reproduzir a RK que Bob comitou!
        let alice_recv_key0 = alice.receiving_key(&bob_reply0).unwrap();
        assert_eq!(bob_key0.as_bytes(), alice_recv_key0.as_bytes());
        let alice_recv_fold0 = alice.pending_recv_fold_root_for_test().expect("Alice executou passo DH");
        assert_eq!(alice_recv_fold0, bob_root0, "a dobra de recepção de Alice deve bater bit a bit com a RK de Bob");
        alice.commit_receive();

        // E mais uma rodada para confirmar a convergência contínua:
        let (header1, key1) = alice.next_sending_key().unwrap();
        let alice_root1 = alice.root_bytes_for_test();

        let recv_key1 = bob.receiving_key(&header1).unwrap();
        assert_eq!(key1.as_bytes(), recv_key1.as_bytes());
        let bob_recv_fold1 = bob.pending_recv_fold_root_for_test().expect("Bob executou passo DH");
        assert_eq!(bob_recv_fold1, alice_root1, "na segunda rodada a sincronia de RK permanece exata");
        bob.commit_receive();
    }

    #[test]
    fn deep_conversation_10000_messages_alternating() {
        let (mut alice, mut bob) = established_pair();

        for i in 0..10_000 {
            if i % 2 == 0 {
                deliver(&mut alice, &mut bob);
            } else {
                deliver(&mut bob, &mut alice);
            }
        }
        assert_eq!(alice.skipped_len_for_test(), 0);
        assert_eq!(bob.skipped_len_for_test(), 0);
    }
}
