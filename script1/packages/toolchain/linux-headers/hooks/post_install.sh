#!/usr/bin/env bash
# Hook post_install para Linux 6.17.9 - API Headers
#
# Executado após a instalação em ROOTFS.
# Objetivos:
#   - Verificar se os headers foram instalados em ROOTFS/usr/include.
#   - Checar presença de diretórios linux/ e asm/.
#   - Fazer alguns avisos básicos.

set -euo pipefail

PKG_EXPECTED_VERSION="6.17.9"

# ROOTFS passado pelo adm.sh (ou fallback)
ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

INCLUDE_DIR="${ROOTFS}/usr/include"

echo "[linux-api-headers/post_install] ROOTFS detectado: ${ROOTFS}"
echo "[linux-api-headers/post_install] Verificando headers em: ${INCLUDE_DIR}"

if [[ ! -d "${INCLUDE_DIR}" ]]; then
  echo "[linux-api-headers/post_install] ERRO: diretório ${INCLUDE_DIR} não existe." >&2
  exit 1
fi

if [[ ! -d "${INCLUDE_DIR}/linux" ]]; then
  echo "[linux-api-headers/post_install] ERRO: diretório ${INCLUDE_DIR}/linux não encontrado." >&2
  exit 1
fi

if [[ ! -d "${INCLUDE_DIR}/asm" && ! -d "${INCLUDE_DIR}/asm-generic" ]]; then
  echo "[linux-api-headers/post_install] AVISO: diretórios 'asm' ou 'asm-generic' não encontrados em ${INCLUDE_DIR}." >&2
  echo "[linux-api-headers/post_install]         Verifique se ARCH/headers_install foi executado corretamente." >&2
fi

# Cabeçalho típico para sanity-check simples
test_header="${INCLUDE_DIR}/linux/limits.h"
if [[ -f "${test_header}" ]]; then
  echo "[linux-api-headers/post_install] Header de teste encontrado: ${test_header}"
else
  echo "[linux-api-headers/post_install] AVISO: ${test_header} não encontrado; isso pode ser normal em versões recentes," >&2
  echo "[linux-api-headers/post_install]         mas é recomendável verificar manualmente o conteúdo de ${INCLUDE_DIR}/linux." >&2
fi

echo "[linux-api-headers/post_install] API Headers do Linux ${PKG_EXPECTED_VERSION} parecem instalados corretamente."
exit 0
