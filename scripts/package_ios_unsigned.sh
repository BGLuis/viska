#!/usr/bin/env bash
# Empacota o build Runner.app sem assinatura em um arquivo .ipa instalavel
# via ferramentas de sideloading comunitarias (AltStore, Sideloadly, TrollStore, etc.)
set -euo pipefail

APP_PATH="${1:-build/ios/iphoneos/Runner.app}"
OUTPUT_DIR="${2:-build/ios/release_unsigned}"
IPA_NAME="${3:-viska-ios-unsigned.ipa}"

if [ ! -d "$APP_PATH" ]; then
    echo "Erro: '$APP_PATH' não encontrado." >&2
    echo "Execute 'flutter build ios --no-codesign --release' antes de empacotar." >&2
    exit 1
fi

# Validação defensiva do diretório de saída para prevenir deleção acidental de caminhos críticos
if [ -z "${OUTPUT_DIR// }" ] || [ "$OUTPUT_DIR" = "." ] || [ "$OUTPUT_DIR" = ".." ] || [ "$OUTPUT_DIR" = "/" ] || [ "$OUTPUT_DIR" = "./" ] || { [ "$#" -ge 2 ] && [ -z "${2// }" ]; }; then
    echo "Erro: OUTPUT_DIR inválido ('$OUTPUT_DIR'). O diretório de saída não pode ser vazio, '.', '..' ou '/'." >&2
    exit 1
fi

echo "Criando estrutura Payload a partir de $APP_PATH..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/Payload"

# Copia preservando links simbolicos e atributos
cp -R "$APP_PATH" "$OUTPUT_DIR/Payload/"

# Comprime em formato .ipa padrao
(
    cd "$OUTPUT_DIR"
    zip -qry "$IPA_NAME" Payload
    rm -rf Payload
)

echo "Arquivo .ipa gerado com sucesso em: $OUTPUT_DIR/$IPA_NAME"
