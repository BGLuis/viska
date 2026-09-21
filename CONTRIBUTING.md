# Guia de Contribuição — Viska

Obrigado pelo seu interesse em contribuir com o **Viska**! Este é um projeto de comunicação ponto a ponto (P2P) com requisitos rígidos de segurança, privacidade e resistência pós-quântica. Para manter esses padrões, todas as contribuições devem seguir as diretrizes abaixo.

---

## 🔒 Princípios de Segurança Não Negociáveis

Qualquer contribuição que viole os princípios a seguir será rejeitada:

1. **Nunca enfraqueça uma primitiva criptográfica para fazer testes passarem.** Se um teste falhar, o código está incorreto ou a expectativa do teste está errada. Reduzir tamanhos de chave, relaxar checagens ou trocar primitivas sem especificação formal é proibido.
2. **Nenhuma assinatura assimétrica por mensagem.** Para assegurar a deniabilidade criptográfica, assinaturas Ed25519 são restritas exclusivamente ao payload do QR Code de pareamento. Mensagens de chat utilizam exclusivamente autenticação simétrica via MAC.
3. **Nenhum segredo cruza a barreira FFI.** O núcleo Rust detém identidades, chaves, estados de ratchet, persistência cifrada e fluxos de arquivo. O Flutter/Dart manipula apenas handles opacos e dados já decifrados/renderizados.
4. **Aleatoriedade exclusivamente do sistema operacional.** Toda aleatoriedade deve vir de `crate::util::rng` (que consome `getrandom`). É vetado o uso de geradores pseudoaleatórios da aplicação para chaves, nonces, preenchimentos ou jitter.
5. **Zero segredos em logs, `Debug` ou mensagens de erro.** Qualquer tipo que manipule material de chave deve implementar `Debug` manualmente retornando `<redigido>`.
6. **Higiene estrita de memória (`zeroize`).** Todo buffer temporário que tenha manipulado chaves ou texto puro deve ser devidamente zerado ao ser descartado.
7. **Proibição estrita de código inseguro.** O crate Rust opera sob `#![forbid(unsafe_code)]` sem nenhuma exceção.
8. **Zero telemetria.** Nenhum SDK de analytics, anúncios, crash reporting remoto ou biblioteca que inicie conexões de rede próprias é permitido.

---

## 🏗️ Arquitetura e Separação de Responsabilidades

O repositório mantém uma separação rígida de camadas:

- **`rust/` (Núcleo de Segurança e Protocolo):**
  - `crypto/`: Identidade, pareamento QR, DH, KEM (ML-KEM-768), handshake, ratchet, AEAD, KDF.
  - `wire/`: Envelopes binários, preenchimento (padding buckets), enquadramento de pacotes e jitter.
  - `util/`: CSPRNG e utilitários auxiliares.
- **`lib/` (Camada de Apresentação e Transporte):**
  - Interface visual em Flutter, sinalização MQTT hostil, WebRTC, BLE e mDNS.
- **`docs/` (Especificações Normativas):**
  - `protocol.md`: Especificação técnica de protocolo.
  - `deviations.md`: Registro de decisões arquiteturais deliberadas.
  - `threat-model.md`: Modelo formal de ameaças.

> **Regra de ouro**: O módulo `wire/` manipula bytes e desconhece chaves criptográficas. O módulo `crypto/ratchet` gerencia chaves e não serializa bytes. A camada de sessão une ambos.

---

## 🚀 Como Desenvolver Localmente

### 1. Pré-requisitos
Certifique-se de ter instalado:
- Flutter SDK (canal estável, Dart SDK `>= 3.11.4`)
- Rust Toolchain (versão `>= 1.85`, com `clippy` e `rustfmt`)
- `flutter_rust_bridge_codegen` (`2.13.0`)
- No Linux: bibliotecas de áudio `libasound2-dev` e `libpulse-dev`

### 2. Validação Contínua (O que roda no CI)
Antes de abrir um Pull Request, execute os seguintes comandos localmente e garanta que todos passem sem qualquer aviso ou falha:

```bash
# Validação do núcleo Rust (executar a partir de rust/)
cd rust
cargo test --workspace
cargo clippy --all-targets -- -D warnings
cargo build --all-features
cargo build --no-default-features
cd ..

# Validação do Flutter (executar a partir da raiz)
flutter pub get
flutter analyze
flutter test
```

---

## 🌿 Fluxo de Git e Commits

1. Crie um fork do repositório e clone-o localmente.
2. Crie uma branch descritiva a partir de `develop` (ou `main`):
   - `feature/nome-da-funcionalidade`
   - `fix/descricao-do-ajuste`
   - `docs/melhoria-na-documentacao`
3. Faça commits claros e atômicos, com mensagens em português ou inglês que descrevam objetivamente o propósito da alteração.
4. Mantenha os comentários no código explicando **o porquê** da decisão de design, e não o que o código já expressa visualmente.

---

## 📥 Abrindo um Pull Request

Ao submeter um Pull Request:
1. Certifique-se de que a descrição explica o contexto da mudança e os testes executados.
2. Marque se houve qualquer impacto em protocolos ou contratos de dados.
3. Garanta que todas as verificações do CI passem com sucesso.
