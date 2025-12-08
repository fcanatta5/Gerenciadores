#!/usr/bin/env bash
# toolchain/libstdc++-pass1/libstdc++-pass1.sh
# Libstdc++ from GCC-15.2.0 (Pass 1) para toolchain temporário em /tools

PKG_NAME="libstdcxx"
PKG_VERSION="15.2.0"
PKG_CATEGORY="toolchain"

# Usamos o tarball oficial do GCC-15.2.0
PKG_URL="https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz"
PKG_SHA256="438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e"

# Ordem lógica do LFS: depois de gcc-pass1 + glibc-pass1
PKG_DEPENDS=(
  "toolchain/gcc-pass1"
  "toolchain/glibc-pass1"
)

###############################################################################
# Perfil / arquitetura -> triplet alvo (igual gcc-pass1)
###############################################################################

_adm_profile="${ADM_PROFILE:-glibc}"
_adm_arch="${ADM_TARGET_ARCH:-x86_64}"

case "${_adm_profile}" in
  glibc|aggressive|musl)
    ;;
  *)
    echo "libstdc++-pass1: ADM_PROFILE='${_adm_profile}' inválido (esperado: glibc, musl ou aggressive)." >&2
    exit 1
    ;;
esac

case "${_adm_arch}-${_adm_profile}" in
  x86_64-glibc|x86_64-aggressive)
    LIBSTDCXX_TARGET_TRIPLET="x86_64-linux-gnu"
    ;;
  x86_64-musl)
    LIBSTDCXX_TARGET_TRIPLET="x86_64-linux-musl"
    ;;
  aarch64-glibc|aarch64-aggressive)
    LIBSTDCXX_TARGET_TRIPLET="aarch64-linux-gnu"
    ;;
  aarch64-musl)
    LIBSTDCXX_TARGET_TRIPLET="aarch64-linux-musl"
    ;;
  *)
    LIBSTDCXX_TARGET_TRIPLET="${_adm_arch}-linux-${_adm_profile}"
    ;;
esac

# avisa o ADM que o target deste pacote é esse triplet
PKG_TARGET_TRIPLET="${LIBSTDCXX_TARGET_TRIPLET}"

###############################################################################
# Opções de configuração (baseado em LFS 12.4 - Libstdc++ from GCC-15.2.0)
###############################################################################
# No LFS:
#   ../libstdc++-v3/configure \
#       --host=$LFS_TGT       \
#       --build=$(../config.guess) \
#       --prefix=/usr         \
#       --disable-multilib    \
#       --disable-nls         \
#       --disable-libstdcxx-pch \
#       --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/15.2.0
#
# Aqui, BUILD/HOST vêm de ADM_CONFIGURE_ARGS_COMMON, então só
# adicionamos os flags específicos da libstdc++.

PKG_CONFIGURE_OPTS=(
  "--prefix=/usr"
  "--disable-multilib"
  "--disable-nls"
  "--disable-libstdcxx-pch"
  "--with-gxx-include-dir=/tools/${LIBSTDCXX_TARGET_TRIPLET}/include/c++/15.2.0"
)

PKG_CFLAGS_EXTRA="-O2 -pipe"
PKG_LDFLAGS_EXTRA=""

PKG_MAKE_OPTS=()
PKG_MAKE_INSTALL_OPTS=()
