# Fase 5 — notas de voz em Opus sem metadados

| Campo | Valor |
|-------|-------|
| **Status** | ❌ Não iniciada |
| **Cobertura** | ~5 % (0 de 4 tarefas) — só o tipo de pacote `AUDIO_CHUNK` existe |
| **Esforço** | 3–4,5 dias-dev no escopo completo; 2–2,5 d no mínimo viável [modelado] |
| **Depende de** | Fase 4 — o áudio reusa o pipeline de arquivo por inteiro |
| **Compartilha código com** | Fase 4: fatiamento, Merkle, staging e cifragem são os mesmos |

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

> Nenhum item deste relatório foi executado, e a verificação central — ausência de metadados no
> arquivo gravado — só pode rodar depois de existir uma gravação real em aparelho físico.
