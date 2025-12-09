#!/usr/bin/env bash
# Hook pre_build para GNU M4 1.4.20
#
# Executado após fetch/extract/patch e antes de configure/build.
# Objetivos:
#   - Reconstruir BUILD_ROOT/BUILD_DIR como o adm.sh.
#   - Verificar se o source do M4 está íntegro (configure presente).
#   - Verificar se há um GCC utilizável (toolchain final) no ambiente.
#   - Limpar artefatos de configure em caso de ADM_FORCE_REBUILD=1.

set -euo pipefail

###############################################################################
# ROOTFS / BUILD_ROOT / BUILD_DIR
###############################################################################

ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[m4/pre_build] ROOTFS detectado: ${ROOTFS}"

# A partir do ROOTFS (ex.: /opt/adm/rootfs-glibc ou /opt/adm/rootfs-musl)
last="${ROOTFS##*/}"
suffix=""
if [[ "${last}" == rootfs* ]]; then
  suffix="${last#rootfs}"
fi
adm_base="${ROOTFS%/*}"

# BUILD_ROOT segue o padrão do adm.sh: "${ADM_ROOT}/build${suffix}"
BUILD_ROOT="${adm_base}/build${suffix}"

# Pacote completo (ex.: system/m4)
PKG_FULL="${ADM_HOOK_PKG:-system/m4}"

# BUILD_DIR = "${ADM_BUILD_ROOT}/build/${full}"
BUILD_DIR="${BUILD_ROOT}/build/${PKG_FULL}"

echo "[m4/pre_build] BUILD_ROOT reconstruído: ${BUILD_ROOT}"
echo "[m4/pre_build] Diretório de build do pacote: ${BUILD_DIR}"

###############################################################################
# Sanity-check do diretório de build e do source
###############################################################################

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "[m4/pre_build] ERRO: diretório de build ${BUILD_DIR} não existe." >&2
  echo "[m4/pre_build]        Verifique a fase de extract/patch do adm.sh." >&2
  exit 1
fi

if [[ ! -f "${BUILD_DIR}/configure" ]]; then
  echo "[m4/pre_build] ERRO: 'configure' não encontrado em ${BUILD_DIR}." >&2
  echo "[m4/pre_build]        Verifique se o tarball m4-${PKG_VERSION:-1.4.20}.tar.xz foi extraído corretamente." >&2
  exit 1
fi

###############################################################################
# Verificação de toolchain (GCC) para compilar o M4
###############################################################################

USR_BIN="${ROOTFS}/usr/bin"

echo "[m4/pre_build] Verificando GCC em: ${USR_BIN}"

gcc_candidate=""

if [[ -x "${USR_BIN}/gcc" ]]; then
  gcc_candidate="${USR_BIN}/gcc"
elif command -v gcc >/dev/null 2>&1; then
  gcc_candidate="$(command -v gcc)"
fi

if [[ -z "${gcc_candidate}" ]]; then
  echo "[m4/pre_build] ERRO: nenhum GCC encontrado (nem ${USR_BIN}/gcc nem no PATH)." >&2
  echo "[m4/pre_build]        Certifique-se de que o toolchain final já foi instalado." >&2
  exit 1
fi

echo "[m4/pre_build] GCC detectado para build do M4: ${gcc_candidate}"

###############################################################################
# Limpeza agressiva em caso de ADM_FORCE_REBUILD=1
###############################################################################

FORCE_REBUILD="${ADM_FORCE_REBUILD:-0}"

if [[ "${FORCE_REBUILD}" = "1" ]]; then
  echo "[m4/pre_build] ADM_FORCE_REBUILD=1 -> limpando artefatos antigos em ${BUILD_DIR}"

  for f in config.cache config.log config.status; do
    if [[ -f "${BUILD_DIR}/${f}" ]]; then
      echo "[m4/pre_build] Removendo ${BUILD_DIR}/${f}"
      rm -f "${BUILD_DIR}/${f}"
    fi
  done

  if [[ -f "${BUILD_DIR}/Makefile" ]]; then
    echo "[m4/pre_build] Removendo Makefile de topo em ${BUILD_DIR}/Makefile"
    rm -f "${BUILD_DIR}/Makefile"
  fi
fi

###############################################################################
# Logs de ambiente
###############################################################################

PROFILE="${ADM_PROFILE:-default}"
TRIPLET="${TARGET_TRIPLET:-native}"

echo "[m4/pre_build] Perfil ADM (ADM_PROFILE): ${PROFILE}"
echo "[m4/pre_build] TARGET_TRIPLET (se definido): ${TRIPLET}"

CURRENT_PATH="${PATH:-/usr/bin:/bin}"
echo "[m4/pre_build] PATH atual no contexto do hook:"
echo "  ${CURRENT_PATH}"

echo "[m4/pre_build] Sanity-check concluído. Ambiente pronto para build do M4 1.4.20."
exit 0
