#!/usr/bin/env bash
# Hook pre_build para musl 1.2.5 - Pass 1 (perfil -P musl)
#
# Executado após fetch/extract/patch e antes de configure/build.
# Objetivos:
#   - Reconstruir BUILD_ROOT/BUILD_DIR como o adm.sh.
#   - Verificar se o source do musl está íntegro (configure presente).
#   - Verificar se Linux API headers + toolchain pass1 estão disponíveis.
#   - Limpar subdir build/ em caso de ADM_FORCE_REBUILD=1.

set -euo pipefail

###############################################################################
# Descoberta de ROOTFS / BUILD_ROOT / BUILD_DIR
###############################################################################

# ROOTFS passado pelo adm.sh:
ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[musl-pass1/pre_build] ROOTFS detectado: ${ROOTFS}"

# A partir do ROOTFS (ex.: /opt/adm/rootfs-musl)
last="${ROOTFS##*/}"
suffix=""
if [[ "${last}" == rootfs* ]]; then
  suffix="${last#rootfs}"
fi
adm_base="${ROOTFS%/*}"

# BUILD_ROOT segue o padrão do adm.sh: "${ADM_ROOT}/build${suffix}"
BUILD_ROOT="${adm_base}/build${suffix}"

# Pacote completo (ex.: system/musl-pass1)
PKG_FULL="${ADM_HOOK_PKG:-system/musl-pass1}"

# BUILD_DIR = "${ADM_BUILD_ROOT}/build/${full}"
BUILD_DIR="${BUILD_ROOT}/build/${PKG_FULL}"

echo "[musl-pass1/pre_build] BUILD_ROOT reconstruído: ${BUILD_ROOT}"
echo "[musl-pass1/pre_build] Diretório de build do pacote: ${BUILD_DIR}"

###############################################################################
# Sanity-check do diretório de build e do source do musl
###############################################################################

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "[musl-pass1/pre_build] ERRO: diretório de build ${BUILD_DIR} não existe." >&2
  echo "[musl-pass1/pre_build]        Verifique a fase de extract/patch do adm.sh." >&2
  exit 1
fi

if [[ ! -f "${BUILD_DIR}/configure" ]]; then
  echo "[musl-pass1/pre_build] ERRO: 'configure' não encontrado em ${BUILD_DIR}." >&2
  echo "[musl-pass1/pre_build]        Verifique se o tarball musl-${PKG_VERSION:-1.2.5}.tar.gz foi extraído corretamente." >&2
  exit 1
fi

###############################################################################
# Verificação de Linux API headers + ambiente libc
###############################################################################

INCLUDE_DIR="${ROOTFS}/usr/include"

echo "[musl-pass1/pre_build] Verificando Linux API headers em: ${INCLUDE_DIR}"

if [[ ! -d "${INCLUDE_DIR}" ]]; then
  echo "[musl-pass1/pre_build] ERRO: diretório ${INCLUDE_DIR} não existe." >&2
  echo "[musl-pass1/pre_build]        Você instalou o pacote system/linux-api-headers antes do musl-pass1?" >&2
  exit 1
fi

if [[ ! -d "${INCLUDE_DIR}/linux" ]]; then
  echo "[musl-pass1/pre_build] ERRO: diretório ${INCLUDE_DIR}/linux não encontrado." >&2
  echo "[musl-pass1/pre_build]        Os headers do kernel parecem não estar instalados." >&2
  exit 1
fi

###############################################################################
# Verificação do toolchain Pass 1 em /tools (GCC/LD para musl)
###############################################################################

TOOLS_DIR="${ROOTFS}/tools"
TOOLS_BIN="${TOOLS_DIR}/bin"

echo "[musl-pass1/pre_build] Verificando toolchain em: ${TOOLS_BIN}"

if [[ ! -d "${TOOLS_BIN}" ]]; then
  echo "[musl-pass1/pre_build] ERRO: diretório ${TOOLS_BIN} não existe." >&2
  echo "[musl-pass1/pre_build]        O toolchain Pass 1 (binutils/gcc) já foi instalado em /tools para o perfil musl?" >&2
  exit 1
fi

TARGET_TGT="${PKG_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-linux-musl}"
gcc_candidate=""

if [[ -x "${TOOLS_BIN}/${TARGET_TGT}-gcc" ]]; then
  gcc_candidate="${TOOLS_BIN}/${TARGET_TGT}-gcc"
elif compgen -G "${TOOLS_BIN}/*-gcc" >/dev/null 2>&1; then
  gcc_candidate="$(compgen -G "${TOOLS_BIN}/*-gcc" | head -n1)"
fi

if [[ -z "${gcc_candidate}" ]]; then
  echo "[musl-pass1/pre_build] ERRO: nenhum '*-gcc' encontrado em ${TOOLS_BIN}." >&2
  echo "[musl-pass1/pre_build]        O GCC Pass 1 para musl não parece instalado corretamente." >&2
  exit 1
fi

echo "[musl-pass1/pre_build] GCC Pass 1 detectado: ${gcc_candidate}"

###############################################################################
# Limpeza agressiva do subdir build em caso de ADM_FORCE_REBUILD=1
###############################################################################

FORCE_REBUILD="${ADM_FORCE_REBUILD:-0}"

if [[ "${FORCE_REBUILD}" = "1" ]]; then
  if [[ -d "${BUILD_DIR}/build" ]]; then
    echo "[musl-pass1/pre_build] ADM_FORCE_REBUILD=1 -> removendo ${BUILD_DIR}/build."
    rm -rf "${BUILD_DIR}/build"
  fi
fi

###############################################################################
# Logs adicionais de ambiente
###############################################################################

PROFILE="${ADM_PROFILE:-default}"
TRIPLET="${TARGET_TRIPLET:-native}"

echo "[musl-pass1/pre_build] Perfil ADM (ADM_PROFILE): ${PROFILE}"
echo "[musl-pass1/pre_build] TARGET_TRIPLET (se definido): ${TRIPLET}"
echo "[musl-pass1/pre_build] TARGET_TGT (toolchain): ${TARGET_TGT}"

CURRENT_PATH="${PATH:-/usr/bin:/bin}"
echo "[musl-pass1/pre_build] PATH atual no contexto do hook:"
echo "  ${CURRENT_PATH}"

echo "[musl-pass1/pre_build] Sanity-check concluído. Ambiente pronto para build do musl 1.2.5 (Pass 1)."
exit 0
