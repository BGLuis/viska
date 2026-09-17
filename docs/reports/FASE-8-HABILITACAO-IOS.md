# Fase 8 — habilitação do build iOS

| Campo | Valor |
|-------|-------|
| **Status** | ❌ Não iniciada |
| **Cobertura** | ~20 % (1 de 5 tarefas) — o `podspec` do cargokit existe e nunca rodou |
| **Esforço** | 3–5 dias-dev no escopo completo [modelado], com alta variância |
| **Depende de** | Acesso a macOS — nenhuma parte desta fase é executável na máquina atual |
| **Atenção** | O código iOS das Fases 2 a 7 é escrito às cegas até esta fase rodar pela primeira vez |

---

## 1. Estado atual — evidências

### O que existe

O `flutter create` gerou o projeto Xcode, e o cargokit gerou o *script phase* que compila o Rust:

```ruby
# rust_builder/ios/viska_core.podspec:32
:script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../../rust viska_core',
```

`rust/Cargo.toml:10-11` declara `staticlib`, que é a saída que o iOS consome, e
`viska_core.podspec:43` a carrega com `-force_load`.

### O que não existe

Nem a ferramenta, nem os alvos:

```bash
which xcodebuild
# → 0 resultados

rustup target list --installed | grep -c ios
# → 0
```

Nenhum *workflow* de CI:

```bash
ls .github/workflows 2>/dev/null
# → No such file or directory
```

### ⚠️ Consequência acumulada

Toda linha de Swift escrita nas Fases 2 a 7 — MultipeerConnectivity, BLE em segundo plano, Secure
Enclave, cobertura de tela — entra no repositório **sem nunca ter sido compilada**. O custo disso
não aparece agora; aparece concentrado aqui, e é a principal fonte de variância do esforço estimado.

---

## 2. As quatro decisões de design

### 2.1 CI em macOS é a única forma de fechar o laço

Sem Mac local, um *runner* macOS do GitHub Actions é o que transforma "escrito" em "compila". A
alternativa — acumular código Swift não compilado até alguém ter um Mac — concentra o risco em um
único evento tardio.

**Recomendação:** habilitar o *workflow* de CI macOS **antes** da Fase 2, não nesta fase, mesmo que
ele só compile o esqueleto no começo. Um CI que quebra na primeira linha de Swift errada custa
minutos; descobrir cem erros de uma vez custa dias.

### 2.2 Os alvos Rust do iOS são dois, não um

`aarch64-apple-ios` para aparelho e `aarch64-apple-ios-sim` para o simulador em Apple Silicon. O
cargokit monta o XCFramework, mas os alvos precisam estar instalados no *runner*.

### 2.3 O alvo de implantação precisa ser alinhado

`ios/Runner.xcodeproj/project.pbxproj:353` diz `IPHONEOS_DEPLOYMENT_TARGET = 13.0`;
`rust_builder/ios/viska_core.podspec:23` diz `s.platform = :ios, '11.0'`. A divergência é herdada do
*template* e deve ser resolvida para o maior dos dois antes do primeiro build real.

### 2.4 O que não fazer

**Não adiar os *entitlements* para o fim.** Rede local, Bluetooth, microfone e câmera exigem
descrições no `Info.plist`, e a ausência de uma delas faz a funcionalidade falhar **em silêncio** em
tempo de execução, não na compilação. Cada fase que acrescenta uma capacidade deve acrescentar a
entrada correspondente no mesmo momento.

---

## 3. Plano de implementação

| Fase | Conteúdo | Esforço [modelado] |
|---|---|---|
| **F0** | *Workflow* de CI macOS: instalar alvos Rust, `pod install`, `flutter build ios --no-codesign` | 1–1,5 d |
| **F1** | Alinhar alvo de implantação e validar a montagem do XCFramework pelo cargokit | 0,5–1 d |
| **F2** | `Info.plist` completo: rede local, Bonjour, Bluetooth, microfone, câmera | 0,5 d |
| **F3** | Correção do acúmulo de erros de compilação Swift das fases anteriores | 1–2 d, alta variância |
| **F4** | Assinatura e distribuição para TestFlight, se houver conta de desenvolvedor | 1 d |

**Mínimo viável** (o app compila para iOS no CI): F0 + F1 + F2 ≈ 2–3 d.
**Escopo completo:** F0–F4 ≈ 4–6 d.

---

## 4. Armadilhas

| Armadilha | Mitigação |
|---|---|
| `panic = "abort"` com `staticlib` e `-force_load` pode gerar conflito de símbolos | Verificar no primeiro build; é o tipo de problema que só aparece na linkagem real. |
| *Runner* macOS do GitHub Actions é cobrado a uma taxa maior que Linux | Rodar o *job* iOS só em `main` e em *pull request*, não a cada *push* de branch. |
| `pod install` depende de rede e de versão do CocoaPods | Travar a versão no *workflow*; CocoaPods quebra compatibilidade com frequência. |
| MultipeerConnectivity exige `NSLocalNetworkUsageDescription` e `NSBonjourServices` | Sem os dois, a descoberta falha sem erro visível — é o pior modo de falha possível. |
| Simulador não tem Bluetooth | Nenhum teste de BLE roda em CI. Esta fase compila; não valida rádio. |

---

## 5. Verificação

**Automatizável em CI macOS:**

- [ ] `cargo build --target aarch64-apple-ios --release` conclui — guarda que o núcleo Rust
      cross-compila, que é o risco central herdado da Fase 0.
- [ ] `flutter build ios --no-codesign` conclui.
- [ ] O `Info.plist` final contém todas as descrições de uso exigidas pelas capacidades declaradas.

**Só em iPhone físico (não verificado até rodar):**

- [ ] Leitura de QR Code pela câmera.
- [ ] Descoberta por rede local e o diálogo de permissão correspondente.
- [ ] BLE em segundo plano, com o app fechado.
- [ ] Chave protegida pelo Secure Enclave, e invalidada quando a biometria muda.

---

## 6. Riscos

1. **O esforço desta fase é o menos confiável de todo o projeto.** Depende de quanto código Swift
   se acumulou sem compilar, e esse número cresce a cada fase que passa sem CI macOS.

2. **Sem conta de desenvolvedor Apple, não há teste em aparelho físico.** O CI compila sem assinar,
   o que valida sintaxe e linkagem — nada do comportamento de rádio, Secure Enclave ou segundo plano.

3. **O simulador não substitui o aparelho para nada que importa nesta aplicação.** Bluetooth, Wi-Fi
   peer-to-peer e Secure Enclave não existem nele.

---

## 7. Arquivos tocados

| Arquivo | Mudança |
|---|---|
| `.github/workflows/ios.yml` | **novo** — build em *runner* macOS |
| `rust_builder/ios/viska_core.podspec` | alvo de implantação alinhado com o Runner |
| `ios/Runner/Info.plist` | descrições de uso de todas as capacidades |
| `ios/Runner.xcodeproj/project.pbxproj` | alvo de implantação e capacidades |
| `ios/Runner/*.swift` | correções acumuladas das fases anteriores |

---

> Nenhum item deste relatório foi executado, e nenhum **pode** ser executado na máquina atual:
> `which xcodebuild` devolve 0 resultados e nenhum alvo `*-apple-ios` está instalado. Toda a análise
> vem da leitura dos arquivos gerados pelo `flutter create` e pelo cargokit.
