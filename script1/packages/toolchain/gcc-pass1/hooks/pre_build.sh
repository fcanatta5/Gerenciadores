#!/usr/bin/env bash
# Hook pre_build para GCC 15.2.0 - Pass 1
#
# Executado após o fetch/extract e antes de configure/build.
# Objetivos:
#   - Garantir /tools e /tools/bin dentro do ROOTFS.
#   - Reconstruir BUILD_ROOT/BUILD_DIR como o adm.sh.
#   - Injetar gmp, mpfr e mpc na árvore de fontes do GCC (in-tree build).
#   - Fazer sanity-check básico do ambiente.

set -euo pipefail

###############################################################################
# Descoberta de ROOTFS / BUILD_ROOT / BUILD_DIR / CACHE
###############################################################################

# ROOTFS passado pelo adm.sh:
ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[gcc-pass1/pre_build] ROOTFS detectado: ${ROOTFS}"

# A partir do ROOTFS (ex.: /opt/adm/rootfs-glibc),
#   - base   = /opt/adm
#   - last   = rootfs-glibc
#   - suffix = -glibc
last="${ROOTFS##*/}"
suffix=""
if [[ "${last}" == rootfs* ]]; then
  suffix="${last#rootfs}"
fi
adm_base="${ROOTFS%/*}"

# Reconstrói BUILD_ROOT como o adm.sh:
#   ADM_BUILD_ROOT="${ADM_ROOT}/build${suffix}"
BUILD_ROOT="${adm_base}/build${suffix}"

# Pacote completo (ex.: toolchain/gcc-pass1)
PKG_FULL="${ADM_HOOK_PKG:-toolchain/gcc-pass1}"

# BUILD_DIR = "${ADM_BUILD_ROOT}/build/${full}"
BUILD_DIR="${BUILD_ROOT}/build/${PKG_FULL}"

echo "[gcc-pass1/pre_build] BUILD_ROOT reconstruído: ${BUILD_ROOT}"
echo "[gcc-pass1/pre_build] Diretório de build do pacote: ${BUILD_DIR}"

# Reconstrói CACHE do ADM (ADM_CACHE_DIR="${ADM_ROOT}/cache")
ADM_CACHE_DIR="${adm_base}/cache"
echo "[gcc-pass1/pre_build] Diretório de cache do ADM: ${ADM_CACHE_DIR}"

###############################################################################
# Garantia de /tools dentro do ROOTFS
###############################################################################

TOOLS_DIR="${ROOTFS}/tools"
TOOLS_BIN="${TOOLS_DIR}/bin"

echo "[gcc-pass1/pre_build] Diretório /tools em ROOTFS: ${TOOLS_DIR}"

if [[ ! -d "${TOOLS_DIR}" ]]; then
  echo "[gcc-pass1/pre_build] /tools não encontrado em ${ROOTFS}. Criando diretório..."
  mkdir -p "${TOOLS_DIR}"
fi

if [[ ! -d "${TOOLS_BIN}" ]]; then
  echo "[gcc-pass1/pre_build] /tools/bin não encontrado em ${ROOTFS}. Criando diretório..."
  mkdir -p "${TOOLS_BIN}"
fi

###############################################################################
# Sanity-check do diretório de build
###############################################################################

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "[gcc-pass1/pre_build] ERRO: diretório de build ${BUILD_DIR} não existe." >&2
  echo "[gcc-pass1/pre_build]        Verifique a fase de extract do adm.sh." >&2
  exit 1
fi

if [[ ! -f "${BUILD_DIR}/configure" ]]; then
  echo "[gcc-pass1/pre_build] ERRO: 'configure' não encontrado em ${BUILD_DIR}." >&2
  echo "[gcc-pass1/pre_build]        Verifique a extração do tarball do GCC." >&2
  exit 1
fi

###############################################################################
# Injeção de gmp, mpfr, mpc (in-tree build)
###############################################################################

# Versões devem bater com o build.sh. Se você ajustar lá, ajuste aqui também.
GMP_VERSION="6.3.0"
MPFR_VERSION="4.2.1"
MPC_VERSION="1.3.1"

# Função auxiliar para injetar um prereq
inject_prereq() {
  local name="$1"   # gmp / mpfr / mpc
  local ver="$2"    # versão
  local ext="$3"    # extensão do tar: tar.xz / tar.gz

  local tarball="${ADM_CACHE_DIR}/${name}-${ver}.${ext}"
  local src_dir="${BUILD_DIR}/${name}-${ver}"
  local dst_dir="${BUILD_DIR}/${name}"

  if [[ -d "${dst_dir}" ]]; then
    echo "[gcc-pass1/pre_build] ${name} já presente em ${dst_dir}; não será reinjetado."
    return 0
  fi

  if [[ ! -f "${tarball}" ]]; then
    echo "[gcc-pass1/pre_build] ERRO: tarball do ${name} não encontrado: ${tarball}" >&2
    echo "[gcc-pass1/pre_build]        Certifique-se de que o fetch baixou todas as fontes." >&2
    exit 1
  fi

  echo "[gcc-pass1/pre_build] Injetando ${name}-${ver} em ${BUILD_DIR}..."

  # Extração no diretório de build do GCC
  tar -xf "${tarball}" -C "${BUILD_DIR}"

  if [[ ! -d "${src_dir}" ]]; then
    echo "[gcc-pass1/pre_build] ERRO: diretório esperado não encontrado após extração: ${src_dir}" >&2
    exit 1
  fi

  mv "${src_dir}" "${dst_dir}"
  echo "[gcc-pass1/pre_build] ${name}-${ver} movido para ${dst_dir}."
}

inject_prereq "gmp"  "${GMP_VERSION}"  "tar.xz"
inject_prereq "mpfr" "${MPFR_VERSION}" "tar.xz"
inject_prereq "mpc"  "${MPC_VERSION}"  "tar.gz"

###############################################################################
# Informações de ambiente e avisos úteis
###############################################################################

PROFILE="${ADM_PROFILE:-default}"
TRIPLET="${TARGET_TRIPLET:-native}"

echo "[gcc-pass1/pre_build] Perfil ADM (ADM_PROFILE): ${PROFILE}"
echo "[gcc-pass1/pre_build] TARGET_TRIPLET (se definido): ${TRIPLET}"

CURRENT_PATH="${PATH:-/usr/bin:/bin}"
echo "[gcc-pass1/pre_build] PATH atual no contexto do hook:"
echo "  ${CURRENT_PATH}"

if ! grep -q "/tools/bin" <<<"${CURRENT_PATH}"; then
  echo "[gcc-pass1/pre_build] AVISO: '/tools/bin' não aparece no PATH atual."
  echo "[gcc-pass1/pre_build]         No contexto interno do adm.sh isso pode ser ok,"
  echo "[gcc-pass1/pre_build]         mas para usar o toolchain em /tools interativamente,"
  echo "[gcc-pass1/pre_build]         você provavelmente vai querer adicioná-lo ao PATH."
fi

echo "[gcc-pass1/pre_build] Sanity-check e injeção de prereqs concluídos. Ambiente pronto para o build do GCC Pass 1."
exit 0
