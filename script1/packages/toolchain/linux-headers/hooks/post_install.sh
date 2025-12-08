#!/usr/bin/env bash
# Hook post_install para Linux API Headers 6.17.9

set -euo pipefail

PKG_EXPECTED_VERSION="6.17.9"

ROOTFS="${ADM_ROOTFS:-/opt/adm/rootfs}"
ROOTFS="${ROOTFS%/}"

BUILDROOT="${ADM_BUILD_ROOT:-/opt/adm/build}"
PKG_FULL="core/linux-headers"

BUILDDIR="${BUILDROOT}/${PKG_FULL}"

echo "[linux-headers/post_install] Instalando Linux API Headers ${PKG_EXPECTED_VERSION}..."

cd "${BUILDDIR}"

# Processo OFICIAL do kernel:
make headers_check

make INSTALL_HDR_PATH="${ROOTFS}/usr" headers_install

# =========================
# SANITY CHECK REAL
# =========================

INCLUDE_DIR="${ROOTFS}/usr/include"
LINUX_DIR="${INCLUDE_DIR}/linux"
ASM_DIR="${INCLUDE_DIR}/asm"
ASMGEN_DIR="${INCLUDE_DIR}/asm-generic"

if [[ ! -d "${LINUX_DIR}" ]]; then
  echo "[linux-headers/post_install] ERRO: ${LINUX_DIR} inexistente." >&2
  exit 1
fi

if [[ ! -d "${ASM_DIR}" && ! -d "${ASMGEN_DIR}" ]]; then
  echo "[linux-headers/post_install] ERRO: asm ou asm-generic ausente." >&2
  exit 1
fi

critical_headers=(
  "linux/types.h"
  "linux/errno.h"
  "linux/ioctl.h"
  "linux/limits.h"
)

for h in "${critical_headers[@]}"; do
  if [[ ! -f "${INCLUDE_DIR}/${h}" ]]; then
    echo "[linux-headers/post_install] ERRO: header ausente: ${h}" >&2
    exit 1
  fi
done

# Detecção de versão (best-effort)
version_files=(
  "${INCLUDE_DIR}/linux/version.h"
  "${INCLUDE_DIR}/generated/uapi/linux/version.h"
)

detected=""
for f in "${version_files[@]}"; do
  if [[ -f "$f" ]]; then
    detected="$(grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' "$f" | head -n1 || true)"
    [[ -n "$detected" ]] && break
  fi
done

if [[ -n "$detected" ]]; then
  echo "[linux-headers/post_install] Versão detectada: $detected"
fi

echo "[linux-headers/post_install] ✅ Linux API Headers instalados corretamente em ${ROOTFS}/usr/include"
exit 0
