#!/usr/bin/env bash
# Hook post_install para GNU M4 1.4.20
#
# Executado após a instalação em ROOTFS.
# Objetivos:
#   - Verificar se o binário 'm4' foi instalado em ROOTFS/usr/bin.
#   - Checar a versão via 'm4 --version'.
#   - Emitir avisos se houver conflitos no PATH.

set -euo pipefail

PKG_EXPECTED_VERSION="1.4.20"

ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[m4/post_install] ROOTFS detectado: ${ROOTFS}"

USR_BIN="${ROOTFS}/usr/bin"

echo "[m4/post_install] Verificando binário do M4 em: ${USR_BIN}"

if [[ ! -d "${USR_BIN}" ]]; then>
  echo "[m4/post_install] ERRO: diretório ${USR_BIN} não existe." >&2
  exit 1
fi

if [[ ! -x "${USR_BIN}/m4" ]]; then
  echo "[m4/post_install] ERRO: '${USR_BIN}/m4' não encontrado ou não executável." >&2
  exit 1
fi

###############################################################################
# Verificação de versão
###############################################################################

m4_version="$("${USR_BIN}/m4" --version | head -n1 || true)"

if [[ -z "${m4_version}" ]]; then
  echo "[m4/post_install] ERRO: não foi possível obter 'm4 --version' de ${USR_BIN}/m4." >&2
  exit 1
fi

echo "[m4/post_install] m4 --version: ${m4_version}"

if ! grep -q "${PKG_EXPECTED_VERSION}" <<<"${m4_version}"; then
  echo "[m4/post_install] AVISO: versão reportada não contém '${PKG_EXPECTED_VERSION}'." >&2
  echo "[m4/post_install]         Verifique se este é o M4 esperado." >&2
fi

###############################################################################
# Verificação de PATH
###############################################################################

export PATH="${USR_BIN}:${PATH:-/usr/bin:/bin}"
which_m4="$(command -v m4 || true)"

if [[ -n "${which_m4}" ]]; then
  echo "[m4/post_install] 'm4' no PATH resolve para: ${which_m4}"
  if [[ "${which_m4}" != "${USR_BIN}/m4" ]]; then
    echo "[m4/post_install] AVISO: 'm4' no PATH não é o de ${USR_BIN}." >&2
    echo "[m4/post_install]         Isso pode indicar outro M4 competindo no PATH (por exemplo, em /tools)." >&2
  fi
else
  echo "[m4/post_install] AVISO: 'm4' não encontrado no PATH mesmo após incluir ${USR_BIN}." >&2
fi

echo "[m4/post_install] M4 ${PKG_EXPECTED_VERSION} parece instalado corretamente no ROOTFS."
exit 0
