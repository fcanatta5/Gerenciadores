#!/usr/bin/env bash
# Hook pre_build para Glibc 2.42 (final)
#
# Objetivos:
#   - Reconstruir BUILD_ROOT/BUILD_DIR como o adm.sh.
#   - Verificar source da glibc (configure presente).
#   - Verificar Linux API headers em ROOTFS/usr/include.
#   - Verificar toolchain/binutils em ROOTFS/usr/bin.
#   - Limpar subdir build/ em caso de ADM_FORCE_REBUILD=1.

set -euo pipefail

###############################################################################
# ROOTFS / BUILD_ROOT / BUILD_DIR
###############################################################################

ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[glibc-final/pre_build] ROOTFS detectado: ${ROOTFS}"

last="${ROOTFS##*/}"
suffix=""
if [[ "${last}" == rootfs* ]]; then
  suffix="${last#rootfs}"
fi
adm_base="${ROOTFS%/*}"

BUILD_ROOT="${adm_base}/build${suffix}"

PKG_FULL="${ADM_HOOK_PKG:-system/glibc}"

BUILD_DIR="${BUILD_ROOT}/build/${PKG_FULL}"

echo "[glibc-final/pre_build] BUILD_ROOT reconstruído: ${BUILD_ROOT}"
echo "[glibc-final/pre_build] Diretório de build do pacote: ${BUILD_DIR}"

###############################################################################
# Sanity-check do diretório de build
###############################################################################

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "[glibc-final/pre_build] ERRO: diretório de build ${BUILD_DIR} não existe." >&2
  echo "[glibc-final/pre_build]        Verifique a fase de extract do adm.sh." >&2
  exit 1
fi

if [[ ! -f "${BUILD_DIR}/configure" ]]; then
  echo "[glibc-final/pre_build] ERRO: 'configure' não encontrado em ${BUILD_DIR}." >&2
  echo "[glibc-final/pre_build]        Verifique se o tarball glibc-${PKG_VERSION:-2.42}.tar.xz foi extraído corretamente." >&2
  exit 1
fi

if [[ ! -f "${BUILD_DIR}/scripts/config.guess" ]]; then
  echo "[glibc-final/pre_build] ERRO: scripts/config.guess não encontrado em ${BUILD_DIR}/scripts." >&2
  exit 1
fi

###############################################################################
# Verificação de Linux API headers
###############################################################################

INCLUDE_DIR="${ROOTFS}/usr/include"

echo "[glibc-final/pre_build] Verificando Linux API headers em: ${INCLUDE_DIR}"

if [[ ! -d "${INCLUDE_DIR}" ]]; then
  echo "[glibc-final/pre_build] ERRO: diretório ${INCLUDE_DIR} não existe." >&2
  echo "[glibc-final/pre_build]        Você instalou system/linux-api-headers antes da glibc final?" >&2
  exit 1
fi

if [[ ! -d "${INCLUDE_DIR}/linux" ]]; then
  echo "[glibc-final/pre_build] ERRO: diretório ${INCLUDE_DIR}/linux não encontrado." >&2
  echo "[glibc-final/pre_build]        Os headers do kernel parecem não estar instalados." >&2
  exit 1
fi

###############################################################################
# Verificação do toolchain/binutils em /usr
###############################################################################

USR_BIN="${ROOTFS}/usr/bin"

echo "[glibc-final/pre_build] Verificando toolchain final em: ${USR_BIN}"

if [[ ! -d "${USR_BIN}" ]]; then
  echo "[glibc-final/pre_build] ERRO: diretório ${USR_BIN} não existe." >&2
  echo "[glibc-final/pre_build]        O binutils/gcc final já foi instalado em /usr?" >&2
  exit 1
fi

if ! command -v gcc >/dev/null 2>&1 && [[ ! -x "${USR_BIN}/gcc" ]]; then
  echo "[glibc-final/pre_build] ERRO: gcc não encontrado (nem no PATH nem em ${USR_BIN}/gcc)." >&2
  exit 1
fi

if [[ ! -x "${USR_BIN}/ld" ]]; then
  echo "[glibc-final/pre_build] ERRO: ld não encontrado ou não executável em ${USR_BIN}/ld." >&2
  exit 1
fi

###############################################################################
# Limpeza agressiva do subdir build em caso de ADM_FORCE_REBUILD=1
###############################################################################

FORCE_REBUILD="${ADM_FORCE_REBUILD:-0}"

if [[ "${FORCE_REBUILD}" = "1" ]]; then
  if [[ -d "${BUILD_DIR}/build" ]]; then
    echo "[glibc-final/pre_build] ADM_FORCE_REBUILD=1 -> removendo ${BUILD_DIR}/build."
    rm -rf "${BUILD_DIR}/build"
  fi
fi

###############################################################################
# Logs de ambiente
###############################################################################

PROFILE="${ADM_PROFILE:-default}"
TRIPLET="${TARGET_TRIPLET:-native}"

echo "[glibc-final/pre_build] Perfil ADM (ADM_PROFILE): ${PROFILE}"
echo "[glibc-final/pre_build] TARGET_TRIPLET (se definido): ${TRIPLET}"

CURRENT_PATH="${PATH:-/usr/bin:/bin}"
echo "[glibc-final/pre_build] PATH atual no contexto do hook:"
echo "  ${CURRENT_PATH}"

echo "[glibc-final/pre_build] Sanity-check concluído. Ambiente pronto para build da Glibc 2.42 (final)."
exit 0
