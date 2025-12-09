#!/usr/bin/env bash
# Hook pre_build para GCC 15.2.0 - Toolchain final
#
# Executado após fetch/extract e antes de configure/build.
# Objetivos:
#   - Reconstruir BUILD_ROOT/BUILD_DIR como o adm.sh.
#   - Injetar gmp/mpfr/mpc na árvore do GCC (in-tree build).
#   - Verificar glibc + headers do Linux no ROOTFS.
#   - Verificar binutils final em /usr/bin.
#   - Limpar subdir build/ em caso de ADM_FORCE_REBUILD=1.

set -euo pipefail

###############################################################################
# Descoberta de ROOTFS / BUILD_ROOT / BUILD_DIR / CACHE
###############################################################################

ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[gcc-final/pre_build] ROOTFS detectado: ${ROOTFS}"

# A partir do ROOTFS (ex.: /opt/adm/rootfs-glibc)
last="${ROOTFS##*/}"
suffix=""
if [[ "${last}" == rootfs* ]]; then
  suffix="${last#rootfs}"
fi
adm_base="${ROOTFS%/*}"

# BUILD_ROOT segue o padrão do adm.sh: "${ADM_ROOT}/build${suffix}"
BUILD_ROOT="${adm_base}/build${suffix}"

# Pacote completo (ex.: toolchain/gcc)
PKG_FULL="${ADM_HOOK_PKG:-toolchain/gcc}"

# BUILD_DIR = "${ADM_BUILD_ROOT}/build/${full}"
BUILD_DIR="${BUILD_ROOT}/build/${PKG_FULL}"

echo "[gcc-final/pre_build] BUILD_ROOT reconstruído: ${BUILD_ROOT}"
echo "[gcc-final/pre_build] Diretório de build do pacote: ${BUILD_DIR}"

# Diretório de cache (ADM_CACHE_DIR = "${ADM_ROOT}/cache")
ADM_CACHE_DIR="${adm_base}/cache"
echo "[gcc-final/pre_build] Diretório de cache do ADM: ${ADM_CACHE_DIR}"

###############################################################################
# Sanity-check do diretório de build
###############################################################################

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "[gcc-final/pre_build] ERRO: diretório de build ${BUILD_DIR} não existe." >&2
  echo "[gcc-final/pre_build]        Verifique a fase de extract do adm.sh para o tarball do GCC." >&2
  exit 1
fi

if [[ ! -f "${BUILD_DIR}/config.guess" ]]; then
  echo "[gcc-final/pre_build] ERRO: config.guess não encontrado em ${BUILD_DIR}." >&2
  echo "[gcc-final/pre_build]        O source do GCC parece incompleto." >&2
  exit 1
fi

###############################################################################
# Injeção de gmp, mpfr, mpc (in-tree build)
###############################################################################

GMP_VERSION="6.3.0"
MPFR_VERSION="4.2.1"
MPC_VERSION="1.3.1"

inject_prereq() {
  local name="$1"   # gmp / mpfr / mpc
  local ver="$2"    # versão
  local ext="$3"    # extensão do tar: tar.xz / tar.gz

  local tarball="${ADM_CACHE_DIR}/${name}-${ver}.${ext}"
  local src_dir="${BUILD_DIR}/${name}-${ver}"
  local dst_dir="${BUILD_DIR}/${name}"

  if [[ -d "${dst_dir}" ]]; then
    echo "[gcc-final/pre_build] ${name} já presente em ${dst_dir}; não será reinjetado."
    return 0
  fi

  if [[ ! -f "${tarball}" ]]; then
    echo "[gcc-final/pre_build] ERRO: tarball de ${name} não encontrado: ${tarball}" >&2
    echo "[gcc-final/pre_build]        Certifique-se de que o fetch baixou todas as fontes." >&2
    exit 1
  fi

  echo "[gcc-final/pre_build] Injetando ${name}-${ver} em ${BUILD_DIR}..."

  tar -xf "${tarball}" -C "${BUILD_DIR}"

  if [[ ! -d "${src_dir}" ]]; then
    echo "[gcc-final/pre_build] ERRO: diretório esperado não encontrado após extração: ${src_dir}" >&2
    exit 1
  fi

  mv "${src_dir}" "${dst_dir}"
  echo "[gcc-final/pre_build] ${name}-${ver} movido para ${dst_dir}."
}

inject_prereq "gmp"  "${GMP_VERSION}"  "tar.xz"
inject_prereq "mpfr" "${MPFR_VERSION}" "tar.xz"
inject_prereq "mpc"  "${MPC_VERSION}"  "tar.gz"

###############################################################################
# Verificação de glibc + Linux headers no ROOTFS
###############################################################################

INCLUDE_DIR="${ROOTFS}/usr/include"
LIB_DIR_1="${ROOTFS}/usr/lib"
LIB_DIR_2="${ROOTFS}/lib"

echo "[gcc-final/pre_build] Verificando headers e glibc em ROOTFS:"

if [[ ! -d "${INCLUDE_DIR}" ]]; then
  echo "[gcc-final/pre_build] ERRO: diretório ${INCLUDE_DIR} não existe." >&2
  echo "[gcc-final/pre_build]        Você instalou linux-api-headers e glibc-pass1 (ou final)?" >&2
  exit 1
fi

if [[ ! -d "${INCLUDE_DIR}/linux" ]]; then
  echo "[gcc-final/pre_build] ERRO: diretório ${INCLUDE_DIR}/linux não encontrado." >&2
  echo "[gcc-final/pre_build]        Os headers do kernel parecem não estar instalados." >&2
  exit 1
fi

if [[ ! -d "${LIB_DIR_1}" && ! -d "${LIB_DIR_2}" ]]; then
  echo "[gcc-final/pre_build] ERRO: nem ${LIB_DIR_1} nem ${LIB_DIR_2} existem." >&2
  echo "[gcc-final/pre_build]        A glibc não parece instalada corretamente." >&2
  exit 1
fi

###############################################################################
# Verificação do binutils final em /usr
###############################################################################

BINUTILS_BIN="${ROOTFS}/usr/bin"

echo "[gcc-final/pre_build] Verificando binutils em: ${BINUTILS_BIN}"

if [[ ! -d "${BINUTILS_BIN}" ]]; then
  echo "[gcc-final/pre_build] ERRO: diretório ${BINUTILS_BIN} não existe." >&2
  echo "[gcc-final/pre_build]        O binutils final já foi instalado em /usr?" >&2
  exit 1
fi

if [[ ! -x "${BINUTILS_BIN}/ld" ]] || [[ ! -x "${BINUTILS_BIN}/as" ]]; then
  echo "[gcc-final/pre_build] ERRO: ld/as não encontrados ou não executáveis em ${BINUTILS_BIN}." >&2
  exit 1
fi

###############################################################################
# Limpeza agressiva do subdir build em caso de ADM_FORCE_REBUILD=1
###############################################################################

FORCE_REBUILD="${ADM_FORCE_REBUILD:-0}"

if [[ "${FORCE_REBUILD}" = "1" ]]; then
  if [[ -d "${BUILD_DIR}/build" ]]; then
    echo "[gcc-final/pre_build] ADM_FORCE_REBUILD=1 -> removendo ${BUILD_DIR}/build."
    rm -rf "${BUILD_DIR}/build"
  fi
fi

###############################################################################
# Logs adicionais de ambiente
###############################################################################

PROFILE="${ADM_PROFILE:-default}"
TRIPLET="${TARGET_TRIPLET:-native}"
TARGET_TGT="${PKG_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu}"

echo "[gcc-final/pre_build] Perfil ADM (ADM_PROFILE): ${PROFILE}"
echo "[gcc-final/pre_build] TARGET_TRIPLET (se definido): ${TRIPLET}"
echo "[gcc-final/pre_build] TARGET_TGT (toolchain): ${TARGET_TGT}"

CURRENT_PATH="${PATH:-/usr/bin:/bin}"
echo "[gcc-final/pre_build] PATH atual no contexto do hook:"
echo "  ${CURRENT_PATH}"

echo "[gcc-final/pre_build] Sanity-check + injeção de prereqs concluídos. Ambiente pronto para build do GCC final."
exit 0
