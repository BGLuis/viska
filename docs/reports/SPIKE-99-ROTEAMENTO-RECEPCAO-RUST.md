# Roteamento de recepção e handshake — migração do restante da máquina de estados para o Rust

| Campo | Valor |
|---|---|
| **Status** | 🟡 Parcial — `Core::receive_incoming` e `Core::connect_signal` existem (#78), mas recibos, drenagem pós-pacote, timer de renovação e gatilhos de conexão continuam no Dart |
| **Cobertura** | ~45 % (roteamento por tamanho, `REOPEN` e candidatas no Rust; orquestração pós-pacote e gatilhos no Dart) |
| **Esforço** | 2,5–3,5 dias-dev para o escopo completo; 1,5–2 d para o mínimo viável |
| **Depende de** | PR #106 (`feat/78`, commit `8dca56e`, ancestral do HEAD `6726106` de `develop`) |
| **Relacionado** | Issue #99 · Issue #96 (reconexão sem drenagem) · D27 · D29 |

---

## 1. Estado atual — evidências

A implementação da #78 (PR #106, commit `8dca56e`) consolidou a decifragem, o reconhecimento por
tamanho de `INIT`/`RESP`/`REOPEN` e as sessões candidatas em `Core::receive_incoming`
(`rust/src/ffi/session.rs:291-333`) e `Core::connect_signal` (`:343-355`). No entanto, o lado Dart
continua hospedando sete decisões da máquina de estados de sessão e da fila de saída.

### O que existe

1. **Pós-processamento de `receiveIncoming` no Dart**
   (`lib/src/transport/message_reception_service.dart:396-434`): após `Core.receiveIncoming`
   devolver `IncomingResultDto` (`reply` + `message`), `_handleIncomingRaw` inspeciona
   `incoming?.isTyping` (`:417`) para emitir `TypingIndicatorEvent` (`:418`) ou
   `incoming?.messageId != null` (`:421`) para chamar `_sendReceipt` (`:422`), disparando uma
   **segunda chamada FFI** (`_core.sealOutgoingReceipt` em `:438-441`) — e passando `messageId`
   local em vez de `global_id`, apesar de `rust/logic/src/store/messages.rs:181,926-958` extrair e
   priorizar `global_id` ao marcar entrega.
2. **Drenagem incondicional pós-pacote** (`message_reception_service.dart:426-430`): todo pacote
   recebido em `_handleIncomingRaw` termina com `await _flushPending(contactId)` (`:430`) —
   inclusive falhas de AEAD, `FILE_FEEDBACK`, `CONTROL_SUITES` ou `REOPEN` que bloqueia a fila. O
   único motivo é cobrir o momento em que o respondedor ganha cadeia de envio ao decifrar o
   primeiro pacote do iniciador (`docs/protocol.md` §5.1), sem haver transição de `SessionStateKind`
   em `SessionEvents` (`rust/src/session_events.rs:77-84`).
3. **Máquina de estados de drenagem e timer de retenção**
   (`message_reception_service.dart:225-270`): `_handleSessionEvent` mantém um espelho
   `_sessionStates` (`:181`) para computar bordas (`!wasEstablished`, `renewed`, `holdEnded`,
   `:235-247`) e agendar `_renewalTimers` (`defaultRenewalHold = 31 s` em `:268`, duplicando
   `CANDIDATE_TIMEOUT_SECS = 30` de `rust/logic/src/session/renewal.rs:31`). Quando o prazo vence,
   o timer chama `_flushPending` (`:261`), cuja saída aciona `PublishOnExit`
   (`rust/src/ffi/session.rs:536`), publica `renewing: false`, e só então `_handleSessionEvent`
   dispara `resumeTransfers` (`message_reception_service.dart:252`).
4. **Rollback em duas fases da fila de saída** (`message_reception_service.dart:715-752` e
   `lib/src/features/chat/chat_controller.dart:891-922`): `Core::flush_pending`
   (`rust/src/ffi/session.rs:530-575`) marca mensagens `Sending` antes de devolver os bytes; o Dart
   envia via `_router.sendToContact` e chama `markMessageSent` (`:731`) ou `requeueMessage`
   (`:727,734`). O mesmo padrão se repete em `resendUnknown` (`:710-713`).
5. **Gatilhos de anúncio e retomada na ligação do canal**
   (`message_reception_service.dart:315-369`): `ensureListening` decide publicar
   `_publishConnectSignal` (`:364`) e `resumeTransfers` (`:368`) quando um transporte novo entra em
   `_boundTransports` — sem chamar `_flushPending` se a sessão já estava `Established` (lacuna da
   issue #96). `ChatController.reconnectSession` (`chat_controller.dart:845-869`) também encadeia
   `resetSession` (`:851`) + `connectSignal` (`:852`) + `sendToContact` (`:855`).
6. **Inferência de papel nos quatro transportes** via `ensureSession().outgoingHandshake != null`:
   `webrtc_p2p_transport.dart:99-100`, `lan_transport.dart:213-214`,
   `multipeer_transport.dart:101-102` e `wifi_aware_transport.dart:118-119`. Se a sessão já estiver
   `Established` (ex.: estabelecida por WebRTC antes de a LAN conectar), `outgoingHandshake` é
   `null` (`rust/logic/src/session/mod.rs:350`) para ambos os pares.
7. **Arbitragem de saúde da sessão na UI** (`lib/src/features/chat/session_health.dart:9-55` e
   `chat_controller.dart:145-149,386-395`): combina `sessionStateFor` (stream) com `ensureSession`
   usando `_streamed`.

### O que não existe

O método `_tryPublishOutgoingHandshake`, citado na descrição original da issue #99, já foi removido
no commit `48a5547` (PR #106) e substituído por `_publishConnectSignal`
(`message_reception_service.dart:695-704`):

```bash
rg -n "_tryPublishOutgoingHandshake"
# → 0 resultados
```

### Precedentes no código

- `rust/src/ffi/session.rs:1-16` — define o núcleo Rust **síncrono por desenho** (sem runtime
  assíncrono em `rust/Cargo.toml:1-55` nem em `rust/logic/Cargo.toml:1-51`) e restringe `StreamSink`
  ao que só o Rust descobre sozinho. **Reutilizar** a fronteira síncrona com retorno de efeitos em
  vez de introduzir callbacks `DartFnFuture` [F1].
- `rust/src/ffi/session.rs:291-333` (`receive_incoming`) e `rust/src/ffi/types.rs:105-112`
  (`IncomingResultDto`) — já devolve `reply: Option<Vec<u8>>` para o Dart despachar no transporte.
  **Reutilizar** e estender esse padrão para uma lista ordenada de pacotes de saída e intenções.
- `rust/src/expiry.rs:65-118` (D29, `docs/deviations.md:537-561`) — usa `std::thread` + `Condvar`
  para expiração de chaves efêmeras, mas `deviations.md:553` registra explicitamente que ela é *"a
  única thread própria do núcleo"*. **Divergir** de criar uma segunda thread só para o prazo de
  `30 s` da candidata, expondo o prazo restante no evento/DTO para o Dart disparar um timer simples.

### Não-objetivos

- Mover I/O de rede (`P2PTransportRouter`, `flutter_webrtc`, sockets LAN, BLE/Wi-Fi
  Aware/Multipeer) ou `JitteredOutbox` (`lib/src/transport/outbox.dart:25-88`) para o Rust.
- Eliminar `markMessageSent` / `requeueMessage`: a entrega no transporte continua assíncrona no Dart
  após a cifragem no Rust.
- Migrar o bombeamento de chunks de arquivo (`_pumpOutgoing`), a cadência de `FILE_FEEDBACK`
  (`500 ms`) ou o `TransferForegroundService` (`message_reception_service.dart:450-602,857-913`).

---

## 2. As 4 decisões de design

### 2.1 Modelo da fronteira FFI: lote síncrono de ações × callbacks/threads

| Opção | O que é | Custo [modelado] | Base | Veredicto |
|---|---|---|---|---|
| `DartFn` callbacks a partir do Rust | Rust chama `_router.sendToContact` via `DartFnFuture` | 4–6 d | [F1] | Rejeitada: exige `async` no Rust e traz risco de reentrância sob `Mutex<sessions>` |
| `StreamSink<OutboundPacketDto>` dedicado | Rust empurra pacotes cifrados num novo stream | 3–4 d | [F2], `session.rs:10-16` | Rejeitada: perde correlação síncrona por chamada para `requeueMessage` |
| Lote síncrono de ações (`SessionActionsDto` / `IncomingResultDto`) | Rust devolve pacotes selados, flag de retomada e prazo em cada chamada | 2,5–3,5 d | `session.rs:291-333`, [F2] | **Recomendada** |

Na opção recomendada, toda transição provocada por pacote recebido, conexão de canal, expiração da
candidata ou reset de sessão retorna um único DTO contendo: (a) `outbound: Vec<OutboundPacketDto>`
com `{ bytes: Vec<u8>, message_id: Option<i64> }` já ordenado (sinal/handshake/suites → recibo →
mensagens pendentes), (b) `resume_transfers: bool`, (c) `typing: bool` quando aplicável, e (d)
`renewal_retry_after_ms: Option<u64>`.

### 2.2 Recibos (`MSG_RECEIPT`) e drenagem pós-pacote no Rust

- **Recibos dentro de `handle_incoming_plaintext` (`rust/src/ffi/session.rs:385-455`):** ao
  persistir `PacketType::MsgText` não-reação (`:409-424`), o Rust sela `MSG_RECEIPT` na própria
  sessão (usando `global_id` quando presente, ou `message_id.to_string()`, corrigindo a omissão do
  `global_id` em `message_reception_service.dart:422`) e o inclui em `outbound`. Se o pacote era o
  primeiro do iniciador, `Session::accept` (`renewal.rs:356-371`, via `Session::receive` em
  `renewal.rs:169-195`) acabou de criar a cadeia de envio do respondedor e selar `CONTROL_SUITES` —
  ambos saem juntos na mesma chamada FFI, e `Core::seal_outgoing_receipt`
  (`rust/src/ffi/session.rs:458-484`) deixa a API pública do FFI.
- **Drenagem orientada por transição interna:** `rust/logic/src/session/mod.rs` expõe
  `can_send_now(&self) -> bool` (sessão `Established`, não `is_renewing()`, não `needs_rehandshake`,
  e com cadeia de envio inicializada). `Core::receive_incoming` compara `can_send_now` antes e
  depois de `session.receive` (ou verifica promoção/desbloqueio) e só executa a lógica interna de
  `flush_pending` quando a sessão passa a poder enviar ou quando ainda há fila destravada sem
  duplicar envio (`Sending` já impede re-leitura). Assim, `_handleIncomingRaw` deixa de chamar
  `_flushPending` a cada pacote (`message_reception_service.dart:430`).

### 2.3 Ciclo de canal, papel ativo nos transportes e timer de renovação

- **Conexão de canal e reset:** substituir `Core::connect_signal` por
  `Core::on_channel_connected(peer_device_id) -> SessionActionsDto`, que devolve o sinal de
  conexão (`INIT` ou `REOPEN`), drena `pending` se `can_send_now()` for verdadeiro (resolvendo
  estruturalmente a lacuna da #96) e informa `resume_transfers: can_send_now()`.
  `Core::reset_session` pode devolver o mesmo `SessionActionsDto` com o sinal inicial, removendo a
  dupla chamada `resetSession` + `connectSignal` em `ChatController.reconnectSession`
  (`chat_controller.dart:851-852`).
- **Papel ativo nos 4 transportes:** adicionar `is_initiator: bool` (derivado de
  `LocalIdentity::public().is_before(&peer)` em `session/mod.rs:197`) a `SessionStatusDto`
  (`rust/src/ffi/types.rs:65-79`) ou expor `Core::is_initiator(peer)`. Os quatro transportes deixam
  de usar `status.outgoingHandshake != null` como proxy de papel (`webrtc_p2p_transport.dart:100`,
  `lan_transport.dart:214`, `multipeer_transport.dart:102`, `wifi_aware_transport.dart:119`).
- **Prazo da candidata (`30 s`):** em vez de duplicar `31 s` no Dart (`defaultRenewalHold`,
  `message_reception_service.dart:268`), `SessionStateEventDto` (ou `SessionActionsDto`) informa
  `renewal_retry_after_ms: Option<u64>`. O Dart agenda um único `Timer` burro que chama
  `Core::drain_pending(peer)` quando vence, e o Rust devolve `outbound` + `resume_transfers` sem o
  Dart computar `wasEstablished`/`holdEnded`/`renewed` nem disparar drenagem em
  `_handleSessionEvent`. `_sessionStates` e `sessionStateFor` (`message_reception_service.dart:181,223`)
  permanecem apenas como cache passivo do último evento para `ChatController.initialize()`
  (`chat_controller.dart:386`) e seus testes (`message_reception_service_test.dart:484,1072,1150`).

### 2.4 O que não fazer

- Não criar um segundo runtime assíncrono no Rust nem converter `Core` para `async fn` só para
  chamar `_router.sendToContact` de dentro do Rust: a inversão de controle via retorno de
  `OutboundPacketDto` dá o mesmo encapsulamento da máquina de estados sem quebrar a arquitetura
  síncrona documentada em `rust/src/ffi/session.rs:1-8`.
- Não remover o rollback de `MessageReceptionService._flushPending` (`markMessageSent` /
  `requeueMessage`), pois falhas de `RTCDataChannel.send` ou socket TCP continuam ocorrendo no Dart
  após a cifragem.

---

## 3. Plano de implementação

1. **Predicado de envio e suporte de recibo em `rust/logic` e `rust/src/ffi` (1–1,5 d)** — expor
   `Session::can_send_now` em `rust/logic/src/session/mod.rs` (sem alterar criptografia nem
   protocolo de fio); introduzir `OutboundPacketDto` e `SessionActionsDto` em
   `rust/src/ffi/types.rs`; mover selagem de `MSG_RECEIPT` (com `global_id` preferencial) e
   drenagem condicional para dentro de `Core::receive_incoming`, adicionar `on_channel_connected` e
   `is_initiator`, e atualizar `Core::reset_session` e `Core::resend_unknown_message`.
2. **Regeneração da ponte FFI e adaptação dos 4 transportes (0,5 d)** — rodar
   `flutter_rust_bridge_codegen generate` para `rust/src/frb_generated.rs` e
   `lib/src/rust/frb_generated*.dart`; migrar os 4 transportes para `status.isInitiator`.
3. **Simplificação do `MessageReceptionService` e `ChatController` (0,5–1 d)** — remover de
   `message_reception_service.dart` o cálculo de `wasEstablished`/`renewed`/`holdEnded` em
   `_handleSessionEvent` (mantendo `_sessionStates`/`sessionStateFor` apenas como cache passivo
   para `ChatController.initialize()`), `_sendReceipt`, a chamada incondicional a `_flushPending` em
   `_handleIncomingRaw`, e a constante duplicada `defaultRenewalHold = 31 s`; manter apenas um
   despachante genérico de `SessionActionsDto` (`_dispatchActions`) com rollback via
   `markMessageSent`/`requeueMessage`.
4. **Atualização de testes e dublês em Rust e Dart (0,5–1 d)** — atualizar `rust/src/test_support.rs`,
   os testes de `rust/src/ffi/session.rs` e `core.rs`, e os dublês `implements Core` afetados em
   `test/`.

**Mínimo viável** (elimina decisões pós-pacote e recibos no Dart sem mexer nos 4 transportes nem
no `resetSession`): etapas 1 (sem `is_initiator`) + 2 + 3 parcial ≈ **1,5–2 d**.
**Escopo completo:** etapas 1–4 ≈ **2,5–3,5 d** (estimativa `[modelado]` pela leitura dos
módulos e contagem dos 24 dublês `implements Core` em `test/`).

A ordem importa: estabilizar os DTOs FFI na etapa 1 antes do codegen evita regenerar `frb_generated`
duas vezes e permite validar toda a máquina de estados em `cargo test` antes de tocar no Dart.

---

## 4. Armadilhas

| Armadilha | Mitigação |
|---|---|
| Ordem dos pacotes em `outbound`: enviar `MSG_RECEIPT` ou `pending` antes de `CONTROL_SUITES` ou `RESP` | Ordenar explicitamente no Rust: 1º `reply` de protocolo (`RESP`/`INIT`/`REOPEN`/`CONTROL_SUITES`), 2º `MSG_RECEIPT`, 3º `pending` em ordem crescente de `id` |
| Lock `self.sessions` segurado enquanto `Store` escreve `Sending` e `MessageEvents` emite | Manter a regra de `rust/src/ffi/core.rs:76-78`: não segurar conexão do banco nem trava de `sessions` ao emitir `MessageEvents`/`SessionEvents` (dropar `sessions` ou usar helpers sob ordem fixa de travas) |
| Falha no 1º pacote de `outbound` após `flush_pending` marcar lote inteiro como `Sending` | Preservar `message_id: Option<i64>` em `OutboundPacketDto`; no Dart, ao falhar envio do índice `i`, chamar `requeueMessage` apenas para itens onde `messageId != null` em `i..` (`message_reception_service.dart:726-736`) |
| `handle_incoming_plaintext` selar recibo antes da cadeia de envio existir ou durante `is_renewing()` | Chamar a selagem de recibo só depois de `session.receive` (onde `accept` já ocorreu) e ignorar silenciosamente `Err` como faz `seal_outgoing_receipt` hoje (`rust/src/ffi/session.rs:478`), pois recibos não têm fila (`docs/protocol.md:880-882`) |
| Relógio do sistema voltar para trás ou app suspender durante os `30 s` de `CANDIDATE_TIMEOUT_SECS` | Manter `within` (`rust/logic/src/session/renewal.rs:41-43`) e chamar `drain_pending` no `handleAppResumed` se houver timer pendente |
| Quebra silenciosa nos dublês `implements Core` que hoje emulam roteamento no Dart | Remover os ganchos falsos `feedHandshake`/`decryptIncoming` de `test/transport/message_reception_service_test.dart:117-185` e `test/features/chat/chat_controller_test.dart:154-199,282-289` |

---

## 5. Verificação

**Automatizável no host (`env -u RANLIB cargo test --workspace` dentro de `rust/`):**
- [ ] `rust/src/ffi/session.rs`: respondedor com texto `pending` recebendo o primeiro `MsgText` do
      iniciador devolve numa única chamada `receive_incoming` o `CONTROL_SUITES`, o `MSG_RECEIPT` e
      os textos `pending` cifrados — guarda decisões 2.1 e 2.2.
- [ ] `rust/src/ffi/session.rs`: `MSG_RECEIPT` emitido pelo Rust usa `global_id` quando presente no
      JSON e marca `Delivered` no emissor mesmo quando os `id`s locais do SQLite divergem — guarda
      decisão 2.2 e `rust/logic/src/store/messages.rs:926-958`.
- [ ] `rust/src/ffi/session.rs`: `receive_incoming` com envelope adulterado (falha AEAD) devolve
      `outbound` vazio e não drena a fila — guarda decisão 2.2.
- [ ] `rust/src/ffi/session.rs`: `on_channel_connected` com sessão `Established` drena `pending` e
      sinaliza `resume_transfers: true`; em `Handshaking` devolve `INIT`/`REOPEN` — guarda decisão
      2.3 e cobre lacuna da #96.
- [ ] `rust/src/ffi/session.rs`: `SessionStatusDto.is_initiator` coincide com `is_before` mesmo após
      a sessão atingir `Established` — guarda decisão 2.3.

**Automatizável no host (`flutter test` e `flutter analyze` na raiz):**
- [ ] `test/transport/message_reception_service_test.dart`: falha de `sendToContact` no 2º item de
      `outbound` chama `markMessageSent` só no 1º e `requeueMessage` apenas nos itens com
      `messageId != null` do 2º em diante (sem requeue em `reply`/`MSG_RECEIPT`) — guarda armadilha 3.
- [ ] `test/transport/message_reception_service_test.dart`: timer de renovação usa o prazo
      fornecido pelo Rust e chama `drainPending` ao expirar — guarda decisão 2.3.
- [ ] `test/features/chat/chat_controller_test.dart`, `test/transport/*_transport_test.dart` e demais
      arquivos em `test/transport/`, `test/discovery/` e `test/features/` (`24` dublês
      `implements Core`) compilam e passam após regeneração FRB `2.13.0` [F2].

---

## 6. Riscos

1. **Retorno de investimento moderado em relação ao esforço (2,5–3,5 d).** O núcleo criptográfico e o
   roteamento de risco alto (`INIT`/`RESP`/`REOPEN`/candidatas) **já** foram migrados na #78. O que
   sobrou no Dart é sobretudo orquestração de efeitos e dois desvios práticos (segunda chamada FFI
   para recibo com ID errado e drenagem incondicional em cada pacote); portanto, a migração reduz
   acoplamento e corrige esses dois pontos, mas não elimina a fronteira assíncrona do transporte.
2. **Efeito cascata em testes Dart.** Alterar `IncomingResultDto`, `SessionStatusDto` ou remover
   `sealOutgoingReceipt` toca diretamente em 8 arquivos de teste que instanciam `SessionStatusDto` /
   `IncomingResultDto` e exige atualizar `message_reception_service_test.dart` (`1.573` linhas) e
   `chat_controller_test.dart` (`2.450` linhas), que hoje emulam `feedHandshake`/`decryptIncoming`
   nos próprios dublês.
3. **Acoplamento com outras issues abertas.** A issue #96 (drenagem na reconexão de transporte)
   mexe exatamente em `ensureListening` e `_connectionSubs` de `message_reception_service.dart:315-369`;
   se for corrigida antes, parte de `on_channel_connected` precisa preservar o comportamento dela.

---

## 7. Arquivos tocados

| Arquivo | Mudança |
|---|---|
| `rust/logic/src/session/mod.rs` | Expor `can_send_now` e `is_initiator` em `Session` |
| `rust/src/ffi/types.rs` | Adicionar `OutboundPacketDto`, `SessionActionsDto`, `is_initiator` em `SessionStatusDto`, e `renewal_retry_after_ms` |
| `rust/src/ffi/session.rs` | Selar recibos e drenar condicionalmente em `receive_incoming`; adicionar `on_channel_connected`/`drain_pending`; internalizar `seal_outgoing_receipt`; atualizar testes §11.4 |
| `rust/src/test_support.rs` e `rust/src/ffi/core.rs` | Adaptar helpers `feed_handshake`/`decrypt_incoming` à nova assinatura de `receive_incoming` |
| `rust/src/frb_generated.rs` e `lib/src/rust/**` | Regenerados via `flutter_rust_bridge_codegen generate` |
| `lib/src/transport/message_reception_service.dart` | Substituir `_handleIncomingRaw`, `_sendReceipt`, `_publishConnectSignal`, a detecção de bordas em `_handleSessionEvent` (mantendo `_sessionStates`/`sessionStateFor` como cache passivo) e `_renewalTimers` por despacho único de `SessionActionsDto` |
| `lib/src/features/chat/chat_controller.dart` | Simplificar `reconnectSession` para usar retorno de `resetSession`; revisar `sendText`/`_trySendSealed` |
| `lib/src/transport/{webrtc_p2p,lan/lan,multipeer/multipeer,wifi_aware/wifi_aware}_transport.dart` | Ler `status.isInitiator` em vez de `status.outgoingHandshake != null` |
| `test/transport/message_reception_service_test.dart` e `test/features/chat/chat_controller_test.dart` | Remover emulação de `feedHandshake`/`decryptIncoming` e adaptar testes de drenagem/recibo/timer |
| Demais arquivos em `test/{transport,discovery,features}/` com dublês `implements Core` (24 classes no total) e `test/support/fake_session_events.dart` | Atualizar construtores de `SessionStatusDto` (8 arquivos) e assinaturas alteradas de `Core` |

---

## 8. Fontes consultadas

| # | Fonte | Tipo | Versão | Consultada em | Sustenta |
|---|---|---|---|---|---|
| F1 | [Flutter Rust Bridge — Rust calls Dart (`DartFnFuture`)](https://github.com/fzyzcjy/flutter_rust_bridge/blob/v2.13.0/website/docs/guides/direction/rust-call-dart.md) | Doc oficial | 2.13.0 | 2026-11-17 | Decisão 2.1 (callbacks exigem `pub async fn` no Rust) |
| F2 | [Flutter Rust Bridge — Streams (`StreamSink`)](https://github.com/fzyzcjy/flutter_rust_bridge/blob/v2.13.0/website/docs/guides/types/translatable/stream.md) | Doc oficial | 2.13.0 | 2026-11-17 | Decisão 2.1 e Verificação 5 (comportamento de `StreamSink` na v2.13.0) |

As estimativas de esforço em dias-dev (`2,5–3,5 d` completo; `1,5–2 d` mínimo viável) permanecem
`[modelado]` por se tratar de spike de análise antes da implementação, baseadas na contagem direta
dos arquivos e dublês afetados no repositório.

---

> Nenhum item deste relatório foi executado em build, `cargo test`, `flutter test` ou dispositivo
> real. Toda a análise decorre da inspeção direta do código na branch `docs/99-spike-rust-routing`
> (baseada em `origin/develop`, commit `6726106`), da especificação em `docs/protocol.md`, dos
> desvios em `docs/deviations.md` e da documentação do `flutter_rust_bridge` v2.13.0; as
> verificações propostas permanecem pendentes na seção 5.
