#!/usr/bin/env bash
# Hook pre_build para musl 1.2.5 - libc final (perfil -P musl)
#
# Objetivos:
#   - Reconstruir BUILD_ROOT/BUILD_DIR como o adm.sh.
#   - Verificar se o source do musl está íntegro (configure presente).
#   - Verificar Linux API headers em ROOTFS/usr/include.
#   - Verificar toolchain musl em /usr/bin (ou equivalente).
#   - Limpar subdir build/ em caso de ADM_FORCE_REBUILD=1.

set -euo pipefail

###############################################################################
# ROOTFS / BUILD_ROOT / BUILD_DIR
###############################################################################

ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[musl-final/pre_build] ROOTFS detectado: ${ROOTFS}"

# A partir do ROOTFS (ex.: /opt/adm/rootfs-musl)
last="${ROOTFS##*/}"
suffix=""
if [[ "${last}" == rootfs* ]]; then
  suffix="${last#rootfs}"
fi
adm_base="${ROOTFS%/*}"

# BUILD_ROOT segue o padrão do adm.sh: "${ADM_ROOT}/build${suffix}"
BUILD_ROOT="${adm_base}/build${suffix}"

# Pacote completo (ex.: system/musl)
PKG_FULL="${ADM_HOOK_PKG:-system/musl}"

# BUILD_DIR = "${ADM_BUILD_ROOT}/build/${full}"
BUILD_DIR="${BUILD_ROOT}/build/${PKG_FULL}"

echo "[musl-final/pre_build] BUILD_ROOT reconstruído: ${BUILD_ROOT}"
echo "[musl-final/pre_build] Diretório de build do pacote: ${BUILD_DIR}"

###############################################################################
# Sanity-check do diretório de build e do source do musl
###############################################################################

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "[musl-final/pre_build] ERRO: diretório de build ${BUILD_DIR} não existe." >&2
  echo "[musl-final/pre_build]        Verifique a fase de extract/patch do adm.sh." >&2
  exit 1
fi

if [[ ! -f "${BUILD_DIR}/configure" ]]; then
  echo "[musl-final/pre_build] ERRO: 'configure' não encontrado em ${BUILD_DIR}." >&2
  echo "[musl-final/pre_build]        Verifique se o tarball musl-${PKG_VERSION:-1.2.5}.tar.gz foi extraído corretamente." >&2
  exit 1
fi

###############################################################################
# Verificação de Linux API headers no ROOTFS
###############################################################################

INCLUDE_DIR="${ROOTFS}/usr/include"

echo "[musl-final/pre_build] Verificando Linux API headers em: ${INCLUDE_DIR}"

if [[ ! -d "${INCLUDE_DIR}" ]]; then
  echo "[musl-final/pre_build] ERRO: diretório ${INCLUDE_DIR} não existe." >&2
  echo "[musl-final/pre_build]        Você instalou system/linux-api-headers antes do musl final?" >&2
  exit 1
fi

if [[ ! -d "${INCLUDE_DIR}/linux" ]]; then
  echo "[musl-final/pre_build] ERRO: diretório ${INCLUDE_DIR}/linux não encontrado." >&2
  echo "[musl-final/pre_build]        Os headers do kernel parecem não estar instalados." >&2
  exit 1
fi

###############################################################################
# Verificação do toolchain musl em /usr/bin
###############################################################################

USR_BIN="${ROOTFS}/usr/bin"

echo "[musl-final/pre_build] Verificando toolchain final em: ${USR_BIN}"

if [[ ! -d "${USR_BIN}" ]]; then
  echo "[musl-final/pre_build] ERRO: diretório ${USR_BIN} não existe." >&2
  echo "[musl-final/pre_build]        O binutils/gcc final já foi instalado em /usr para o perfil musl?" >&2
  exit 1
fi

TARGET_TGT="${PKG_TARGET_TRIPLET:-${ADM_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-linux-musl}}"
gcc_candidate=""

if [[ -x "${USR_BIN}/${TARGET_TGT}-gcc" ]]; then
  gcc_candidate="${USR_BIN}/${TARGET_TGT}-gcc"
elif command -v gcc >/dev/null 2>&1; then
  gcc_candidate="$(command -v gcc)"
fi

if [[ -z "${gcc_candidate}" ]]; then
  echo "[musl-final/pre_build] ERRO: nenhum compilador GCC adequado encontrado (nem ${TARGET_TGT}-gcc em ${USR_BIN}, nem gcc no PATH)." >&2
  exit 1
fi

echo "[musl-final/pre_build] GCC detectado para build do musl final: ${gcc_candidate}"

###############################################################################
# Limpeza agressiva do subdir build em caso de ADM_FORCE_REBUILD=1
###############################################################################

FORCE_REBUILD="${ADM_FORCE_REBUILD:-0}"

if [[ "${FORCE_REBUILD}" = "1" ]]; then
  if [[ -d "${BUILD_DIR}/build" ]]; then
    echo "[musl-final/pre_build] ADM_FORCE_REBUILD=1 -> removendo ${BUILD_DIR}/build."
    rm -rf "${BUILD_DIR}/build"
  fi
fi

###############################################################################
# Logs de ambiente
###############################################################################

PROFILE="${ADM_PROFILE:-default}"
TRIPLET="${TARGET_TRIPLET:-native}"

echo "[musl-final/pre_build] Perfil ADM (ADM_PROFILE): ${PROFILE}"
echo "[musl-final/pre_build] TARGET_TRIPLET (se definido): ${TRIPLET}"
echo "[musl-final/pre_build] TARGET_TGT (toolchain): ${TARGET_TGT}"

CURRENT_PATH="${PATH:-/usr/bin:/bin}"
echo "[musl-final/pre_build] PATH atual no contexto do hook:"
echo "  ${CURRENT_PATH}"

echo "[musl-final/pre_build] Sanity-check concluído. Ambiente pronto para build da musl 1.2.5 (final)."
exit 0
