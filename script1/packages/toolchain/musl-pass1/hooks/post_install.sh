#!/usr/bin/env bash
# Hook post_install para musl 1.2.5 - Pass 1 (perfil -P musl)
#
# Executado após a instalação em ROOTFS.
# Objetivos:
#   - Verificar se o dynamic linker ld-musl-$ARCH.so.1 foi instalado em ROOTFS/lib.
#   - Verificar presença de headers básicos em ROOTFS/usr/include.
#   - Emitir avisos se algo suspeito for encontrado.

set -euo pipefail

PKG_EXPECTED_VERSION="1.2.5"

ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[musl-pass1/post_install] ROOTFS detectado: ${ROOTFS}"

LIB_DIR="${ROOTFS}/lib"
INC_DIR="${ROOTFS}/usr/include"

echo "[musl-pass1/post_install] Verificando bibliotecas em: ${LIB_DIR}"
echo "[musl-pass1/post_install] Verificando headers em: ${INC_DIR}"

if [[ ! -d "${LIB_DIR}" ]]; then
  echo "[musl-pass1/post_install] ERRO: diretório ${LIB_DIR} não existe." >&2
  exit 1
fi

if [[ ! -d "${INC_DIR}" ]]; then
  echo "[musl-pass1/post_install] ERRO: diretório ${INC_DIR} não existe." >&2
  exit 1
fi

###############################################################################
# Dynamic linker ld-musl-$ARCH.so.1
###############################################################################

# Arquitetura musl (pode ajustar via PKG_MUSL_ARCH se precisar ser diferente)
MUSL_ARCH="${PKG_MUSL_ARCH:-${ADM_TARGET_ARCH:-x86_64}}"
LD_SO="${LIB_DIR}/ld-musl-${MUSL_ARCH}.so.1"

if [[ ! -f "${LD_SO}" ]]; then
  echo "[musl-pass1/post_install] ERRO: dynamic linker não encontrado: ${LD_SO}" >&2
  echo "[musl-pass1/post_install]        Verifique se a arquitetura esperada bate com o nome usado pelo musl." >&2
  exit 1
fi

echo "[musl-pass1/post_install] Dynamic linker encontrado: ${LD_SO}"

###############################################################################
# Headers básicos de C
###############################################################################

headers_essenciais=(
  "stdlib.h"
  "stdio.h"
  "string.h"
  "unistd.h"
  "errno.h"
)

missing_headers=0
for h in "${headers_essenciais[@]}"; do
  if [[ ! -f "${INC_DIR}/${h}" ]]; then
    echo "[musl-pass1/post_install] AVISO: header essencial ausente: ${INC_DIR}/${h}" >&2
    missing_headers=1
  fi
done

if [[ "${missing_headers}" -eq 0 ]]; then
  echo "[musl-pass1/post_install] Headers C básicos encontrados em ${INC_DIR}."
fi

echo "[musl-pass1/post_install] musl ${PKG_EXPECTED_VERSION} (Pass 1) parece instalado corretamente no ROOTFS."
exit 0
