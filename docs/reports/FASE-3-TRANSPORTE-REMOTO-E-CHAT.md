# Fase 3 — transporte remoto via WebRTC e chat de texto ponta a ponta

| Campo | Valor |
|-------|-------|
| **Status** | ❌ Não iniciada — as primitivas existem, a camada que as costura e todo o transporte não |
| **Cobertura** | ~30 % (2 de 7 tarefas), contando só o que `crypto/` e `wire/` já entregam |
| **Esforço** | 7–10 dias-dev no escopo completo; 4,5–6 d no mínimo viável [modelado] |
| **Depende de** | Fase 2 completa (contato pareado e persistido) · Fase 1 fechada (ratchet) |
| **Fecha requisito** | É o primeiro entregável executável do projeto — a fatia vertical que prova o desenho inteiro |

---

## 1. Estado atual — evidências

### O que existe

O envelope de transporte está completo em `rust/src/wire/` (1.015 linhas em 7 arquivos), com o
seam deliberado descrito em `wire/mod.rs:10-21`: `wire/` produz bytes e não conhece chave nenhuma.
`envelope.rs:64-68` expõe a convenção do AAD como função, em vez de deixar cada chamador
reconstruir `counter.to_be_bytes()` por conta própria.

`crypto/handshake.rs` (551 linhas) entrega o AKE híbrido deniável, e `crypto/aead.rs` (281 linhas) as
duas cifras, validada contra o vetor do RFC 8439 §2.8.2.

### O que não existe

**Nenhuma camada de sessão.** `wire/mod.rs:10-13` descreve uma camada `session` que encadeia
ratchet → `wire` → `aead`, e ela não existe:

```bash
ls rust/src/
# → crypto  lib.rs  util  wire      (sem session/, sem ffi/, sem store/)
```

Nenhuma dependência de transporte:

```bash
grep -n "flutter_webrtc\|mqtt" pubspec.yaml
# → 0 resultados
```

A derivação de tópico de sinalização da spec §8.1 também não foi implementada — o contexto
`viska-signaling-v1` está declarado em `crypto/kdf.rs`, mas nenhuma função o usa.

### ⚠️ Segundo defeito de planejamento: a camada `session` não pertence a nenhuma fase

O roteiro distribuiu handshake, ratchet, AEAD e envelope entre as Fases 1 e 3, mas o código que os
compõe em uma sessão viva — máquina de estados, quem inicia, o que fazer quando o AEAD falha — não
foi atribuído a ninguém. É o maior item não contabilizado do projeto, estimado em 2–3 d.

---

## 2. As seis decisões de design

### 2.1 Onde a ordem de papéis é imposta

`crypto/handshake.rs` não verifica qual lado deve iniciar: a documentação do módulo declara isso
como responsabilidade de quem chama. A revisão do handshake confirmou que o protocolo **falha
fechado** se os papéis divergirem — as raízes simplesmente não batem — mas dois aparelhos que
iniciem ao mesmo tempo nunca convergem.

`PublicIdentity::is_before` (`crypto/identity.rs`) já existe. A camada `session` **deve** chamá-lo
antes de decidir entre `Initiator::start` e `respond`. Sem isso, o handshake simultâneo é um *bug*
de conectividade intermitente, do tipo que só aparece em campo.

### 2.2 O DataChannel precisa de dois modos, não um

| Opção | O que é | Custo | Veredito |
|---|---|---|---|
| Um canal confiável e ordenado | Um `RTCDataChannel` para tudo | Simples, mas paga retransmissão do SCTP sobre símbolos RaptorQ na Fase 4 | Rejeitada: D6 explica por que isso duplica trabalho |
| Dois canais | Um confiável para controle e texto, um não confiável e não ordenado para arquivos | Mais estado a gerenciar | **Recomendada** — cada tipo de tráfego no canal que o serve |

Decidir isto na Fase 3, e não na 4, evita reabrir a negociação SDP depois.

### 2.3 O socket MQTT fecha assim que o DataChannel abre

Spec §8.2. É o que limita a janela em que o broker público observa o par. A implementação precisa
tratar o caso em que o DataChannel cai depois: reconectar ao broker exige derivar o tópico da época
**corrente**, não reusar o anterior.

### 2.4 Rotação de época com janela de três

Spec §8.1 e `util/time.rs`, onde `epoch_window()` já devolve `[e-1, e, e+1]`. O assinante inscreve as
três. Sem isso, dois celulares com relógios poucos minutos dessincronizados não se encontram perto
da virada da hora — e o sintoma seria "o app não conecta às vezes".

### 2.5 O jitter é amostrado no Rust e dormido no Dart

`wire/jitter.rs` devolve uma `Duration` e não dorme, porque só a camada de transporte sabe qual
*runtime* assíncrono está em uso. A camada Dart precisa honrar isso de fato — ignorar a duração
devolvida desativa silenciosamente a mitigação da spec §6.5.

### 2.6 O que não fazer

**Não adicionar TURN.** A spec não prevê relay, e um servidor TURN é exatamente o tipo de
infraestrutura que o §1.1 rejeita. A consequência é que uma fração das conexões entre NATs
simétricos não fecha; a UI deve falhar de forma explícita e sugerir o modo local, em vez de tentar
indefinidamente.

---

## 3. Plano de implementação

| Fase | Conteúdo | Esforço [modelado] |
|---|---|---|
| **F0** | `rust/src/session/`: máquina de estados, escolha de papel por `is_before`, encadeamento ratchet → `wire` → `aead`, política de erro do AEAD | 2–3 d |
| **F1** | `rust/src/signaling/`: derivação de tópico por época, cifragem do SDP com `seal_xchacha`, padding para 1.024 B | 1 d |
| **F2** | Superfície FFI de sessão e mensagem, sobre o `ffi/` criado na Fase 2 | 0,5–1 d |
| **F3** | `lib/src/transport/webrtc_transport.dart`: `flutter_webrtc`, STUN público, dois DataChannels | 1,5–2 d |
| **F4** | `lib/src/transport/signaling/mqtt.dart`: publicação e assinatura nos tópicos opacos, desconexão ao abrir o canal | 1 d |
| **F5** | `P2PTransportRouter` com um único transporte por enquanto — a interface que a Fase 6 preenche | 0,5 d |
| **F6** | Tela de chat, fila de envio, persistência das mensagens no banco | 1,5–2 d |

**Mínimo viável** (dois aparelhos trocam texto): F0 + F1 + F2 + F3 + F4 ≈ 6–8 d.
**Escopo completo:** F0–F6 ≈ 8–10,5 d.

---

## 4. Armadilhas

| Armadilha | Mitigação |
|---|---|
| `flutter_webrtc` entrega o DataChannel em *callback*, e o Rust é síncrono | Fila de saída no Dart; nunca chamar o FFI de dentro do *callback* de rede. |
| Brokers públicos aplicam limite de taxa e derrubam clientes | Interface de sinalização plugável desde o início (spec §8.3), com MQTT, Nostr e troca manual. |
| `retain = true` por engano deixa o SDP cifrado no broker indefinidamente | Spec §8.2 exige `retain = false`; travar isso em teste, não em revisão. |
| Candidatos ICE vazam IPs locais e públicos no payload | O payload é cifrado, mas o volume e o momento não. Já aceito e documentado em D12. |
| O contador do envelope é `u32` e o nonce deriva dele | A camada `session` precisa garantir que a cadeia rotacione antes do estouro. Não há hoje nenhum teste que force esse limite. |

---

## 5. Verificação

**Automatizável no host (`cargo test`):**

- [ ] `session`: dois pares em processo completam handshake e trocam 1.000 mensagens alternadas —
      guarda que o encadeamento ratchet/wire/aead está correto sem depender de rede.
- [ ] `session`: handshake simultâneo (os dois chamam `start`) converge para uma única sessão —
      guarda a regra de papéis da decisão 2.1.
- [ ] `signaling`: o tópico derivado muda entre épocas e é idêntico nos dois lados dentro da mesma.

**Automatizável no host (`flutter test`):**

- [ ] O `P2PTransportRouter` reporta falha explícita quando o ICE não fecha, em vez de pendurar.

**Só com dois aparelhos em redes diferentes (não verificado até rodar):**

- [ ] Troca de texto ponta a ponta entre redes distintas.
- [ ] `tcpdump` no broker mostra apenas tópicos opacos e payloads de 1.024 B — guarda §6.3 e §8.
- [ ] O socket MQTT fecha depois que o DataChannel abre.
- [ ] Entre NATs simétricos, a falha é explícita e sugere o modo local.

---

## 6. Riscos

1. **A camada `session` é o item mais subestimado do projeto.** Ela concentra as decisões difíceis —
   papéis, reentrância, o que fazer com o estado do ratchet quando o AEAD falha — e não estava
   orçada em nenhuma fase.

2. **NAT simétrico não tem solução dentro das premissas.** Sem TURN, uma fração das conexões
   remotas nunca fecha, e isso é uma limitação de produto, não um *bug* a corrigir.

3. **A dependência de brokers públicos é frágil por natureza.** `broker.emqx.io` e
   `test.mosquitto.org` podem cair, limitar taxa ou banir sem aviso — e o modo manual de troca de
   SDP é a única garantia real de que o app funciona sem terceiros.

---

## 7. Arquivos tocados

| Arquivo | Mudança |
|---|---|
| `rust/src/session/` | **novo** — máquina de estados da sessão |
| `rust/src/signaling/` | **novo** — tópicos por época, cifragem do SDP |
| `rust/src/ffi/session.rs` | **novo** — superfície de sessão e mensagem |
| `pubspec.yaml` | `flutter_webrtc`, `mqtt_client` |
| `lib/src/transport/` | **novo** — router, WebRTC, sinalização |
| `lib/src/features/chat/` | **novo** — tela, fila de envio, estado |
| `docs/protocol.md` | §8 revisado se a negociação de dois DataChannels mudar o SDP |

---

> Nenhum item deste relatório foi executado, e nenhum dos dois aparelhos necessários para a
> verificação de ponta a ponta está disponível nesta máquina. A análise vem da leitura do código em
> *working tree* não versionado; a validação está listada na seção 5 como pendente.
