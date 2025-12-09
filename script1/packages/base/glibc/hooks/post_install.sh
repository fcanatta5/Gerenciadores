#!/usr/bin/env bash
# Hook post_install para Glibc 2.42 (final)
#
# Objetivos:
#   - Verificar presença de libc.so.6 e libc-2.42.so em ROOTFS.
#   - Verificar dynamic linker ld-linux-*.so.*
#   - Verificar headers básicos em ROOTFS/usr/include.
#   - Emitir avisos se algo suspeito for encontrado.

set -euo pipefail

PKG_EXPECTED_VERSION="2.42"

ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[glibc-final/post_install] ROOTFS detectado: ${ROOTFS}"

LIB_DIR_1="${ROOTFS}/usr/lib"
LIB_DIR_2="${ROOTFS}/lib"
INC_DIR="${ROOTFS}/usr/include"

echo "[glibc-final/post_install] Verificando libs em:"
echo "  - ${LIB_DIR_1}"
echo "  - ${LIB_DIR_2}"

if [[ ! -d "${LIB_DIR_1}" && ! -d "${LIB_DIR_2}" ]]; then
  echo "[glibc-final/post_install] ERRO: nem ${LIB_DIR_1} nem ${LIB_DIR_2} existem." >&2
  exit 1
fi

###############################################################################
# libc.so.6 / libc-2.42.so
###############################################################################

libc_candidates=()

if [[ -d "${LIB_DIR_1}" ]]; then
  while IFS= read -r -d '' f; do
    libc_candidates+=("$f")
  done < <(find "${LIB_DIR_1}" -maxdepth 1 \( -name "libc.so.6" -o -name "libc-*.so" \) -type f -print0 || true)
fi

if [[ -d "${LIB_DIR_2}" ]]; then
  while IFS= read -r -d '' f; do
    libc_candidates+=("$f")
  done < <(find "${LIB_DIR_2}" -maxdepth 1 \( -name "libc.so.6" -o -name "libc-*.so" \) -type f -print0 || true)
fi

if [[ "${#libc_candidates[@]}" -eq 0 ]]; then
  echo "[glibc-final/post_install] ERRO: nenhum arquivo libc.so.6/libc-*.so encontrado em ${LIB_DIR_1} ou ${LIB_DIR_2}." >&2
  exit 1
fi

echo "[glibc-final/post_install] libc encontrada:"
for c in "${libc_candidates[@]}"; do
  echo "  - ${c}"
done

###############################################################################
# Dynamic linker (ld-linux-*.so.*)
###############################################################################

ld_candidates=()

if [[ -d "${LIB_DIR_2}" ]]; then
  while IFS= read -r -d '' f; do
    ld_candidates+=("$f")
  done < <(find "${LIB_DIR_2}" -maxdepth 1 -name "ld-linux-*.so.*" -type f -print0 || true)
fi

if [[ "${#ld_candidates[@]}" -eq 0 ]]; then
  echo "[glibc-final/post_install] AVISO: nenhum ld-linux-*.so.* encontrado em ${LIB_DIR_2}." >&2
  echo "[glibc-final/post_install]         Verifique se o dynamic linker foi instalado no local esperado." >&2
else
  echo "[glibc-final/post_install] Dynamic linker(s) encontrado(s):"
  for ld in "${ld_candidates[@]}"; do
    echo "  - ${ld}"
  done
fi

###############################################################################
# Headers essenciais em /usr/include
###############################################################################

echo "[glibc-final/post_install] Verificando headers em: ${INC_DIR}"

if [[ ! -d "${INC_DIR}" ]]; then
  echo "[glibc-final/post_install] ERRO: diretório ${INC_DIR} não existe." >&2
  exit 1
fi

headers_essenciais=(
  "unistd.h"
  "stdio.h"
  "stdlib.h"
  "string.h"
  "errno.h"
  "time.h"
)

missing_headers=0
for h in "${headers_essenciais[@]}"; do
  if [[ ! -f "${INC_DIR}/${h}" ]]; then
    echo "[glibc-final/post_install] AVISO: header essencial ausente: ${INC_DIR}/${h}" >&2
    missing_headers=1
  fi
done

if [[ "${missing_headers}" -eq 0 ]]; then
  echo "[glibc-final/post_install] Headers C básicos presentes em ${INC_DIR}."
fi

echo "[glibc-final/post_install] Glibc ${PKG_EXPECTED_VERSION} (final) parece instalada corretamente no ROOTFS."
exit 0
