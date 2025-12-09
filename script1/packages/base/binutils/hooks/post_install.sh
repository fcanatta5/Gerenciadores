#!/usr/bin/env bash
# Hook post_install para Binutils 2.45.1 (final)
#
# Executado após a instalação em ROOTFS.
# Objetivos:
#   - Verificar se 'ld' e 'as' foram instalados em ROOTFS/usr/bin.
#   - Checar a versão reportada por ld --version.
#   - Emitir avisos básicos se algo suspeito for encontrado.

set -euo pipefail

PKG_EXPECTED_VERSION="2.45.1"

# ROOTFS passado pelo adm.sh (ou fallback)
ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

USR_BIN="${ROOTFS}/usr/bin"

echo "[binutils/post_install] ROOTFS detectado: ${ROOTFS}"
echo "[binutils/post_install] Verificando binutils em: ${USR_BIN}"

if [[ ! -d "${USR_BIN}" ]]; then
  echo "[binutils/post_install] ERRO: diretório ${USR_BIN} não existe." >&2
  exit 1
fi

if [[ ! -x "${USR_BIN}/ld" ]]; then
  echo "[binutils/post_install] ERRO: '${USR_BIN}/ld' não encontrado ou não executável." >&2
  exit 1
fi

if [[ ! -x "${USR_BIN}/as" ]]; then
  echo "[binutils/post_install] ERRO: '${USR_BIN}/as' não encontrado ou não executável." >&2
  exit 1
fi

# Verifica versão reportada por ld
ld_version="$("${USR_BIN}/ld" --version | head -n1 || true)"

if [[ -z "${ld_version}" ]]; then
  echo "[binutils/post_install] ERRO: não foi possível obter 'ld --version' de ${USR_BIN}/ld." >&2
  exit 1
fi

echo "[binutils/post_install] ld --version: ${ld_version}"

if ! grep -q "${PKG_EXPECTED_VERSION}" <<<"${ld_version}"; then
  echo "[binutils/post_install] AVISO: versão reportada por ld não contém '${PKG_EXPECTED_VERSION}'." >&2
  echo "[binutils/post_install]         Verifique se o binutils correto foi instalado." >&2
fi

# Opcional: checar se 'ld' em PATH resolve para /usr/bin/ld
export PATH="${USR_BIN}:${PATH:-/usr/bin:/bin}"
which_ld="$(command -v ld || true)"

if [[ -n "${which_ld}" ]]; then
  echo "[binutils/post_install] 'ld' no PATH resolve para: ${which_ld}"
  if [[ "${which_ld}" != "${USR_BIN}/ld" ]]; then
    echo "[binutils/post_install] AVISO: 'ld' no PATH não é o de ${USR_BIN}." >&2
    echo "[binutils/post_install]         Isso pode indicar que há outro binutils competindo no PATH." >&2
  fi
else
  echo "[binutils/post_install] AVISO: 'ld' não encontrado no PATH mesmo após incluir ${USR_BIN}." >&2
fi

echo "[binutils/post_install] Binutils 2.45.1 (final) parecem instalados corretamente no ROOTFS."
exit 0
