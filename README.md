<div align="center">

<!-- Badges de Status do GitHub -->
![GitHub Stars](https://www.shieldcn.dev/github/stars/bgluis/viska.svg?variant=secondary&size=sm)
![GitHub Forks](https://www.shieldcn.dev/github/forks/bgluis/viska.svg?variant=secondary&size=sm)
![Watchers](https://www.shieldcn.dev/github/watchers/bgluis/viska.svg?variant=secondary&size=sm)
![Contributors](https://www.shieldcn.dev/github/contributors/bgluis/viska.svg?theme=emerald&size=sm)
![License](https://www.shieldcn.dev/github/license/bgluis/viska.svg?variant=ghost&size=sm)

<br/>

<!-- Badges das Tecnologias Utilizadas (Substituir pelas reais do projeto) -->
![Flutter](https://www.shieldcn.dev/badge/Flutter-02569B.svg?logo=flutter&variant=branded&size=sm)
![Dart](https://www.shieldcn.dev/badge/Dart-0175C2.svg?logo=dart&variant=branded&size=sm)
![Rust](https://www.shieldcn.dev/badge/Rust-000000.svg?logo=rust&variant=branded&size=sm)
![WebRTC](https://www.shieldcn.dev/badge/WebRTC-333333.svg?logo=webrtc&variant=branded&size=sm)
![SQLite](https://www.shieldcn.dev/badge/SQLite-003B57.svg?logo=sqlite&variant=branded&size=sm)

  <h3>Viska</h3>
  Aplicativo móvel 1:1 de chat e transferência de arquivos P2P com criptografia híbrida pós-quântica e zero servidores confiáveis.
</div>

<p align="center">
  <b>Português</b> | <a href="README.en.md">English</a>
</p>

# 📖 Sobre
O **Viska** é um aplicativo móvel de comunicação ponto a ponto (P2P) **1:1** para Android e iOS, desenvolvido com foco intransigente em privacidade, integridade criptográfica e segurança pós-quântica. Ele opera sob uma arquitetura de confiança zero, onde brokers MQTT de sinalização, servidores STUN e pontos de acesso de rede são tratados como potencialmente hostis.

O projeto utiliza **Flutter (Dart)** para a camada de interface e experiência de usuário, e um núcleo criptográfico de alta performance implementado em **Rust** (sem código `unsafe`) conectado via `flutter_rust_bridge`. Toda a manipulação de chaves, derivação KDF, ratchets, persistência cifrada (SQLCipher) e codificação de transporte é mantida no lado Rust, garantindo isolamento de memória e higiene de segredos (`zeroize`).

### Pilares de Segurança
1. **Nenhuma infraestrutura confiável**: O pareamento presencial via QR Code com verificação cruzada é a única raiz de confiança.
2. **Resistência Pós-Quântica (HNDL)**: Proteção contra ataques *"Harvest Now, Decrypt Later"* combinando **X25519** com **ML-KEM-768** em camada híbrida.
3. **Deniabilidade Criptográfica**: Autenticação de mensagens exclusivamente via MAC simétrico (sem assinaturas assimétricas por mensagem).
4. **Zero Telemetria**: Sem rastreadores, analytics, crash reporting de terceiros ou SDKs que realizem requisições ocultas.

# 📋 Motivo
Desconhecido.

# 💻 Como iniciar

### Requisitos
- [Flutter SDK](https://flutter.dev/docs/get-started/install) (`>= 3.11.4` no canal estável)
- [Dart SDK](https://dart.dev/get-dart) (`>= 3.11.4`)
- [Rust Toolchain](https://www.rust-lang.org/tools/install) (`>= 1.85` estável com componentes `clippy` e `rustfmt`)
- [flutter_rust_bridge_codegen](https://cjycode.com/flutter_rust_bridge/) (`= 2.13.0`)
- [Android Studio & Android SDK/NDK](https://developer.android.com/studio) com os targets Rust `aarch64-linux-android` e `x86_64-linux-android` (para Android)
- [Xcode](https://developer.apple.com/xcode/) (macOS, para compilação iOS)
- Dependências nativas de áudio no Linux (para testes unitários locais):
  ```sh
  sudo apt-get install -y libasound2-dev libpulse-dev
  ```

### Instalação

1. Clone o repositório do projeto:
  ```sh
  git clone https://github.com/bgluis/viska.git
  ```

2. Navegue até o diretório do projeto:
  ```sh
  cd viska
  ```

3. Obtenha as dependências do Flutter:
  ```sh
  flutter pub get
  ```

4. Valide e compile o núcleo Rust:
  ```sh
  cd rust
  cargo test
  cargo clippy --all-targets -- -D warnings
  cd ..
  ```

5. Execute a aplicação em um emulador ou dispositivo conectado:
  ```sh
  flutter run
  ```

# 🤝 Contribuidores
 <a href="https://github.com/bgluis/viska/graphs/contributors">
   <img src="https://contrib.rocks/image?repo=bgluis/viska"/>
 </a>
