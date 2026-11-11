{
  description = "Viska — ambiente de desenvolvimento opcional (nix develop). O CI não depende deste arquivo.";

  # Por que cada input existe (a lista é mínima de propósito; tudo fica fixado em flake.lock):
  # - nixpkgs-unstable: o canal estável (25.11) traz Flutter 3.38 / Dart 3.10, abaixo do
  #   Dart >= 3.11.4 e do Flutter >= 3.41 que o pubspec.lock exige. O unstable também traz o
  #   flutter_rust_bridge_codegen 2.13.0 exato; o estável traz o 2.11.1.
  # - rust-overlay: o rustc do nixpkgs não vem com a std dos targets Android; este input só
  #   baixa os tarballs oficiais de static.rust-lang.org.
  # - android-nixpkgs: Android SDK/NDK em versões exatas, baixados de dl.google.com.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    android-nixpkgs = {
      url = "github:tadfisher/android-nixpkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay, android-nixpkgs }:
    let
      # Só x86_64-linux: o android-nixpkgs não publica o SDK/NDK do Google para aarch64-linux,
      # e darwin não dá para validar sem Mac/Xcode.
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      mkEnv = system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
            # O Android SDK é unfree; aceitá-lo é uma escolha explícita de quem usa este shell.
            config.allowUnfree = true;
            config.android_sdk.accept_license = true;
          };

          # Mesmo conjunto que o CI usa em `rustup target add`.
          rust = pkgs.rust-bin.stable.latest.default.override {
            extensions = [ "clippy" "rustfmt" ];
            targets = [ "aarch64-linux-android" "x86_64-linux-android" ];
          };

          # compileSdk e ndkVersion vêm de `flutter.*` no android/app/build.gradle.kts, ou seja,
          # do SDK do Flutter: se o Flutter do lock mudar, estes valores precisam acompanhar.
          # build-tools 35 e platforms 34/35 não vêm do app: o Gradle os pede para compilar
          # plugins Flutter (audio_session, file_picker...) com compileSdk menor, e o SDK da
          # store é somente leitura, então não consegue instalá-los sozinho. O cmake 3.22.1 é o
          # que o plugin jni (CMake nativo) exige.
          androidSdk = android-nixpkgs.sdk.${system} (sp: with sp; [
            cmdline-tools-latest
            platform-tools
            build-tools-35-0-0
            build-tools-36-0-0
            platforms-android-34
            platforms-android-35
            platforms-android-36
            cmake-3-22-1
            ndk-28-2-13676358
          ]);
          # O ninja do pacote cmake do Google, reempacotado pelo android-nixpkgs, termina em
          # segfault aqui (quebra o plugin jni no Gradle). Troca só ele pelo ninja do nixpkgs,
          # numa cópia por symlinks do SDK, para não mexer no resto.
          androidSdkFixed = pkgs.runCommand "android-sdk-viska" { } ''
            mkdir -p $out/share
            cp -rs ${androidSdk}/share/android-sdk $out/share/android-sdk
            chmod -R u+w $out/share/android-sdk/cmake
            ln -sf ${pkgs.ninja}/bin/ninja $out/share/android-sdk/cmake/3.22.1/bin/ninja
          '';
          androidHome = "${androidSdkFixed}/share/android-sdk";

          jdk = pkgs.jdk17;
        in
        { inherit pkgs rust androidSdkFixed androidHome jdk; };
    in
    {
      devShells = forAllSystems (system:
        let e = mkEnv system; inherit (e) pkgs; in
        {
          default = pkgs.mkShell {
            packages = [
              e.rust
              pkgs.flutter
              e.jdk
              e.androidSdkFixed
              pkgs.flutter_rust_bridge_codegen
              # scripts/verify_mobile.sh e scripts/audit_apk.sh
              pkgs.jq
              pkgs.unzip
              pkgs.binutils # `strings`
              # crates de áudio do núcleo Rust no Linux
              pkgs.pkg-config
              pkgs.alsa-lib
              pkgs.libpulseaudio
            ];

            JAVA_HOME = "${e.jdk}";
            ANDROID_HOME = e.androidHome;
            ANDROID_SDK_ROOT = e.androidHome;
            # O aapt2 baixado do Maven pelo AGP é um binário dinâmico que não roda no Nix.
            GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${e.androidHome}/build-tools/36.0.0/aapt2";
            # Zero telemetria (CLAUDE.md): desliga o analytics do Flutter e o do CLI do Dart.
            FLUTTER_SUPPRESS_ANALYTICS = "true";
            DART_SUPPRESS_ANALYTICS = "true";
          };
        });

      # Garante apenas que o ambiente constrói; clippy/test precisam de rede (pub get) e do
      # CI, então ficam em `apps`, fora do sandbox.
      checks = forAllSystems (system: {
        devshell = self.devShells.${system}.default;
      });

      # Reproduzem os comandos do CLAUDE.md dentro do ambiente do flake, sem substituir o CI.
      apps = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # Não é writeShellApplication porque ANDROID_HOME, GRADLE_OPTS etc. só existem dentro
          # do `nix develop`; por isso os apps precisam ser executados de dentro do repositório.
          mk = name: description: script: {
            type = "app";
            meta.description = description;
            program = "${pkgs.writeShellScript name ''
              set -euo pipefail
              exec ${pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes' develop path:${self} --command bash -euo pipefail -c ${pkgs.lib.escapeShellArg script}
            ''}";
          };
        in
        {
          rust-check = mk "viska-rust-check" "clippy (-D warnings) e testes do núcleo Rust" ''
            cd "$(git rev-parse --show-toplevel)/rust"
            cargo clippy --locked --all-targets -- -D warnings
            cargo test --locked --workspace
          '';
          flutter-check = mk "viska-flutter-check" "pub get travado, analyze e testes do Flutter" ''
            cd "$(git rev-parse --show-toplevel)"
            flutter pub get --enforce-lockfile
            flutter analyze
            flutter test
          '';
        });
    };
}
