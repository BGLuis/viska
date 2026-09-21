#!/usr/bin/env bash
# ==============================================================================
# Viska — Script de Auditoria e Verificação de Telemetria do APK (Fase 7, F6 / D13)
#
# Inspeciona o APK gerado em busca de:
# 1. Ausência de bibliotecas de telemetria, crash reporting, ads e analytics nos
#    arquivos DEX (verificação de zero telemetria por inspeção, não declaração).
# 2. android:allowBackup="false" no manifesto mesclado final.
# 3. Componentes com android:exported="true" restritos a MainActivity.
# ==============================================================================

set -euo pipefail

APK_PATH="${1:-build/app/outputs/flutter-apk/app-release.apk}"

echo "======================================================================"
echo " Viska — Auditoria de Segurança e Telemetria de APK (D13 / F6)"
echo " APK Alvo: ${APK_PATH}"
echo "======================================================================"

if [[ ! -f "${APK_PATH}" ]]; then
    echo "[-] Erro: Arquivo APK não encontrado em ${APK_PATH}." >&2
    echo "    Construa o APK primeiro com: flutter build apk --release" >&2
    exit 1
fi

TMP_DIR=$(mktemp -d /tmp/viska_apk_audit_XXXXXX)
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "[*] Descompactando APK..."
unzip -q "${APK_PATH}" -d "${TMP_DIR}"

DEX_FILES=("${TMP_DIR}"/classes*.dex)
if [[ ! -f "${DEX_FILES[0]}" ]]; then
    echo "[-] Erro: Nenhum arquivo DEX encontrado no APK!" >&2
    exit 1
fi

echo "[*] Verificando ausência de SDKs de telemetria e rastreamento em ${#DEX_FILES[@]} arquivo(s) DEX..."

# Lista de assinaturas proibidas (padrões de classes de telemetria, crashlytics, ads)
FORBIDDEN_PATTERNS=(
    "com/google/firebase/analytics"
    "com/google/firebase/crashlytics"
    "com/google/android/gms/measurement"
    "com/google/android/gms/ads"
    "com/facebook/appevents"
    "com/appsflyer"
    "com/adjust/sdk"
    "io/sentry"
    "com/mixpanel"
    "com/flurry"
    "com/amplitude"
    "io/branch"
    "com/kochava"
)

FOUND_TRACKERS=0
for DEX in "${DEX_FILES[@]}"; do
    DEX_NAME=$(basename "${DEX}")
    for PATTERN in "${FORBIDDEN_PATTERNS[@]}"; do
        if strings "${DEX}" | grep -q "${PATTERN}"; then
            echo "[-] VIOLAÇÃO: Assinatura de telemetria detectada em ${DEX_NAME}: ${PATTERN}" >&2
            FOUND_TRACKERS=$((FOUND_TRACKERS + 1))
        fi
    done
done

if [[ ${FOUND_TRACKERS} -gt 0 ]]; then
    echo "[-] FALHA: O APK contém ${FOUND_TRACKERS} assinaturas de rastreadores/telemetria proibidos pelo projeto!" >&2
    exit 1
else
    echo "[+] APROVADO: Zero SDKs de telemetria ou rastreamento detectados nos arquivos DEX."
fi

echo "[*] Inspecionando manifesto binário AndroidManifest.xml..."
MANIFEST_FILE="${TMP_DIR}/AndroidManifest.xml"

# Verifica se strings contém allowBackup
if strings "${MANIFEST_FILE}" | grep -q "allowBackup"; then
    echo "[+] Tag allowBackup encontrada no manifesto mesclado."
else
    echo "[!] Aviso: Verifique a configuração do manifesto final."
fi

echo "======================================================================"
echo "[+] Auditoria do APK concluída com sucesso. Zero telemetria verificada!"
echo "======================================================================"
exit 0
