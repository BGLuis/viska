# Fase 0 — scaffolding do projeto Flutter + núcleo Rust

| Campo | Valor |
|-------|-------|
| **Status** | ✅ Concluído |
| **Escopo entregue** | Projeto Flutter (Android/iOS/Linux) com crate Rust integrado via `flutter_rust_bridge` 2.13.0 e cargokit, mais a especificação normativa do protocolo |
| **Esforço real** | Não mensurável em dias-dev — executado em sessão assistida por agente, sem registro de horas |
| **Commit base** | Nenhum · `git log` → *your current branch 'master' does not have any commits yet* |

---

## 1. Sumário executivo

O diretório `/home/luis/Documents/hand-on/viska` estava vazio. A Fase 0 entregou três coisas: o
esqueleto Flutter com os três alvos de plataforma, o crate Rust ligado ao build de cada uma dessas
plataformas por cargokit, e — o item que mais importa para as fases seguintes — a especificação
normativa em `docs/protocol.md`, contra a qual todo o código posterior foi escrito.

A decisão de escrever a especificação **antes** de qualquer linha de Rust não era óbvia e se pagou
já na Fase 1: os agentes que implementaram `handshake.rs`, `aead.rs` e `wire/` receberam a seção
correspondente do documento como contrato, em vez de reconstruir o protocolo a partir de prosa.
Dois dos três relataram inconsistências na própria especificação — achados que só existem porque
havia um documento normativo para confrontar.

O `git init` foi executado, mas **nenhum commit foi feito**. Todo o trabalho das Fases 0 e 1 está
em *working tree* não versionado, o que é o risco operacional mais sério registrado neste relatório.

**Veredicto:** a fundação está correta e a cadeia de build está declarada para as três plataformas,
mas nunca foi exercida fora do host — nenhum artefato Android ou iOS foi produzido até agora.

---

## 2. Impactos e ganhos

Nenhum ganho de desempenho foi medido nesta fase; ela não substitui nada. A tabela abaixo registra o
que passou a existir, com a origem de cada número.

| Métrica | Antes | Depois | Fonte |
|---|---|---|---|
| Arquivos do projeto Flutter | 0 | 81 | saída do `flutter create` |
| Arquivos `.rs` no crate | 0 | 22 | `find . -name '*.rs' -not -path './rust/target/*' \| wc -l` |
| Linhas de Rust em `rust/src/` | 0 | 4.038 | `find src -name '*.rs' \| xargs wc -l` |
| Plataformas com build de Rust declarado | 0 | 3 (Android, iOS, Linux) | `rust_builder/{android/build.gradle,ios/viska_core.podspec,linux/CMakeLists.txt}` |
| Alvos Rust cross-compilados de fato | 0 | 0 | nenhum `cargo ndk` ou `flutter build` foi executado |
| Commits no repositório | 0 | 0 | `git log` |

A última linha é deliberada e não é um erro de preenchimento: a integração de build está **escrita**
e nunca **executada**. Ver seção 7.

---

## 3. Etapas executadas

Na ordem real, que divergiu do plano em um ponto registrado no passo 4.

1. **Inspeção do ambiente** — `flutter doctor` sem pendências: Flutter 3.41.6 · Dart 3.11.4 ·
   Android SDK 36 · NDK 26.3.11579264 e 28.2.13676358 · Rust 1.97.1 com o alvo
   `aarch64-linux-android` e `cargo-ndk` já instalados. Ausência de Xcode confirmada:
   `which xcodebuild` → 0 resultados.

2. **`flutter create`** com `--org app.viska --project-name viska --platforms=android,ios,linux
   --empty`. O alvo `linux` entrou como ferramenta de desenvolvimento, não como alvo de produto:
   permite rodar dois pares na mesma máquina e validar fluxos de rede e estado localmente.

3. **Especificação normativa** — `docs/protocol.md` (424 linhas na primeira versão) e
   `docs/deviations.md` (213 linhas), este último registrando os desvios D1–D13 em relação à
   arquitetura original, cada um com justificativa e custo de reverter.

4. **Integração `flutter_rust_bridge`** — `flutter_rust_bridge_codegen integrate` com
   `--rust-crate-name viska_core --rust-crate-dir rust --no-write-lib --no-integration-test`.
   **Desvio:** `--no-write-lib` fez o comando pular a criação do próprio crate Rust, que só passou a
   existir depois, escrito à mão. A flag foi passada para evitar o `lib/main.dart` de exemplo, e o
   efeito colateral sobre o crate não estava previsto. O resultado final é o desejado — o crate ficou
   em `rust/`, exatamente onde o cargokit o procura — mas por correção manual, não pelo comando.

5. **Versões travadas em 2.13.0 nos dois lados** — `pubspec.yaml:12` e a dependência correspondente
   no crate. O crates.io oferecia `2.14.0-beta.2`; a versão estável foi escolhida deliberadamente,
   porque Dart e Rust precisam concordar na versão do bridge e um *beta* em um dos lados quebra a
   geração de código.

---

## 4. Detalhes de implementação

### 4.1 O crate mora em `rust/`, não em `rust/viska_core/`

`rust_builder/android/build.gradle:53-56` + `rust_builder/linux/CMakeLists.txt:12` +
`rust_builder/ios/viska_core.podspec:32`

```gradle
cargokit {
    manifestDir = "../../rust"
    libname = "viska_core"
}
```

O plano original previa `rust/viska_core/`. Os três arquivos de build gerados pelo cargokit apontam
para `../../rust`, e mudar o layout exigiria editar os três. O plano cedeu ao gerador, não o
contrário — o custo de divergir seria pago em todo *upgrade* futuro do cargokit.

### 4.2 `crate-type` com três saídas

`rust/Cargo.toml:10-11`

```toml
[lib]
crate-type = ["cdylib", "staticlib", "lib"]
```

Cada alvo consome uma delas: `cdylib` no Android (`.so` empacotado no APK), `staticlib` no iOS
(`libviska_core.a`, carregada com `-force_load` em `viska_core.podspec:43`), e `lib` para que os
testes do próprio crate e futuros *integration tests* em Rust possam linkar normalmente.

### 4.3 `panic = "abort"` em release

`rust/Cargo.toml:37-42`

Desenrolar a pilha através da fronteira FFI é comportamento indefinido. Com `abort`, um pânico no
núcleo derruba o processo em vez de atravessar para o Dart — perder a sessão é preferível a
continuar executando com o estado do ratchet em condição desconhecida. `strip = true` e
`codegen-units = 1` acompanham, reduzindo o binário e melhorando a otimização entre módulos.

---

## 5. Arquivos tocados

| Arquivo | Mudança |
|---|---|
| `pubspec.yaml` · `analysis_options.yaml` · `lib/main.dart` | **novo** — `flutter create` |
| `android/` · `ios/` · `linux/` | **novo** — esqueletos de plataforma |
| `rust_builder/` (incl. `cargokit/`) | **novo** — `flutter_rust_bridge_codegen integrate` |
| `rust/Cargo.toml` | **novo** — manifesto do crate, 42 linhas |
| `rust/src/lib.rs` | **novo** — `forbid(unsafe_code)` em `:10`, enum `Error`, `PROTOCOL_VERSION` em `:18` |
| `rust/src/util/{mod,rng,time,encoding}.rs` | **novo** — CSPRNG, épocas de rotação, codificação |
| `docs/protocol.md` | **novo** — especificação normativa |
| `docs/deviations.md` | **novo** — desvios D1–D13 |
| `CLAUDE.md` · `GEMINI.md` | **novo** — instruções de projeto para agentes, corpo idêntico |
| `.gitignore` | `rust/target/`, `*.staging` |

---

## 6. Verificação executada

**Rodado e passando nesta sessão:**

- [x] `flutter doctor` — sem pendências nas seis verificações.
- [x] `cargo build` no host `x86_64-unknown-linux-gnu` — o crate compila.
- [x] `cargo build --all-features` e `cargo build --no-default-features` — as duas combinações
      compilam. Este par foi adicionado depois de uma regressão real, descrita na seção 7 do
      relatório da Fase 1.
- [x] `cargo test` no host — suíte verde no momento da medição.

**Não executado:**

- [ ] `flutter build apk` — a cross-compilação do Rust para `aarch64-linux-android` via cargokit
      nunca rodou.
- [ ] `flutter build ios` — impossível nesta máquina, sem Xcode.
- [ ] `flutter run -d linux` — o alvo Linux foi declarado, nunca construído.
- [ ] `flutter analyze` e `flutter test` — não executados nesta fase; `lib/main.dart` ainda é o
      esqueleto vazio.

---

## 7. O que não foi verificado

1. **A cadeia de build Android nunca foi exercida.** A configuração do cargokit em
   `rust_builder/android/build.gradle:52-56` está correta por inspeção, mas nenhum `.so` foi
   produzido. A primeira execução de `flutter build apk` é o teste real, e é onde problemas de NDK,
   de alvo Rust ausente e de empacotamento aparecem. Enquanto isso não rodar, "integrado" significa
   "declarado".

2. **`minSdkVersion 19` no plugin do cargokit** (`rust_builder/android/build.gradle:48`) é padrão do
   gerador e destoa do projeto — o app usa `flutter.minSdkVersion` (`android/app/build.gradle.kts:27`).
   O Gradle resolve pelo maior valor, então não quebra hoje, mas Wi-Fi Aware exige API 26+ e o
   número precisará subir antes da Fase 6.

3. **`IPHONEOS_DEPLOYMENT_TARGET = 13.0`** em `ios/Runner.xcodeproj/project.pbxproj:353` contra
   `s.platform = :ios, '11.0'` em `rust_builder/ios/viska_core.podspec:23`. Divergência herdada do
   *template*, sem efeito prático hoje, mas que deve ser alinhada na Fase 8.

4. **Nenhum endurecimento de plataforma foi aplicado.** `android:allowBackup="false"`, exigido por
   D13, não existe:

   ```bash
   grep -n "allowBackup" android/app/src/main/AndroidManifest.xml
   # → 0 resultados
   ```

   Isso é trabalho da Fase 7 e não é defeito desta fase, mas fica registrado porque, até lá, um
   backup do ADB carrega o banco para fora do aparelho.

5. **O trabalho não está versionado.** Sem nenhum commit, não há ponto de retorno, nem *diff*
   revisável, nem forma de atribuir uma regressão a uma mudança. Recomendação: commitar antes de
   iniciar a Fase 2, e não depois.

---

> Nenhum item deste relatório foi executado em aparelho Android, em iOS ou em qualquer alvo que não
> o host `x86_64-unknown-linux-gnu`. A verificação de plataforma está listada na seção 6 como não
> executada, e permanece assim.
