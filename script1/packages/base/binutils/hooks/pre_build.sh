#!/usr/bin/env bash
# Hook pre_build para Binutils 2.45.1 (final)
#
# Executado após fetch/extract e antes de configure/build.
# Objetivos:
#   - Reconstruir BUILD_ROOT/BUILD_DIR como o adm.sh.
#   - Verificar se o source do binutils está íntegro (configure presente).
#   - Verificar se existe um compilador funcional (GCC) no ambiente.
#   - Fazer alguns sanity-checks mínimos do ROOTFS.
#   - Limpar artefatos de configure em caso de ADM_FORCE_REBUILD=1.

set -euo pipefail

###############################################################################
# Descoberta de ROOTFS / BUILD_ROOT / BUILD_DIR
###############################################################################

# ROOTFS passado pelo adm.sh:
ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[binutils/pre_build] ROOTFS detectado: ${ROOTFS}"

# A partir do ROOTFS (ex.: /opt/adm/rootfs-glibc), derivamos:
last="${ROOTFS##*/}"
suffix=""
if [[ "${last}" == rootfs* ]]; then
  suffix="${last#rootfs}"
fi
adm_base="${ROOTFS%/*}"

# BUILD_ROOT segue o padrão do adm.sh: "${ADM_ROOT}/build${suffix}"
BUILD_ROOT="${adm_base}/build${suffix}"

# Pacote completo (ex.: toolchain/binutils)
PKG_FULL="${ADM_HOOK_PKG:-toolchain/binutils}"

# BUILD_DIR = "${ADM_BUILD_ROOT}/build/${full}"
BUILD_DIR="${BUILD_ROOT}/build/${PKG_FULL}"

echo "[binutils/pre_build] BUILD_ROOT reconstruído: ${BUILD_ROOT}"
echo "[binutils/pre_build] Diretório de build do pacote: ${BUILD_DIR}"

###############################################################################
# Sanity-check do diretório de build
###############################################################################

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "[binutils/pre_build] ERRO: diretório de build ${BUILD_DIR} não existe." >&2
  echo "[binutils/pre_build]        Verifique a fase de extract do adm.sh." >&2
  exit 1
fi

if [[ ! -f "${BUILD_DIR}/configure" ]]; then
  echo "[binutils/pre_build] ERRO: 'configure' não encontrado em ${BUILD_DIR}." >&2
  echo "[binutils/pre_build]        Verifique se o tarball binutils-${PKG_VERSION}.tar.xz foi extraído corretamente." >&2
  exit 1
fi

###############################################################################
# Verificação de ambiente de toolchain (GCC)
###############################################################################

TOOLS_DIR="${ROOTFS}/tools"
TOOLS_BIN="${TOOLS_DIR}/bin"

TARGET_TGT="${PKG_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu}"
gcc_candidate=""

# Preferimos um ${TARGET}-gcc em /tools/bin ou /usr/bin
if [[ -x "${TOOLS_BIN}/${TARGET_TGT}-gcc" ]]; then
  gcc_candidate="${TOOLS_BIN}/${TARGET_TGT}-gcc"
elif [[ -x "${ROOTFS}/usr/bin/${TARGET_TGT}-gcc" ]]; then
  gcc_candidate="${ROOTFS}/usr/bin/${TARGET_TGT}-gcc"
elif command -v gcc >/dev/null 2>&1; then
  # último recurso: algum gcc no PATH
  gcc_candidate="$(command -v gcc)"
fi

if [[ -z "${gcc_candidate}" ]]; then
  echo "[binutils/pre_build] ERRO: nenhum compilador GCC adequado encontrado (nem ${TARGET_TGT}-gcc nem gcc no PATH)." >&2
  echo "[binutils/pre_build]        Certifique-se de que o toolchain está instalado (GCC Pass 1 ou final)." >&2
  exit 1
fi

echo "[binutils/pre_build] GCC detectado para build do binutils: ${gcc_candidate}"

###############################################################################
# Limpeza agressiva em caso de ADM_FORCE_REBUILD=1
###############################################################################

FORCE_REBUILD="${ADM_FORCE_REBUILD:-0}"

if [[ "${FORCE_REBUILD}" = "1" ]]; then
  echo "[binutils/pre_build] ADM_FORCE_REBUILD=1 -> limpando artefatos antigos em ${BUILD_DIR}"

  # Remove artefatos típicos de configure/autotools
  for f in config.cache config.log config.status; do
    if [[ -f "${BUILD_DIR}/${f}" ]]; then
      echo "[binutils/pre_build] Removendo ${BUILD_DIR}/${f}"
      rm -f "${BUILD_DIR}/${f}"
    fi
  done

  # Remove Makefile de topo, se existir
  if [[ -f "${BUILD_DIR}/Makefile" ]]; then
    echo "[binutils/pre_build] Removendo Makefile de topo em ${BUILD_DIR}/Makefile"
    rm -f "${BUILD_DIR}/Makefile"
  fi
fi

###############################################################################
# Logs adicionais de ambiente
###############################################################################

PROFILE="${ADM_PROFILE:-default}"
TRIPLET="${TARGET_TRIPLET:-native}"

echo "[binutils/pre_build] Perfil ADM (ADM_PROFILE): ${PROFILE}"
echo "[binutils/pre_build] TARGET_TRIPLET (se definido): ${TRIPLET}"
echo "[binutils/pre_build] TARGET_TGT (toolchain): ${TARGET_TGT}"

CURRENT_PATH="${PATH:-/usr/bin:/bin}"
echo "[binutils/pre_build] PATH atual no contexto do hook:"
echo "  ${CURRENT_PATH}"

echo "[binutils/pre_build] Sanity-check concluído. Ambiente pronto para build do Binutils 2.45.1 (final)."
exit 0
