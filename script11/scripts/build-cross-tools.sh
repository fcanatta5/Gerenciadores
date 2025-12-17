#!/usr/bin/env bash
set -Eeuo pipefail

#############################################
# Cross Toolchain (x86_64-linux-musl) builder
# Prefix: /mnt/adm/tools
# Target: x86_64-linux-musl
#############################################

############
# VERSÕES  #
############
BINUTILS_VER="2.45.1"
GCC_VER="15.2.0"
LINUX_VER="6.18.1"
MUSL_VER="1.2.5"
BUSYBOX_VER="1.36.1"

#####################
# AJUSTES GERAIS    #
#####################
TARGET="x86_64-linux-musl"
TOP="/mnt/adm"
TOOLS="${TOP}/tools"
SRCS="${TOP}/sources"
BLD="${TOP}/build"
LOGS="${TOP}/logs"
STATE="${TOP}/.state"

# Paralelismo
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

# Controle (0/1)
CLEAN_BUILD_DIRS="${CLEAN_BUILD_DIRS:-0}"
KEEP_TARBALLS="${KEEP_TARBALLS:-1}"
BUILD_FINAL_GCC="${BUILD_FINAL_GCC:-1}"
BUILD_BUSYBOX_STATIC="${BUILD_BUSYBOX_STATIC:-1}"   # 1 = static (musl), 0 = dinâmico

# Saída
USE_COLOR="${USE_COLOR:-1}"

#####################
# URLs (Upstream)   #
#####################
# Binutils (GNU)
BINUTILS_TAR="binutils-${BINUTILS_VER}.tar.xz"
BINUTILS_URL="https://ftp.gnu.org/gnu/binutils/${BINUTILS_TAR}"

# GCC (oficial)
GCC_TAR="gcc-${GCC_VER}.tar.xz"
GCC_URL="https://gcc.gnu.org/pub/gcc/releases/gcc-${GCC_VER}/${GCC_TAR}"
GCC_SHA512_URL="https://gcc.gnu.org/pub/gcc/releases/gcc-${GCC_VER}/sha512.sum"

# Linux kernel (headers)
LINUX_TAR="linux-${LINUX_VER}.tar.xz"
LINUX_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${LINUX_TAR}"
LINUX_SHA256_ASC_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc"

# musl
MUSL_TAR="musl-${MUSL_VER}.tar.gz"
MUSL_URL="https://musl.libc.org/releases/${MUSL_TAR}"

# Patches musl-1.2.5 (Bootlin) - aplica todos do "series"
MUSL_PATCH_BASE="https://toolchains.bootlin.com/downloads/releases/sources/musl-${MUSL_VER}"
MUSL_PATCH_SERIES_URL="${MUSL_PATCH_BASE}/series"

# BusyBox (espelho com .sha256)
BUSYBOX_TAR="busybox-${BUSYBOX_VER}.tar.bz2"
BUSYBOX_URL="https://ftp.icm.edu.pl/packages/busybox/${BUSYBOX_TAR}"
BUSYBOX_SHA256_URL="https://ftp.icm.edu.pl/packages/busybox/${BUSYBOX_TAR}.sha256"

#####################
# SYSROOT           #
#####################
SYSROOT="${TOOLS}/${TARGET}"

#####################
# FUNÇÕES UTIL      #
#####################
ts() { date +"%Y-%m-%d %H:%M:%S"; }

c_reset="" c_red="" c_grn="" c_yel="" c_blu="" c_dim=""
if [[ "${USE_COLOR}" == "1" ]] && [[ -t 1 ]]; then
  c_reset=$'\033[0m'
  c_red=$'\033[31m'
  c_grn=$'\033[32m'
  c_yel=$'\033[33m'
  c_blu=$'\033[34m'
  c_dim=$'\033[2m'
fi

log()  { echo "${c_dim}[$(ts)]${c_reset} $*"; }
ok()   { echo "${c_grn}[$(ts)] OK:${c_reset} $*"; }
warn() { echo "${c_yel}[$(ts)] WARN:${c_reset} $*" >&2; }
die()  { echo "${c_red}[$(ts)] ERRO:${c_reset} $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Comando ausente: $1"; }

run_logged() {
  local name="$1"; shift
  local logfile="${LOGS}/${name}.log"
  log "Iniciando: ${name}"
  log "Log: ${logfile}"
  ( set -o pipefail; "$@" ) 2>&1 | tee "${logfile}"
  ok "Concluído: ${name}"
}

mark_done() { mkdir -p "${STATE}"; touch "${STATE}/$1.done"; }
is_done()   { [[ -f "${STATE}/$1.done" ]]; }

fetch() {
  local url="$1" out="$2"
  if [[ -f "${out}" ]]; then
    log "Já existe: ${out}"
    return 0
  fi
  need_cmd curl
  run_logged "fetch-$(basename "${out}")" curl -L --fail --retry 5 --retry-delay 2 -o "${out}.part" "${url}"
  mv -f "${out}.part" "${out}"
}

verify_sha512_sumfile() {
  local sumfile="$1" tarpath="$2"
  need_cmd sha512sum
  ( cd "$(dirname "${tarpath}")" && sha512sum -c <(grep -E " $(basename "${tarpath}")\$" "${sumfile}") ) \
    || die "Falha sha512: ${tarpath}"
}

verify_sha256_linefile() {
  local sha_file="$1" tarpath="$2"
  need_cmd sha256sum
  # Busybox .sha256 costuma ser "SHA256 (file) = ..." OU "hash  file". Tentamos ambos.
  local base="$(basename "${tarpath}")"
  local tmp="${sha_file}.normalized"
  if grep -qE '^[0-9a-f]{64}[[:space:]]+' "${sha_file}"; then
    cp -f "${sha_file}" "${tmp}"
  else
    # Extrai o hash do formato "SHA256 (file) = <hash>"
    awk -v f="${base}" '
      match($0, /SHA256 \('"${base}"'\) = ([0-9a-f]{64})/, a){ print a[1] "  " f }
    ' "${sha_file}" > "${tmp}" || true
  fi
  [[ -s "${tmp}" ]] || die "Não consegui normalizar sha256 para ${base} a partir de ${sha_file}"
  ( cd "$(dirname "${tarpath}")" && sha256sum -c "${tmp}" ) || die "Falha sha256: ${tarpath}"
}

verify_kernel_sha256sums_asc() {
  local asc="$1" tarpath="$2"
  need_cmd sha256sum
  # sha256sums.asc contém linhas "hash  filename" (com muitos arquivos).
  local base="$(basename "${tarpath}")"
  local line
  line="$(grep -E " ${base}\$" "${asc}" || true)"
  [[ -n "${line}" ]] || die "Não encontrei ${base} em ${asc}"
  ( cd "$(dirname "${tarpath}")" && printf "%s\n" "${line}" | sha256sum -c - ) \
    || die "Falha sha256 (kernel): ${tarpath}"
}

extract() {
  local tarball="$1" dest="$2"
  mkdir -p "${dest}"
  run_logged "extract-$(basename "${tarball}")" tar -xf "${tarball}" -C "${dest}"
}

ensure_dirs() {
  mkdir -p "${TOOLS}" "${SRCS}" "${BLD}" "${LOGS}" "${STATE}"
  mkdir -p "${SYSROOT}/usr" "${SYSROOT}/usr/include" "${SYSROOT}/usr/lib" "${SYSROOT}/lib"
}

host_sanity() {
  need_cmd make
  need_cmd tar
  need_cmd xz
  need_cmd bzip2
  need_cmd gzip
  need_cmd sed
  need_cmd awk
  need_cmd patch
  need_cmd gawk || true

  if [[ "$(id -u)" == "0" ]]; then
    warn "Executando como root. Isso funciona, mas é recomendável um usuário dedicado e permissões em ${TOP}."
  fi

  # Evita pegar /usr/local antes do prefix
  export PATH="${TOOLS}/bin:/usr/bin:/bin"
  export LC_ALL=C
  export MAKEFLAGS="-j${JOBS}"

  # flags conservadoras para toolchain temporária
  export CFLAGS="-O2 -pipe"
  export CXXFLAGS="-O2 -pipe"
}

cleanup_builddir() {
  [[ "${CLEAN_BUILD_DIRS}" == "1" ]] || return 0
  warn "Limpando diretórios de build (CLEAN_BUILD_DIRS=1)"
  rm -rf "${BLD:?}/"*
}

#############################
# BUILD: BINUTILS (pass1)   #
#############################
build_binutils_pass1() {
  local step="binutils-pass1"
  is_done "${step}" && { ok "${step} já feito (skip)"; return 0; }

  local tar="${SRCS}/${BINUTILS_TAR}"
  fetch "${BINUTILS_URL}" "${tar}"

  rm -rf "${BLD}/binutils-src" "${BLD}/binutils-build"
  mkdir -p "${BLD}/binutils-src" "${BLD}/binutils-build"
  extract "${tar}" "${BLD}/binutils-src"

  local srcdir
  srcdir="$(find "${BLD}/binutils-src" -maxdepth 1 -type d -name "binutils-${BINUTILS_VER}" | head -n1)"
  [[ -d "${srcdir}" ]] || die "src binutils não encontrado"

  run_logged "${step}-configure" bash -c "
    cd '${BLD}/binutils-build'
    '${srcdir}/configure' \
      --prefix='${TOOLS}' \
      --target='${TARGET}' \
      --with-sysroot='${SYSROOT}' \
      --disable-nls \
      --disable-werror
  "
  run_logged "${step}-make" bash -c "cd '${BLD}/binutils-build' && make"
  run_logged "${step}-install" bash -c "cd '${BLD}/binutils-build' && make install"

  mark_done "${step}"
}

#############################
# BUILD: GCC (pass1)        #
#############################
build_gcc_pass1() {
  local step="gcc-pass1"
  is_done "${step}" && { ok "${step} já feito (skip)"; return 0; }

  local tar="${SRCS}/${GCC_TAR}"
  local sha="${SRCS}/gcc-${GCC_VER}-sha512.sum"

  fetch "${GCC_URL}" "${tar}"
  fetch "${GCC_SHA512_URL}" "${sha}"
  verify_sha512_sumfile "${sha}" "${tar}"

  rm -rf "${BLD}/gcc-src" "${BLD}/gcc-build-pass1"
  mkdir -p "${BLD}/gcc-src" "${BLD}/gcc-build-pass1"
  extract "${tar}" "${BLD}/gcc-src"

  local srcdir
  srcdir="$(find "${BLD}/gcc-src" -maxdepth 1 -type d -name "gcc-${GCC_VER}" | head -n1)"
  [[ -d "${srcdir}" ]] || die "src gcc não encontrado"

  # Baixa prereqs do GCC (gmp/mpfr/mpc/isl) usando script oficial
  run_logged "${step}-prereqs" bash -c "cd '${srcdir}' && ./contrib/download_prerequisites"

  run_logged "${step}-configure" bash -c "
    cd '${BLD}/gcc-build-pass1'
    '${srcdir}/configure' \
      --prefix='${TOOLS}' \
      --target='${TARGET}' \
      --with-sysroot='${SYSROOT}' \
      --disable-nls \
      --disable-multilib \
      --disable-shared \
      --disable-threads \
      --enable-languages=c \
      --without-headers \
      --with-newlib \
      --disable-libatomic \
      --disable-libgomp \
      --disable-libquadmath \
      --disable-libsanitizer \
      --disable-libssp \
      --disable-libvtv \
      --disable-libstdcxx
  "
  run_logged "${step}-make" bash -c "cd '${BLD}/gcc-build-pass1' && make all-gcc all-target-libgcc"
  run_logged "${step}-install" bash -c "cd '${BLD}/gcc-build-pass1' && make install-gcc install-target-libgcc"

  mark_done "${step}"
}

#############################
# BUILD: Linux headers      #
#############################
build_linux_headers() {
  local step="linux-headers"
  is_done "${step}" && { ok "${step} já feito (skip)"; return 0; }

  local tar="${SRCS}/${LINUX_TAR}"
  local shaasc="${SRCS}/kernel-v6x-sha256sums.asc"

  fetch "${LINUX_URL}" "${tar}"
  fetch "${LINUX_SHA256_ASC_URL}" "${shaasc}"
  verify_kernel_sha256sums_asc "${shaasc}" "${tar}"

  rm -rf "${BLD}/linux-src"
  mkdir -p "${BLD}/linux-src"
  extract "${tar}" "${BLD}/linux-src"

  local srcdir
  srcdir="$(find "${BLD}/linux-src" -maxdepth 1 -type d -name "linux-${LINUX_VER}" | head -n1)"
  [[ -d "${srcdir}" ]] || die "src linux não encontrado"

  run_logged "${step}-install" bash -c "
    cd '${srcdir}'
    make mrproper
    make headers_install INSTALL_HDR_PATH='${SYSROOT}/usr'
  "

  mark_done "${step}"
}

#############################
# BUILD: musl + patches     #
#############################
apply_musl_patches_from_series() {
  local srcdir="$1"
  local series="${SRCS}/musl-${MUSL_VER}-series"
  fetch "${MUSL_PATCH_SERIES_URL}" "${series}"

  # Baixa cada patch listado no series e aplica na ordem
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    [[ "${p}" =~ ^# ]] && continue
    local url="${MUSL_PATCH_BASE}/${p}"
    local localp="${SRCS}/musl-${MUSL_VER}-${p}"
    fetch "${url}" "${localp}"
    run_logged "musl-patch-${p}" bash -c "cd '${srcdir}' && patch -p1 < '${localp}'"
  done < "${series}"
}

build_musl() {
  local step="musl"
  is_done "${step}" && { ok "${step} já feito (skip)"; return 0; }

  local tar="${SRCS}/${MUSL_TAR}"
  fetch "${MUSL_URL}" "${tar}"

  rm -rf "${BLD}/musl-src" "${BLD}/musl-build"
  mkdir -p "${BLD}/musl-src" "${BLD}/musl-build"
  extract "${tar}" "${BLD}/musl-src"

  local srcdir
  srcdir="$(find "${BLD}/musl-src" -maxdepth 1 -type d -name "musl-${MUSL_VER}" | head -n1)"
  [[ -d "${srcdir}" ]] || die "src musl não encontrado"

  # Patches (inclui hardening; cobre cenário "1.2.5 + patches de segurança")
  apply_musl_patches_from_series "${srcdir}"

  # Compila/instala musl no sysroot como /usr
  run_logged "${step}-configure" bash -c "
    cd '${BLD}/musl-build'
    CC='${TARGET}-gcc' \
    AR='${TARGET}-ar' \
    RANLIB='${TARGET}-ranlib' \
    '${srcdir}/configure' --prefix=/usr --target='${TARGET}'
  "
  run_logged "${step}-make" bash -c "cd '${BLD}/musl-build' && make"
  run_logged "${step}-install" bash -c "cd '${BLD}/musl-build' && make DESTDIR='${SYSROOT}' install"

  mark_done "${step}"
}

#############################
# BUILD: GCC final (pass2)  #
#############################
build_gcc_final() {
  local step="gcc-final"
  [[ "${BUILD_FINAL_GCC}" == "1" ]] || { warn "BUILD_FINAL_GCC=0, pulando gcc final"; return 0; }
  is_done "${step}" && { ok "${step} já feito (skip)"; return 0; }

  local tar="${SRCS}/${GCC_TAR}"
  [[ -f "${tar}" ]] || die "Tarball GCC não encontrado (era esperado em ${tar})"

  rm -rf "${BLD}/gcc-src-final" "${BLD}/gcc-build-final"
  mkdir -p "${BLD}/gcc-src-final" "${BLD}/gcc-build-final"
  extract "${tar}" "${BLD}/gcc-src-final"

  local srcdir
  srcdir="$(find "${BLD}/gcc-src-final" -maxdepth 1 -type d -name "gcc-${GCC_VER}" | head -n1)"
  [[ -d "${srcdir}" ]] || die "src gcc não encontrado"

  # prereqs novamente (idempotente)
  run_logged "${step}-prereqs" bash -c "cd '${srcdir}' && ./contrib/download_prerequisites"

  # Para evitar pegar headers/ libs errados
  export PATH="${TOOLS}/bin:/usr/bin:/bin"

  run_logged "${step}-configure" bash -c "
    cd '${BLD}/gcc-build-final'
    '${srcdir}/configure' \
      --prefix='${TOOLS}' \
      --target='${TARGET}' \
      --with-sysroot='${SYSROOT}' \
      --disable-nls \
      --disable-multilib \
      --enable-languages=c,c++ \
      --enable-shared \
      --enable-threads=posix
  "
  run_logged "${step}-make" bash -c "cd '${BLD}/gcc-build-final' && make"
  run_logged "${step}-install" bash -c "cd '${BLD}/gcc-build-final' && make install"

  mark_done "${step}"
}

#############################
# BUILD: BusyBox            #
#############################
build_busybox() {
  local step="busybox"
  is_done "${step}" && { ok "${step} já feito (skip)"; return 0; }

  local tar="${SRCS}/${BUSYBOX_TAR}"
  local sha="${SRCS}/${BUSYBOX_TAR}.sha256"
  fetch "${BUSYBOX_URL}" "${tar}"
  fetch "${BUSYBOX_SHA256_URL}" "${sha}"
  verify_sha256_linefile "${sha}" "${tar}"

  rm -rf "${BLD}/busybox-src"
  mkdir -p "${BLD}/busybox-src"
  extract "${tar}" "${BLD}/busybox-src"

  local srcdir
  srcdir="$(find "${BLD}/busybox-src" -maxdepth 1 -type d -name "busybox-${BUSYBOX_VER}" | head -n1)"
  [[ -d "${srcdir}" ]] || die "src busybox não encontrado"

  # Instalação em staging, não no rootfs
  local dest="${TOOLS}/busybox-rootfs"
  rm -rf "${dest}"
  mkdir -p "${dest}"

  run_logged "${step}-defconfig" bash -c "
    cd '${srcdir}'
    make distclean
    make defconfig
  "

  if [[ "${BUILD_BUSYBOX_STATIC}" == "1" ]]; then
    # habilita build static
    run_logged "${step}-static-enable" bash -c "
      cd '${srcdir}'
      sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config || true
      grep -q '^CONFIG_STATIC=y' .config || echo 'CONFIG_STATIC=y' >> .config
      make olddefconfig
    "
  fi

  # Força toolchain musl
  run_logged "${step}-make" bash -c "
    cd '${srcdir}'
    make CROSS_COMPILE='${TARGET}-' CC='${TARGET}-gcc'
  "
  run_logged "${step}-install" bash -c "
    cd '${srcdir}'
    make CONFIG_PREFIX='${dest}' install
  "

  ok "BusyBox instalado em: ${dest}"
  mark_done "${step}"
}

#############################
# TESTE RÁPIDO TOOLCHAIN    #
#############################
toolchain_smoketest() {
  local step="smoketest"
  is_done "${step}" && { ok "${step} já feito (skip)"; return 0; }

  local tcc="${TOOLS}/bin/${TARGET}-gcc"
  [[ -x "${tcc}" ]] || die "Compiler não encontrado: ${tcc}"

  local tmp="${BLD}/_smoketest"
  rm -rf "${tmp}"
  mkdir -p "${tmp}"

  cat > "${tmp}/hello.c" <<'EOF'
#include <stdio.h>
int main(void){ puts("hello musl toolchain"); return 0; }
EOF

  run_logged "${step}-build" bash -c "
    '${tcc}' --sysroot='${SYSROOT}' -o '${tmp}/hello' '${tmp}/hello.c'
    file '${tmp}/hello'
  "

  ok "Smoketest ok. Binário em ${tmp}/hello"
  mark_done "${step}"
}

#############################
# MAIN                      #
#############################
main() {
  ensure_dirs
  host_sanity

  log "============================================================"
  log "Cross-toolchain temporária em: ${TOOLS}"
  log "TARGET: ${TARGET}"
  log "SYSROOT: ${SYSROOT}"
  log "JOBS: ${JOBS}"
  log "Logs: ${LOGS}"
  log "Retomada: ${STATE}"
  log "============================================================"

  build_binutils_pass1
  build_gcc_pass1
  build_linux_headers
  build_musl
  build_gcc_final
  build_busybox
  toolchain_smoketest

  cleanup_builddir

  ok "Tudo pronto para continuar a construção do sistema."
  log "Sugestão: exporte PATH='${TOOLS}/bin:\$PATH' e use --sysroot='${SYSROOT}' ao compilar pacotes para o target."
  log "BusyBox staging: ${TOOLS}/busybox-rootfs"
}

main "$@"
