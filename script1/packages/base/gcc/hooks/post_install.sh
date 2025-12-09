#!/usr/bin/env bash
# Hook post_install para GCC 15.2.0 - Toolchain final
#
# Executado após a instalação em ROOTFS.
# Objetivos:
#   - Verificar se gcc/cc foram instalados em ROOTFS/usr/bin.
#   - Checar versão via gcc --version.
#   - Emitir avisos se houver conflito no PATH.

set -euo pipefail

PKG_EXPECTED_VERSION="15.2.0"

ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

USR_BIN="${ROOTFS}/usr/bin"

echo "[gcc-final/post_install] ROOTFS detectado: ${ROOTFS}"
echo "[gcc-final/post_install] Verificando GCC em: ${USR_BIN}"

if [[ ! -d "${USR_BIN}" ]]; then
  echo "[gcc-final/post_install] ERRO: diretório ${USR_BIN} não existe." >&2
  exit 1
fi

if [[ ! -x "${USR_BIN}/gcc" ]]; then
  echo "[gcc-final/post_install] ERRO: '${USR_BIN}/gcc' não encontrado ou não executável." >&2
  exit 1
fi

# cc normalmente é symlink para gcc; avisar se não for
if [[ ! -x "${USR_BIN}/cc" ]]; then
  echo "[gcc-final/post_install] AVISO: '${USR_BIN}/cc' não encontrado ou não executável." >&2
  echo "[gcc-final/post_install]         Considere criar um symlink cc -> gcc, se for apropriado." >&2
fi

# Verifica versão
gcc_version="$("${USR_BIN}/gcc" --version | head -n1 || true)"

if [[ -z "${gcc_version}" ]]; then
  echo "[gcc-final/post_install] ERRO: não foi possível obter 'gcc --version' de ${USR_BIN}/gcc." >&2
  exit 1
fi

echo "[gcc-final/post_install] gcc --version: ${gcc_version}"

if ! grep -q "${PKG_EXPECTED_VERSION}" <<<"${gcc_version}"; then
  echo "[gcc-final/post_install] AVISO: versão reportada por gcc não contém '${PKG_EXPECTED_VERSION}'." >&2
  echo "[gcc-final/post_install]         Verifique se este é realmente o GCC final esperado." >&2
fi

# Garante que /usr/bin está na frente do PATH e verifica resolução de gcc
export PATH="${USR_BIN}:${PATH:-/usr/bin:/bin}"
which_gcc="$(command -v gcc || true)"

if [[ -n "${which_gcc}" ]]; then
  echo "[gcc-final/post_install] 'gcc' no PATH resolve para: ${which_gcc}"
  if [[ "${which_gcc}" != "${USR_BIN}/gcc" ]]; then
    echo "[gcc-final/post_install] AVISO: 'gcc' no PATH não é o de ${USR_BIN}." >&2
    echo "[gcc-final/post_install]         Isso pode indicar que ainda há um GCC temporário em /tools na frente do PATH." >&2
  fi
else
  echo "[gcc-final/post_install] AVISO: 'gcc' não encontrado no PATH mesmo após incluir ${USR_BIN}." >&2
fi

echo "[gcc-final/post_install] GCC 15.2.0 (final) parece instalado corretamente no ROOTFS."
exit 0
