#!/usr/bin/env bash
# Hook post_install para sanity-check do Binutils 2.45.1 - Pass 1

set -euo pipefail

PKG_EXPECTED_VERSION="2.45.1"

# OBS: ADM_ROOTFS não é exportado pelo adm.sh por padrão.
# Aqui usamos:
#   - ADM_ROOTFS, se o usuário tiver exportado;
#   - caso contrário, caímos no default do adm: /opt/adm/rootfs.
ROOTFS="${ADM_ROOTFS:-/opt/adm/rootfs}"
ROOTFS="${ROOTFS%/}"

TOOLS_BIN="${ROOTFS}/tools/bin"

LD_BIN="${TOOLS_BIN}/ld"
AS_BIN="${TOOLS_BIN}/as"

echo "[binutils-pass1/post_install] Sanity-check do Binutils Pass 1 em ${TOOLS_BIN}..."

if [[ ! -x "${LD_BIN}" ]]; then
  echo "[binutils-pass1/post_install] ERRO: ld não encontrado em ${LD_BIN}" >&2
  exit 1
fi

if [[ ! -x "${AS_BIN}" ]]; then
  echo "[binutils-pass1/post_install] ERRO: as não encontrado em ${AS_BIN}" >&2
  exit 1
fi

echo "[binutils-pass1/post_install] ld encontrado: ${LD_BIN}"
echo "[binutils-pass1/post_install] as encontrado: ${AS_BIN}"

# Versão
ld_version="$("${LD_BIN}" --version 2>/dev/null | head -n1 || true)"
as_version="$("${AS_BIN}" --version 2>/dev/null | head -n1 || true)"

if [[ -z "${ld_version}" ]]; then
  echo "[binutils-pass1/post_install] ERRO: não foi possível obter 'ld --version'." >&2
  exit 1
fi

if [[ -z "${as_version}" ]]; then
  echo "[binutils-pass1/post_install] ERRO: não foi possível obter 'as --version'." >&2
  exit 1
fi

echo "[binutils-pass1/post_install] ld --version: ${ld_version}"
echo "[binutils-pass1/post_install] as --version: ${as_version}"

if ! grep -q "${PKG_EXPECTED_VERSION}" <<<"${ld_version}"; then
  echo "[binutils-pass1/post_install] ERRO: versão inesperada de ld (esperado ${PKG_EXPECTED_VERSION})." >&2
  exit 1
fi

# PATH de teste só com /tools/bin
PATH_TEST="${TOOLS_BIN}:${PATH}"
PATH="${PATH_TEST}"
export PATH

which_ld="$(command -v ld || true)"
if [[ -z "${which_ld}" ]]; then
  echo "[binutils-pass1/post_install] ERRO: 'ld' não encontrado no PATH de teste (${PATH_TEST})." >&2
  exit 1
fi

echo "[binutils-pass1/post_install] 'ld' resolvido para: ${which_ld}"

echo "[binutils-pass1/post_install] OK: Binutils Pass 1 ${PKG_EXPECTED_VERSION} em /tools parece funcional."
exit 0
