#!/usr/bin/env bash
# ==============================================================================
# verify_mobile.sh — Script pré-voo de verificação mobile e integridade do APK
#
# Executa todas as camadas de validação necessárias para certificar que nenhuma
# alteração cause crashes ou falhas no aplicativo móvel:
# 1. Testes unitários do núcleo Rust (cargo test)
# 2. Linter do Rust sem avisos (cargo clippy -D warnings)
# 3. Análise estática do Flutter (flutter analyze)
# 4. Suíte de testes do Flutter incluindo smoke tests (flutter test)
# 5. Compilação e empacotamento do APK Android (flutter build apk --debug)
# 6. Auditoria de bibliotecas nativas (libviska_core.so arm64-v8a e x86_64)
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_step() {
    echo -e "\n${BLUE}==>${NC} ${YELLOW}$1${NC}"
}

log_success() {
    echo -e "${GREEN}[✓] $1${NC}"
}

log_error() {
    echo -e "${RED}[✗] $1${NC}" >&2
}

log_step "1/6. Executando testes unitários do Rust Core..."
(cd rust && PROPTEST_CASES="${PROPTEST_CASES:-64}" cargo test --workspace)
log_success "Rust Core: 100% dos testes passaram."

log_step "2/6. Verificando clippy no Rust (zero warnings)..."
(cd rust && cargo clippy --all-targets -- -D warnings)
log_success "Rust Clippy: zero warnings."

log_step "3/6. Executando análise estática do Flutter..."
flutter analyze
log_success "Flutter Analyze: nenhum problema encontrado."

log_step "4/6. Executando suíte de testes Flutter (incluindo Smoke Tests)..."
flutter test
log_success "Flutter Tests: todos os testes passaram."

log_step "5/6. Compilando APK Android em modo Debug..."
flutter build apk --debug
log_success "Build do APK finalizado com sucesso."

log_step "6/6. Auditando bibliotecas nativas e integridade do APK..."
APK_PATH="build/app/outputs/flutter-apk/app-debug.apk"
if [ ! -f "${APK_PATH}" ]; then
    log_error "APK não encontrado em ${APK_PATH}"
    exit 1
fi

# Verifica presença das .so para arm64-v8a e x86_64
if ! unzip -l "${APK_PATH}" | grep -q "lib/arm64-v8a/libviska_core.so"; then
    log_error "libviska_core.so ausente para arm64-v8a!"
    exit 1
fi

if ! unzip -l "${APK_PATH}" | grep -q "lib/x86_64/libviska_core.so"; then
    log_error "libviska_core.so ausente para x86_64!"
    exit 1
fi

APK_SIZE=$(stat -c%s "${APK_PATH}" 2>/dev/null || stat -f%z "${APK_PATH}")
log_success "APK contém as bibliotecas 64-bit obrigatórias (arm64-v8a + x86_64)."
log_success "Tamanho do APK gerado: $(( APK_SIZE / 1024 / 1024 )) MB (${APK_SIZE} bytes)."

echo -e "\n${GREEN}=================================================================${NC}"
echo -e "${GREEN}  PRE-FLIGHT MOBILE CHECKLIST APROVADO — ZERO CRASHES DETECTADOS ${NC}"
echo -e "${GREEN}=================================================================${NC}\n"
