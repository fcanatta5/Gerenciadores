#!/usr/bin/env bash
# Hook pre_build para Glibc 2.42 - Pass 1
#
# Executado após fetch/extract e antes de configure/build.
# Objetivos:
#   - Reconstruir BUILD_ROOT/BUILD_DIR como o adm.sh.
#   - Verificar presença dos Linux API headers em ROOTFS/usr/include.
#   - Verificar se o toolchain Pass 1 em /tools está disponível.
#   - Limpar subdir "build" em caso de ADM_FORCE_REBUILD=1.

set -euo pipefail

###############################################################################
# Descoberta de ROOTFS / BUILD_ROOT / BUILD_DIR
###############################################################################

# ROOTFS passado pelo adm.sh:
ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[glibc-pass1/pre_build] ROOTFS detectado: ${ROOTFS}"

# A partir do ROOTFS (ex.: /opt/adm/rootfs-glibc)
last="${ROOTFS##*/}"
suffix=""
if [[ "${last}" == rootfs* ]]; then
  suffix="${last#rootfs}"
fi
adm_base="${ROOTFS%/*}"

# Reconstrói BUILD_ROOT como o adm.sh:
#   ADM_BUILD_ROOT="${ADM_ROOT}/build${suffix}"
BUILD_ROOT="${adm_base}/build${suffix}"

# Pacote completo (ex.: system/glibc-pass1)
PKG_FULL="${ADM_HOOK_PKG:-system/glibc-pass1}"

# BUILD_DIR = "${ADM_BUILD_ROOT}/build/${full}"
BUILD_DIR="${BUILD_ROOT}/build/${PKG_FULL}"

echo "[glibc-pass1/pre_build] BUILD_ROOT reconstruído: ${BUILD_ROOT}"
echo "[glibc-pass1/pre_build] Diretório de build do pacote: ${BUILD_DIR}"

###############################################################################
# Sanity-check do diretório de build e fonte da glibc
###############################################################################

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "[glibc-pass1/pre_build] ERRO: diretório de build ${BUILD_DIR} não existe." >&2
  echo "[glibc-pass1/pre_build]        Verifique a fase de extract do adm.sh." >&2
  exit 1
fi

if [[ ! -f "${BUILD_DIR}/configure" ]]; then
  echo "[glibc-pass1/pre_build] ERRO: 'configure' não encontrado em ${BUILD_DIR}." >&2
  echo "[glibc-pass1/pre_build]        Verifique se o tarball glibc-${PKG_VERSION}.tar.xz foi extraído corretamente." >&2
  exit 1
fi

###############################################################################
# Verificação dos Linux API Headers (já instalados)
###############################################################################

INCLUDE_DIR="${ROOTFS}/usr/include"

echo "[glibc-pass1/pre_build] Verificando Linux API headers em: ${INCLUDE_DIR}"

if [[ ! -d "${INCLUDE_DIR}" ]]; then
  echo "[glibc-pass1/pre_build] ERRO: diretório ${INCLUDE_DIR} não existe." >&2
  echo "[glibc-pass1/pre_build]        Você instalou o pacote linux-api-headers antes da glibc-pass1?" >&2
  exit 1
fi

if [[ ! -d "${INCLUDE_DIR}/linux" ]]; then
  echo "[glibc-pass1/pre_build] ERRO: diretório ${INCLUDE_DIR}/linux não encontrado." >&2
  echo "[glibc-pass1/pre_build]        Os headers do kernel parecem não estar instalados corretamente." >&2
  exit 1
fi

###############################################################################
# Verificação do toolchain Pass 1 em /tools
###############################################################################

TOOLS_DIR="${ROOTFS}/tools"
TOOLS_BIN="${TOOLS_DIR}/bin"

echo "[glibc-pass1/pre_build] Verificando toolchain em: ${TOOLS_BIN}"

if [[ ! -d "${TOOLS_BIN}" ]]; then
  echo "[glibc-pass1/pre_build] ERRO: diretório ${TOOLS_BIN} não existe." >&2
  echo "[glibc-pass1/pre_build]        O toolchain Pass 1 (binutils/gcc) já foi instalado em /tools?" >&2
  exit 1
fi

# Procura por ${PKG_TARGET_TRIPLET}-gcc ou algo similar
TARGET_TGT="${PKG_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu}"
gcc_candidate=""

if [[ -x "${TOOLS_BIN}/${TARGET_TGT}-gcc" ]]; then
  gcc_candidate="${TOOLS_BIN}/${TARGET_TGT}-gcc"
elif compgen -G "${TOOLS_BIN}/*-gcc" >/dev/null 2>&1; then
  # pega o primeiro *-gcc que aparecer
  gcc_candidate="$(compgen -G "${TOOLS_BIN}/*-gcc" | head -n1)"
fi

if [[ -z "${gcc_candidate}" ]]; then
  echo "[glibc-pass1/pre_build] ERRO: nenhum '*-gcc' encontrado em ${TOOLS_BIN}." >&2
  echo "[glibc-pass1/pre_build]        O GCC Pass 1 não parece instalado corretamente." >&2
  exit 1
fi

echo "[glibc-pass1/pre_build] GCC Pass 1 detectado: ${gcc_candidate}"

###############################################################################
# Limpeza agressiva do subdir build em caso de ADM_FORCE_REBUILD=1
###############################################################################

FORCE_REBUILD="${ADM_FORCE_REBUILD:-0}"

if [[ "${FORCE_REBUILD}" = "1" ]]; then
  if [[ -d "${BUILD_DIR}/build" ]]; then
    echo "[glibc-pass1/pre_build] ADM_FORCE_REBUILD=1 -> removendo subdir ${BUILD_DIR}/build para rebuild limpo."
    rm -rf "${BUILD_DIR}/build"
  fi
fi

###############################################################################
# Logs adicionais de ambiente
###############################################################################

PROFILE="${ADM_PROFILE:-default}"
TRIPLET="${TARGET_TRIPLET:-native}"

echo "[glibc-pass1/pre_build] Perfil ADM (ADM_PROFILE): ${PROFILE}"
echo "[glibc-pass1/pre_build] TARGET_TRIPLET (se definido): ${TRIPLET}"
echo "[glibc-pass1/pre_build] TARGET_TGT (toolchain): ${TARGET_TGT}"

CURRENT_PATH="${PATH:-/usr/bin:/bin}"
echo "[glibc-pass1/pre_build] PATH atual no contexto do hook:"
echo "  ${CURRENT_PATH}"

echo "[glibc-pass1/pre_build] Sanity-check concluído. Ambiente pronto para build da Glibc Pass 1."
exit 0
