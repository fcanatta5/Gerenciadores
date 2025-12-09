#!/usr/bin/env bash
# Hook post_install para Glibc 2.42 - Pass 1
#
# Executado após a instalação em ROOTFS.
# Objetivos:
#   - Verificar se as libs básicas da glibc foram instaladas em ROOTFS.
#   - Verificar presença de headers essenciais em ROOTFS/usr/include.
#   - Emitir avisos básicos se algo suspeito for encontrado.

set -euo pipefail

PKG_EXPECTED_VERSION="2.42"

# ROOTFS passado pelo adm.sh (ou fallback)
ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[glibc-pass1/post_install] ROOTFS detectado: ${ROOTFS}"

LIB_DIR_1="${ROOTFS}/usr/lib"
LIB_DIR_2="${ROOTFS}/lib"
INC_DIR="${ROOTFS}/usr/include"

echo "[glibc-pass1/post_install] Verificando bibliotecas em:"
echo "  - ${LIB_DIR_1}"
echo "  - ${LIB_DIR_2}"

if [[ ! -d "${LIB_DIR_1}" ]]; then
  echo "[glibc-pass1/post_install] ERRO: diretório ${LIB_DIR_1} não existe." >&2
  exit 1
fi

# Verifica algum libc.so* em /usr/lib ou /lib
libc_candidates=()
if compgen -G "${LIB_DIR_1}/libc.so*" >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    libc_candidates+=("$f")
  done < <(find "${LIB_DIR_1}" -maxdepth 1 -name "libc.so*" -type f -print0)
fi

if compgen -G "${LIB_DIR_2}/libc.so*" >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    libc_candidates+=("$f")
  done < <(find "${LIB_DIR_2}" -maxdepth 1 -name "libc.so*" -type f -print0)
fi

if [[ "${#libc_candidates[@]}" -eq 0 ]]; then
  echo "[glibc-pass1/post_install] ERRO: nenhum arquivo 'libc.so*' encontrado em ${LIB_DIR_1} ou ${LIB_DIR_2}." >&2
  echo "[glibc-pass1/post_install]        A glibc parece não ter sido instalada corretamente." >&2
  exit 1
fi

echo "[glibc-pass1/post_install] libc candidata(s) encontrada(s):"
for c in "${libc_candidates[@]}"; do
  echo "  - ${c}"
done

###############################################################################
# Verificação de headers essenciais em usr/include
###############################################################################

echo "[glibc-pass1/post_install] Verificando headers em: ${INC_DIR}"

if [[ ! -d "${INC_DIR}" ]]; then
  echo "[glibc-pass1/post_install] ERRO: diretório ${INC_DIR} não existe." >&2
  exit 1
fi

# Alguns headers típicos da glibc
headers_essenciais=(
  "unistd.h"
  "stdio.h"
  "stdlib.h"
  "string.h"
  "time.h"
)

for h in "${headers_essenciais[@]}"; do
  if [[ ! -f "${INC_DIR}/${h}" ]]; then
    echo "[glibc-pass1/post_install] AVISO: header essencial ausente: ${INC_DIR}/${h}" >&2
  fi
done

# Opcional: verifica arquivo de versão
if [[ -f "${INC_DIR}/gnu/libc-version.h" ]]; then
  echo "[glibc-pass1/post_install] Header gnu/libc-version.h encontrado."
else
  echo "[glibc-pass1/post_install] AVISO: gnu/libc-version.h não encontrado; verifique se a instalação está completa." >&2
fi

echo "[glibc-pass1/post_install] Glibc ${PKG_EXPECTED_VERSION} (Pass 1) parece instalada corretamente no ROOTFS."
exit 0
