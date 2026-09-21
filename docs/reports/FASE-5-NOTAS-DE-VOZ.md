# Fase 5 — notas de voz em Opus sem metadados

| Campo | Valor |
|-------|-------|
| **Status** | 🟢 Implementado e testado de ponta a ponta (Rust + Dart), timeline única com texto — pendências remanescentes só de verificação em aparelho físico, ver §0 |
| **Cobertura** | Rust: 261 testes no workspace, `cargo clippy --all-targets -- -D warnings` limpo, as duas combinações de build. Dart: `flutter analyze` limpo, 77 testes (`flutter test`), incluindo gravação/envio/recebimento/reprodução de nota de voz com dublês |
| **Depende de** | Fase 4 — confirmado em 2026-09-20: o pipeline Rust já existia (`rust/src/ffi/transfer.rs`, commit `021e7dd`), mas nunca tinha sido exposto ao Dart (`flutter_rust_bridge_codegen` não rodava desde então) — regenerado nesta fase, o que também deu à Fase 4 sua primeira exposição real ao Dart |
| **Compartilha código com** | Fase 4: fatiamento, Merkle, staging e cifragem são os mesmos; nota de voz usa um byte `kind` no corpo de `FILE_METADATA` para escolher `K_audio_chunk` em vez de `K_symbol` (D16), e o canal `file` agora suporta várias transferências concorrentes por `file_id` em claro (D17), beneficiando arquivo genérico também |

---

## 0. Atualização (2026-09-20) — duas rodadas de implementação

Este relatório foi escrito em 17/09 como plano; a implementação aconteceu em 20/09, em duas rodadas
(a segunda a pedido do usuário, para "resolver todas as pendências" da primeira). As seções 1–8
abaixo são o plano original, mantidas como registro histórico.

### Rodada 1

- **`AUDIO_CHUNK` implementado de verdade** (decisão do usuário), não só reaproveitando
  `FILE_SYMBOL` por baixo: `crypto::kdf::context::AUDIO_CHUNK` é um contexto de KDF próprio —
  `file::keys::derive_audio_key` nunca produz a mesma chave que `derive_symbol_key` para o mesmo par
  `(transfer_secret, file_id)`. Um byte `kind` no corpo de `FILE_METADATA`
  (`file::transfer::TransferKind`) diz ao receptor qual chave derivar. **D16**, `docs/protocol.md`
  §6.6/§7.1.
- **Sanitização por subtração, não filtro**: `file::opus_container` desmonta o Ogg-Opus do gravador
  e extrai só canais/taxa/pre-skip/pacotes crus — `OpusTags` inteiro é descartado, nunca copiado
  para nenhuma struct. Testado com fixture de `OpusTags` forjado (`ENCODER`, `creation_time`,
  identificador de aparelho) que não sobrevive à extração.
- `flutter_rust_bridge_codegen generate` rodado — expôs Fase 4 *e* Fase 5 ao Dart pela primeira vez.

### Rodada 2 — pendências resolvidas a pedido do usuário

- **Transferências concorrentes (D17)**: o corpo de `FILE_SYMBOL`/`AUDIO_CHUNK` ganhou um prefixo
  `file_id` (16 B, em claro) — `file::transfer::peek_wire_file_id` roteia cada pacote do canal
  `file` para a `ReceiveTransfer` certa antes de decifrar, sem precisar de nenhum estado prévio do
  lado que chama. Antes, só dava para ter uma transferência ativa por contato. Testado com
  `duas_transferencias_concorrentes_nao_se_contaminam` (arquivo + nota de voz simultâneos,
  intercalados no mesmo canal). `next_outgoing_file_symbol`/`next_outgoing_audio_chunk` e
  `ingest_incoming_file_symbol`/`ingest_incoming_audio_chunk` foram unificados em
  `next_outgoing_wire_chunk`/`ingest_incoming_wire_bytes` (o roteamento por `file_id` tornou a
  distinção desnecessária). Beneficia arquivo genérico (Fase 4) também, não só áudio.
- **Reprodução em WAV, não Ogg (D18)**: descoberto ao integrar com `just_audio` que `AVPlayer` (iOS)
  não demuxa contêiner Ogg de jeito nenhum, com ou sem suporte a Opus. `file::opus_container::decode_to_wav`
  decodifica os pacotes Opus para PCM (`libopus` via a crate `audiopus`, licença BSD) e embrulha num
  WAV — toca sem ambiguidade nas duas plataformas. `rebuild_ogg_opus_container` foi renomeado/substituído
  por `Core::decode_audio_to_wav`.
- **Timeline única (decisão do usuário)**: nota de voz é uma linha em `store::messages`
  (`packet_type = AudioChunk`, corpo `hex(file_id)`), na mesma lista cronológica de mensagens de
  texto — `MessageDto` ganhou `kind`/`audio_file_id`. `start_send_audio` insere a linha `Pending`;
  `handle_incoming_file_metadata` insere `Delivered` assim que a oferta chega, antes do primeiro
  `AUDIO_CHUNK`. `ChatController` e `VoiceController` foram fundidos em um só — a razão é estrutural,
  não só conveniência: as duas peças precisam reagir ao mesmo fluxo de eventos do canal `control`, e
  `Core::decryptIncoming` não pode ser chamado duas vezes para o mesmo envelope.
- **Descoberta por evento, não por *polling***: `ChatController._handleIncomingRaw` agora sempre
  atualiza a timeline após decifrar (não só quando produz uma mensagem de texto) — é assim que uma
  oferta de nota de voz nova aparece sem esperar um intervalo fixo. A conclusão de um recebimento é
  detectada no próprio ingest do canal `file` (`progress.isComplete`), não por consulta periódica.
  Continua havendo uma espera curta (100 ms) só no laço de envio, para dar ritmo a "tentar de novo"
  depois de um `FILE_FEEDBACK" — não é descoberta de novidade, é controle de fluxo.
- **`minSdk` do Android subido para 29** (decisão do usuário) — `AudioEncoder.opus` do pacote
  `record` exige SDK 29+; descarta Android 9 (Pie) e anteriores.
- **Aceitar/recusar oferta**: decisão do usuário de manter automático (mesmo comportamento herdado
  da Fase 4) — não implementado, permanece como decisão de produto em aberto, não técnica.
- **Testes dedicados para a lógica de voz**: `VoiceRecorder`/`VoicePlayer` (`lib/src/features/voice/voice_io.dart`)
  extraem gravação/reprodução como interfaces injetáveis; `PermissionHandlerPlatform`/`PathProviderPlatform`
  trocados por dublês nos testes (evita depender de canal de plataforma real em `flutter test`).
  Cobertura: permissão negada, codec não suportado, envio completo (sanitização → metadado →
  pedaços → confirmação), recebimento completo (ingest → `FILE_COMPLETE` → decodificação), e
  reprodução/parada.

### Pendências que continuam em aberto (não resolvíveis nesta máquina)

- Verificação em aparelho físico (gravar/ouvir, Android↔iOS) — limitação de ambiente já registrada
  no `CLAUDE.md` (sem Xcode — microfone não testado em hardware real).
- Cross-compilação de `audiopus`/`libopus` para Android/iOS não verificada nesta máquina (só build
  para Linux, o host de desenvolvimento).
- Sem fluxo de aceitar/recusar oferta — decisão de produto do usuário, não pendência técnica.

---

## 1. Estado atual — evidências

### O que existe

`wire/packet_type.rs` declara `AUDIO_CHUNK` (`0x30`), conforme a spec §6.2. É tudo.

### O que não existe

```bash
grep -n "record\|opus" pubspec.yaml
# → 0 resultados
```

Nenhum código de captura, codificação ou reprodução, em nenhuma das duas linguagens.

---

## 2. As quatro decisões de design

### 2.1 Opus puro, não contêiner

A spec §6.3 exige áudio sem metadados de dispositivo, carimbo de tempo ou *tag* de software. Um
contêiner Ogg ou CAF acrescenta exatamente isso. O payload precisa ser o *bitstream* Opus cru, com o
enquadramento vindo do protocolo, não do formato de arquivo.

Isso tem um custo real: reprodutores padrão não tocam Opus cru sem cabeçalho. A reprodução precisa
remontar um contêiner mínimo **em memória**, na hora, e nunca gravá-lo em disco.

### 2.2 A sanitização tem que ser verificada, não presumida

`record` grava através das APIs do sistema, e tanto `MediaRecorder` no Android quanto `AVAudioRecorder`
no iOS acrescentam metadados por conta própria. O teste que importa é abrir o arquivo produzido e
provar, byte a byte, que não há `ENCODER`, `creation_time` nem identificador de aparelho.

### 2.3 Nota de voz é arquivo, não *stream*

Spec §6.3. Tratar como arquivo reusa Merkle, RaptorQ e staging da Fase 4 inteiros, e mantém o
tamanho de pacote dentro dos mesmos dois buckets. Um caminho de *streaming* em tempo real exigiria
um terceiro bucket e uma terceira política de perda.

### 2.4 O que não fazer

**Não implementar chamada de voz ao vivo.** Não está na especificação, exige jitter buffer, controle
de eco e um perfil de latência incompatível com padding de tamanho fixo e jitter de envio.

---

## 3. Plano de implementação

| Fase | Conteúdo | Esforço [modelado] |
|---|---|---|
| **F0** | Captura com `record` em Opus, taxa e canais fixos, permissão de microfone | 1 d |
| **F1** | Sanitização e verificação byte a byte do arquivo produzido | 0,5–1 d |
| **F2** | Ligação ao pipeline da Fase 4, com `AUDIO_CHUNK` no lugar de `FILE_SYMBOL` | 0,5 d |
| **F3** | Reprodução com remontagem de contêiner em memória, e UI de gravação e escuta | 1–2 d |

**Mínimo viável** (gravar, enviar, ouvir): F0 + F2 + F3 ≈ 2,5–3,5 d.
**Escopo completo:** F0–F3 ≈ 3–4,5 d.

---

## 4. Armadilhas

| Armadilha | Mitigação |
|---|---|
| iOS entrega AAC por padrão; Opus exige configuração explícita | Fixar o codec no `RecordConfig` e falhar alto se o aparelho não suportar, em vez de cair em AAC em silêncio. |
| Reprodutores não tocam Opus cru | Remontar cabeçalho em memória; nunca gravar o contêiner em disco, onde ele vira artefato com metadados. |
| Duração da nota vaza pelo tamanho do payload | Os buckets de padding já limitam a granularidade, mas a **contagem** de pacotes ainda revela duração aproximada. Limitação a declarar no threat model, não a esconder. |
| Permissão de microfone negada no meio da gravação | Tratar como erro de usuário, com mensagem clara — não como *crash*. |

---

## 5. Verificação

**Automatizável no host (`cargo test` / script):**

- [ ] O arquivo Opus produzido não contém nenhuma das cadeias `ENCODER`, `creation_time`, `handler`
      nem identificador de aparelho — guarda o invariante da spec §6.3, e é o teste central da fase.

**Automatizável no host (`flutter test`):**

- [ ] A remontagem de contêiner produz um *stream* tocável a partir de um Opus cru conhecido.

**Só em aparelho físico (não verificado até rodar):**

- [ ] Gravar no Android e ouvir no iOS, e o inverso — é onde diferenças de codec aparecem.
- [ ] Nota longa (5 min) atravessa o pipeline sem pico de memória.

---

## 6. Riscos

1. **A sanitização depende do que o sistema operacional decide escrever.** É a única parte desta
   fase cujo resultado não se controla por código, só se verifica depois do fato — e pode exigir
   pós-processamento do *bitstream* em vez de configuração do gravador.

2. **A fase é barata só se a Fase 4 estiver sólida.** Se o pipeline de arquivo tiver arestas, elas
   aparecem aqui multiplicadas pela frequência de uso: nota de voz é mandada dezenas de vezes por
   dia, arquivo grande não.

---

## 7. Arquivos tocados

| Arquivo | Mudança |
|---|---|
| `pubspec.yaml` | `record`, `permission_handler` |
| `lib/src/features/voice/` | **novo** — gravação, reprodução, UI |
| `rust/src/file/manifest.rs` | variante de manifesto para áudio |
| `android/app/src/main/AndroidManifest.xml` · `ios/Runner/Info.plist` | permissão de microfone |
| `docs/threat-model.md` | vazamento de duração por contagem de pacotes |

---

> Atualização de 2026-09-20 (ver §0): F0–F3 implementados e testados nas duas pontas — Rust
> (`cargo test`/`cargo clippy` limpos) e Dart (`flutter analyze`/`flutter test` limpos) —, incluindo
> a verificação central (fixture com metadados forjados não sobrevive a
> `file::opus_container::strip_container`), transferências concorrentes (D17), reprodução
> confiável em iOS (D18, WAV em vez de Ogg) e timeline única com mensagens de texto. A verificação
> com uma gravação real em aparelho físico continua pendente, como já previsto aqui.
