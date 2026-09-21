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
  1:1 peer-to-peer messaging and file transfer mobile app featuring post-quantum hybrid encryption and zero-trust architecture.
</div>

<p align="center">
  <a href="README.md">Português</a> | <b>English</b>
</p>

# 📖 About
**Viska** is a **1:1** peer-to-peer (P2P) mobile messaging and file transfer application for Android and iOS, engineered with an uncompromising focus on privacy, cryptographic integrity, and post-quantum security. It operates under a zero-trust model, treating signaling MQTT brokers, STUN servers, and local access points as potentially hostile.

The application leverages **Flutter (Dart)** for its user interface and experience, and a high-performance, strictly memory-safe cryptographic core in **Rust** (with `#![forbid(unsafe_code)]`) interfaced via `flutter_rust_bridge`. All key management, KDF derivations, double-ratchet mechanisms, encrypted persistence (SQLCipher), and wire framing stay exclusively within Rust to maintain strict memory hygiene (`zeroize`).

### Core Security Pillars
1. **Zero Trusted Infrastructure**: Face-to-face QR code pairing with mutual cross-verification serves as the sole root of trust.
2. **Post-Quantum Resistance (HNDL)**: Guarded against *"Harvest Now, Decrypt Later"* attacks via hybrid key exchange combining **X25519** and **ML-KEM-768**.
3. **Plausible Deniability**: Message authentication relies exclusively on symmetric MACs (no per-message asymmetric signatures).
4. **Zero Telemetry**: No third-party trackers, analytics, crash reporting SDKs, or background network calls.

# 📋 Motivation
Unknown.

# 💻 Getting Started

### Prerequisites
- [Flutter SDK](https://flutter.dev/docs/get-started/install) (`>= 3.11.4` on the stable channel)
- [Dart SDK](https://dart.dev/get-dart) (`>= 3.11.4`)
- [Rust Toolchain](https://www.rust-lang.org/tools/install) (`>= 1.85` stable with `clippy` and `rustfmt`)
- [flutter_rust_bridge_codegen](https://cjycode.com/flutter_rust_bridge/) (`= 2.13.0`)
- [Android Studio & Android SDK/NDK](https://developer.android.com/studio) with Rust targets `aarch64-linux-android` and `x86_64-linux-android` (for Android)
- [Xcode](https://developer.apple.com/xcode/) (macOS, for iOS builds)
- Linux native audio dependencies (for local unit tests):
  ```sh
  sudo apt-get install -y libasound2-dev libpulse-dev
  ```

### Installation

1. Clone the project repository:
  ```sh
  git clone https://github.com/bgluis/viska.git
  ```

2. Navigate to the project directory:
  ```sh
  cd viska
  ```

3. Fetch Flutter dependencies:
  ```sh
  flutter pub get
  ```

4. Build and verify the Rust core:
  ```sh
  cd rust
  cargo test
  cargo clippy --all-targets -- -D warnings
  cd ..
  ```

5. Run the application on an emulator or connected device:
  ```sh
  flutter run
  ```

# 🤝 Contributors
 <a href="https://github.com/bgluis/viska/graphs/contributors">
   <img src="https://contrib.rocks/image?repo=bgluis/viska"/>
 </a>
