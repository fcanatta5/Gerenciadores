#!/usr/bin/env bash
# Hook pre_build para Linux 6.17.9 - API Headers
#
# Executado após fetch/extract e antes de build/install.
# Objetivos:
#   - Reconstruir BUILD_ROOT/BUILD_DIR como o adm.sh.
#   - Fazer sanity-check do diretório de build e do Makefile.
#   - Logar ARCH que será usado.

set -euo pipefail

###############################################################################
# Descoberta de ROOTFS / BUILD_ROOT / BUILD_DIR
###############################################################################

# ROOTFS passado pelo adm.sh:
ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[linux-api-headers/pre_build] ROOTFS detectado: ${ROOTFS}"

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

# Pacote completo (ex.: system/linux-api-headers)
PKG_FULL="${ADM_HOOK_PKG:-system/linux-api-headers}"

# BUILD_DIR = "${ADM_BUILD_ROOT}/build/${full}"
BUILD_DIR="${BUILD_ROOT}/build/${PKG_FULL}"

echo "[linux-api-headers/pre_build] BUILD_ROOT reconstruído: ${BUILD_ROOT}"
echo "[linux-api-headers/pre_build] Diretório de build do pacote: ${BUILD_DIR}"

###############################################################################
# Sanity-check do diretório de build
###############################################################################

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "[linux-api-headers/pre_build] ERRO: diretório de build ${BUILD_DIR} não existe." >&2
  echo "[linux-api-headers/pre_build]        Verifique a fase de extract do adm.sh." >&2
  exit 1
fi

if [[ ! -f "${BUILD_DIR}/Makefile" ]]; then
  echo "[linux-api-headers/pre_build] ERRO: Makefile não encontrado em ${BUILD_DIR}." >&2
  echo "[linux-api-headers/pre_build]        Verifique se o tarball do kernel foi extraído corretamente." >&2
  exit 1
fi

KARCH="${PKG_KARCH:-${ADM_KERNEL_ARCH:-${ADM_TARGET_ARCH:-x86_64}}}"
PROFILE="${ADM_PROFILE:-default}"
TRIPLET="${TARGET_TRIPLET:-native}"

echo "[linux-api-headers/pre_build] Perfil ADM (ADM_PROFILE): ${PROFILE}"
echo "[linux-api-headers/pre_build] TARGET_TRIPLET: ${TRIPLET}"
echo "[linux-api-headers/pre_build] ARCH do kernel (KARCH): ${KARCH}"

echo "[linux-api-headers/pre_build] Sanity-check concluído. Ambiente pronto para build dos API Headers."
exit 0
