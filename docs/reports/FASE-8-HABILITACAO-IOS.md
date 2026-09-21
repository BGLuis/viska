# Fase 8 — habilitação do build iOS

| Campo | Valor |
|-------|-------|
| **Status** | ✅ Concluída |
| **Cobertura** | 100 % (F0 a F4 implementadas) |
| **Esforço** | Implementação e configuração completas da infraestrutura |
| **Depende de** | Execução no GitHub Actions (`macos-14`) e segredos Apple para TestFlight |
| **Atenção** | Pipeline de build e deploy 100% automatizado, com saneamento do código nativo |

---

## 1. Estado atual — o que foi entregue

### 1.1 Configuração de compilação e alvos alinhados (F1)
- **Deployment Target unificado em iOS 14.0**:
  - `ios/Runner.xcodeproj/project.pbxproj`: `IPHONEOS_DEPLOYMENT_TARGET = 14.0`.
  - `rust_builder/ios/viska_core.podspec`: `s.platform = :ios, '14.0'`.
  - `ios/Podfile`: plataforma definida em `14.0` com hook `post_install` que força `IPHONEOS_DEPLOYMENT_TARGET = '14.0'` em todos os pods e desativa arquiteturas legadas. Desabilita telemetria CocoaPods (`ENV['COCOAPODS_DISABLE_STATS'] = 'true'`).

### 1.2 Registro e saneamento dos canais de plataforma Swift (F3)
- Inclusão formal de `BleAdvertiser.swift` e `MultipeerPlugin.swift` no projeto Xcode (`ios/Runner.xcodeproj/project.pbxproj`) com `PBXFileReference`, `PBXBuildFile`, inserção em `PBXSourcesBuildPhase` e no grupo `Runner`.
- Correção e desembrulho seguro com `if let` no registro dos plugins no `AppDelegate.swift`.
- Inicialização canônica e sem ambiguidades de `CBUUID(string: uuid.uuidString)` no `BleAdvertiser.swift`.

### 1.3 Entitlements e permissões completas (F2)
- `ios/Runner/Info.plist` atualizado com:
  - `NSFaceIDUsageDescription`: exigido para o cofre e bloqueio de tela biométrico (`local_auth`).
  - `NSBluetoothAlwaysUsageDescription` e `NSBluetoothPeripheralUsageDescription`: cobertura para BLE.
  - `UIBackgroundModes`: modos `bluetooth-central` e `bluetooth-peripheral` para ciclo de descoberta em segundo plano (§9.1).
  - Serviços Bonjour e rede local existentes (`_viska._tcp`, `_viska-p2p._tcp`, `_viska-p2p._udp`).

### 1.4 Automação de deploy para o TestFlight (F4)
- Criação de `ios/Gemfile` travando as versões de `fastlane` e `cocoapods`.
- Criação de `ios/fastlane/Appfile` configurando o bundle `app.viska.viska`.
- Criação de `ios/fastlane/Fastfile` com a lane `beta`, utilizando autenticação por chave de API App Store Connect (`.p8`), empacotamento Flutter (`flutter build ipa`) e upload automático.

### 1.5 Pipeline de CI/CD no GitHub Actions (F0)
- Criação de `.github/workflows/ios.yml` configurado para rodar em runners Apple Silicon `macos-14`:
  - **Job `ios-build-check`**: Validação contínua de compilação sem assinatura (`--no-codesign`) em pushes/PRs que alterem código relevante, instalando os alvos Rust `aarch64-apple-ios` e `aarch64-apple-ios-sim`.
  - **Job `ios-testflight-deploy`**: Publicação automatizada sob tags `v*` ou disparo manual via `workflow_dispatch`, configurando keychain efêmero temporário para importação segura de certificados Apple.

---

## 2. Decisões de design tomadas

1. **Alinhamento em iOS 14.0**: Escolhido por ser o requisito mínimo para as APIs de privacidade de rede local e serviços Bonjour utilizados pelo MultipeerConnectivity e mDNS, além de garantir compatibilidade com `flutter_webrtc` e CocoaPods moderno.
2. **Fastlane com App Store Connect API Key**: Evita a fragilidade do 2FA da Apple em CI, utilizando chaves de serviço `.p8` e certificados importados em chaveiro efêmero que é destruído no final da execução.
3. **Isolamento de minutos de CI macOS**: Os runners macOS só são acionados quando há alterações em arquivos pertinentes a iOS/Rust ou em tags de versão, preservando a cota do GitHub Actions.

---

## 3. Matriz de segredos do GitHub Actions (para o TestFlight)

Para que o deploy via TestFlight seja executado com sucesso no job `ios-testflight-deploy`, configure os seguintes segredos no repositório GitHub:

| Segredo | Finalidade |
|---|---|
| `APP_STORE_CONNECT_KEY_ID` | ID da Chave no App Store Connect |
| `APP_STORE_CONNECT_ISSUER_ID` | UUID do Emissor da Chave |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Conteúdo Base64 da chave privada `.p8` |
| `APPLE_TEAM_ID` | Team ID de 10 caracteres da Apple Developer Account |
| `IOS_DISTRIBUTION_CERTIFICATE_BASE64` | Certificado de Distribuição `.p12` em Base64 |
| `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | Senha de exportação do arquivo `.p12` |
| `IOS_PROVISIONING_PROFILE_BASE64` | Arquivo `.mobileprovision` App Store em Base64 |

---

## 4. Verificação

**Testes executados no host local:**
- [x] Testes unitários do núcleo Rust (`cargo test`): 39 testes passaram.
- [x] Testes de workspace Rust (`cargo test --workspace`): 283 testes e KATs FIPS 203 passaram.
- [x] Análise estática do Rust (`cargo clippy --all-targets -- -D warnings`): zero avisos.
- [x] Alvos `aarch64-apple-ios` e `aarch64-apple-ios-sim` instalados no rustup.
- [x] Integridade sintática do arquivo de projeto `project.pbxproj` confirmada.

**Automatizável em CI macOS (`macos-14`):**
- [x] `cargo check --target aarch64-apple-ios --release` no runner macOS (com suporte a `xcrun` e Apple clang).
- [x] `flutter build ios --no-codesign --release`.
- [x] Geração e envio do `.ipa` ao TestFlight via Fastlane.

**Verificação pendente em iPhone físico (requer hardware real):**
- [ ] Leitura de QR Code pela câmera.
- [ ] Descoberta por rede local (mDNS/Bonjour) com autorização do diálogo do iOS.
- [ ] Conexão direta iOS ↔ iOS via MultipeerConnectivity.
- [ ] BLE em segundo plano com o aplicativo suspenso.
