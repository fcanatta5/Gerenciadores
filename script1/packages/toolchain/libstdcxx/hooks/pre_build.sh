#!/usr/bin/env bash
# Hook pre_build para Libstdc++ a partir do GCC 15.2.0 (Pass 1)
#
# Executado após fetch/extract e antes de configure/build.
# Objetivos:
#   - Reconstruir BUILD_ROOT/BUILD_DIR como o adm.sh.
#   - Verificar presença da subárvore libstdc++-v3 no source do GCC.
#   - Verificar se Linux API headers + Glibc estão instalados no ROOTFS.
#   - Verificar se o toolchain Pass 1 em /tools está disponível.
#   - Limpar subdir libstdc++-v3/build em caso de ADM_FORCE_REBUILD=1.

set -euo pipefail

###############################################################################
# Descoberta de ROOTFS / BUILD_ROOT / BUILD_DIR
###############################################################################

ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[libstdc++-pass1/pre_build] ROOTFS detectado: ${ROOTFS}"

last="${ROOTFS##*/}"
suffix=""
if [[ "${last}" == rootfs* ]]; then
  suffix="${last#rootfs}"
fi
adm_base="${ROOTFS%/*}"

# ADM_BUILD_ROOT = "${ADM_ROOT}/build${suffix}"
BUILD_ROOT="${adm_base}/build${suffix}"

# Pacote completo (ex.: toolchain/libstdc++-pass1)
PKG_FULL="${ADM_HOOK_PKG:-toolchain/libstdc++-pass1}"

# BUILD_DIR = "${ADM_BUILD_ROOT}/build/${full}"
BUILD_DIR="${BUILD_ROOT}/build/${PKG_FULL}"

echo "[libstdc++-pass1/pre_build] BUILD_ROOT reconstruído: ${BUILD_ROOT}"
echo "[libstdc++-pass1/pre_build] Diretório de build do pacote (source GCC): ${BUILD_DIR}"

###############################################################################
# Sanity-check do diretório de build e da subárvore libstdc++-v3
###############################################################################

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "[libstdc++-pass1/pre_build] ERRO: diretório de build ${BUILD_DIR} não existe." >&2
  echo "[libstdc++-pass1/pre_build]        Verifique a fase de extract do adm.sh para o tarball do GCC." >&2
  exit 1
fi

if [[ ! -f "${BUILD_DIR}/config.guess" ]]; then
  echo "[libstdc++-pass1/pre_build] ERRO: config.guess não encontrado em ${BUILD_DIR}." >&2
  echo "[libstdc++-pass1/pre_build]        O source do GCC parece incompleto." >&2
  exit 1
fi

if [[ ! -d "${BUILD_DIR}/libstdc++-v3" ]]; then
  echo "[libstdc++-pass1/pre_build] ERRO: diretório libstdc++-v3 não encontrado em ${BUILD_DIR}." >&2
  exit 1
fi

###############################################################################
# Verificação de Linux API headers + Glibc no ROOTFS
###############################################################################

INCLUDE_DIR="${ROOTFS}/usr/include"
LIB_DIR_1="${ROOTFS}/usr/lib"
LIB_DIR_2="${ROOTFS}/lib"

echo "[libstdc++-pass1/pre_build] Verificando headers/glibc em ROOTFS:"

if [[ ! -d "${INCLUDE_DIR}" ]]; then
  echo "[libstdc++-pass1/pre_build] ERRO: diretório ${INCLUDE_DIR} não existe." >&2
  echo "[libstdc++-pass1/pre_build]        Você instalou linux-api-headers e glibc-pass1?" >&2
  exit 1
fi

if [[ ! -d "${INCLUDE_DIR}/linux" ]]; then
  echo "[libstdc++-pass1/pre_build] ERRO: diretório ${INCLUDE_DIR}/linux não encontrado." >&2
  echo "[libstdc++-pass1/pre_build]        Os headers do kernel parecem não estar instalados." >&2
  exit 1
fi

if [[ ! -d "${LIB_DIR_1}" && ! -d "${LIB_DIR_2}" ]]; then
  echo "[libstdc++-pass1/pre_build] ERRO: nem ${LIB_DIR_1} nem ${LIB_DIR_2} existem." >&2
  echo "[libstdc++-pass1/pre_build]        A glibc não parece instalada corretamente." >&2
  exit 1
fi

###############################################################################
# Verificação do toolchain Pass 1 em /tools
###############################################################################

TOOLS_DIR="${ROOTFS}/tools"
TOOLS_BIN="${TOOLS_DIR}/bin"

echo "[libstdc++-pass1/pre_build] Verificando toolchain em: ${TOOLS_BIN}"

if [[ ! -d "${TOOLS_BIN}" ]]; then
  echo "[libstdc++-pass1/pre_build] ERRO: diretório ${TOOLS_BIN} não existe." >&2
  echo "[libstdc++-pass1/pre_build]        O toolchain Pass 1 (binutils/gcc) já foi instalado em /tools?" >&2
  exit 1
fi

TARGET_TGT="${PKG_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu}"
gcc_candidate=""

if [[ -x "${TOOLS_BIN}/${TARGET_TGT}-gcc" ]]; then
  gcc_candidate="${TOOLS_BIN}/${TARGET_TGT}-gcc"
elif compgen -G "${TOOLS_BIN}/*-gcc" >/dev/null 2>&1; then
  gcc_candidate="$(compgen -G "${TOOLS_BIN}/*-gcc" | head -n1)"
fi

if [[ -z "${gcc_candidate}" ]]; then
  echo "[libstdc++-pass1/pre_build] ERRO: nenhum '*-gcc' encontrado em ${TOOLS_BIN}." >&2
  echo "[libstdc++-pass1/pre_build]        O GCC Pass 1 não parece instalado corretamente." >&2
  exit 1
fi

echo "[libstdc++-pass1/pre_build] GCC Pass 1 detectado: ${gcc_candidate}"

###############################################################################
# Limpeza agressiva do subdir libstdc++-v3/build em caso de ADM_FORCE_REBUILD=1
###############################################################################

FORCE_REBUILD="${ADM_FORCE_REBUILD:-0}"

if [[ "${FORCE_REBUILD}" = "1" ]]; then
  if [[ -d "${BUILD_DIR}/libstdc++-v3/build" ]]; then
    echo "[libstdc++-pass1/pre_build] ADM_FORCE_REBUILD=1 -> removendo ${BUILD_DIR}/libstdc++-v3/build."
    rm -rf "${BUILD_DIR}/libstdc++-v3/build"
  fi
fi

###############################################################################
# Logs adicionais de ambiente
###############################################################################

PROFILE="${ADM_PROFILE:-default}"
TRIPLET="${TARGET_TRIPLET:-native}"

echo "[libstdc++-pass1/pre_build] Perfil ADM (ADM_PROFILE): ${PROFILE}"
echo "[libstdc++-pass1/pre_build] TARGET_TRIPLET (se definido): ${TRIPLET}"
echo "[libstdc++-pass1/pre_build] TARGET_TGT (toolchain): ${TARGET_TGT}"

CURRENT_PATH="${PATH:-/usr/bin:/bin}"
echo "[libstdc++-pass1/pre_build] PATH atual no contexto do hook:"
echo "  ${CURRENT_PATH}"

echo "[libstdc++-pass1/pre_build] Sanity-check concluído. Ambiente pronto para build da Libstdc++ Pass 1."
exit 0
