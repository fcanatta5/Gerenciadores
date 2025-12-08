#!/usr/bin/env bash
# toolchain/gcc-pass1/gcc-pass1.sh
# GCC-15.2.0 - Pass 1 (toolchain temporário em /tools)

set -euo pipefail

PKG_NAME="gcc-pass1"
PKG_VERSION="15.2.0"
PKG_CATEGORY="toolchain"

# Fonte principal do GCC
PKG_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz"
  "https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz"
  "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
  "https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"
)

# SHA256 correspondentes (na mesma ordem de PKG_URLS)
PKG_SHA256S=(
  "438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e" # gcc-15.2.0.tar.xz 
  "b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01" # mpfr-4.2.2.tar.xz 
  "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898" # gmp-6.3.0.tar.xz 
  "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8" # mpc-1.3.1.tar.gz 
)

# Binutils-pass1 precisa existir primeiro
PKG_DEPENDS=(
  "toolchain/binutils-pass1"
)

###############################################################################
# Detecção de perfil (glibc/musl) e ARCH para definir o triplet alvo
###############################################################################

_adm_profile="${ADM_PROFILE:-glibc}"
_adm_arch="${ADM_TARGET_ARCH:-x86_64}"

case "${_adm_profile}" in
  glibc|aggressive|musl)
    ;;
  *)
    echo "gcc-pass1: ADM_PROFILE='${_adm_profile}' inválido (esperado: glibc, musl ou aggressive)" >&2
    exit 1
    ;;
esac

# Mapeamento alinhado com o setup_profiles do adm
case "${_adm_arch}-${_adm_profile}" in
  x86_64-glibc|x86_64-aggressive)
    GCC_PASS1_TARGET_TRIPLET="x86_64-linux-gnu"
    ;;
  x86_64-musl)
    GCC_PASS1_TARGET_TRIPLET="x86_64-linux-musl"
    ;;
  aarch64-glibc|aarch64-aggressive)
    GCC_PASS1_TARGET_TRIPLET="aarch64-linux-gnu"
    ;;
  aarch64-musl)
    GCC_PASS1_TARGET_TRIPLET="aarch64-linux-musl"
    ;;
  *)
    # fallback genérico, se você adicionar novos perfis/arch no futuro
    GCC_PASS1_TARGET_TRIPLET="${_adm_arch}-linux-${_adm_profile}"
    ;;
esac

# Isso força o adm a usar este triplet para BUILD/HOST/TARGET
PKG_TARGET_TRIPLET="${GCC_PASS1_TARGET_TRIPLET}"

###############################################################################
# Opções de configuração (baseado no LFS 5.3 GCC-15.2.0 Pass 1) 
###############################################################################

# IMPORTANTE:
# - Prefixo /tools: toolchain temporário claramente separado do final.
# - --with-sysroot=${ADM_ROOTFS}: GCC aponta para o rootfs que o adm está gerando.
# - --with-newlib / --without-headers: não depende ainda de glibc/musl no target.
# - Desabilita libs e features que não precisamos no pass1.
# - Compila apenas C e C++ (como no LFS; C++ será útil depois para libstdc++).

PKG_CONFIGURE_OPTS=(
  "--target=${GCC_PASS1_TARGET_TRIPLET}"
  "--prefix=/tools"
  "--with-sysroot=${ADM_ROOTFS}"
  "--with-newlib"
  "--without-headers"
  "--enable-default-pie"
  "--enable-default-ssp"
  "--disable-nls"
  "--disable-shared"
  "--disable-multilib"
  "--disable-threads"
  "--disable-libatomic"
  "--disable-libgomp"
  "--disable-libquadmath"
  "--disable-libssp"
  "--disable-libvtv"
  "--disable-libstdcxx"
  "--enable-languages=c,c++"
)

# Deixa o adm controlar -jN
PKG_MAKE_OPTS=()
PKG_MAKE_INSTALL_OPTS=()

# Flags adicionais (se quiser tunar por perfil no futuro)
PKG_CFLAGS_EXTRA="-pipe"
PKG_LDFLAGS_EXTRA=""
