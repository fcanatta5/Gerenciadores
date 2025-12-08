#!/usr/bin/env bash

# Pacote: GCC 15.2.0 (toolchain final, C e C++)
PKG_NAME="gcc-15.2.0"
PKG_VERSION="15.2.0"
PKG_CATEGORY="base"
PKG_SUMMARY="GNU Compiler Collection 15.2.0 (C e C++)"
PKG_LICENSE="GPL-3.0-or-later"

# URLs das fontes: GCC + dependências embutidas (GMP, MPFR, MPC)
# (checksums confirmados em distros grandes / upstream)
# gcc-15.2.0.tar.xz       -> sha256 438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e 
# mpfr-4.2.2.tar.xz       -> sha256 b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01 
# gmp-6.3.0.tar.xz        -> sha256 a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898 
# mpc-1.3.1.tar.gz        -> sha256 ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8 

PKG_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz"
  "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
  "https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"
)

PKG_SHA256S=(
  "438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e"
  "b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01"
  "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"
  "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8"
)

# Ajuste conforme sua árvore de pacotes real, se quiser dependências explícitas
# (binutils final, libc, gmp, mpfr, mpc já instalados no sysroot).
PKG_DEPENDS=(
  # "toolchain/binutils-2.45.1"
  # "libs/gmp-6.3.0"
  # "libs/mpfr-4.2.2"
  # "libs/mpc-1.3.1"
  # "libc/glibc-2.x" ou "libc/musl-1.2.x"
)

# Opções adicionais de ./configure
# O ADM já passa --host/--build/--prefix/--sysconfdir/--localstatedir
# via ADM_CONFIGURE_ARGS_COMMON. Aqui só acrescentamos o que é específico do GCC.
PKG_CONFIGURE_OPTS=(
  "LD=ld"
  "--target=${TARGET_TRIPLET}"
  "--with-sysroot=${ADM_SYSROOT:-${ADM_ROOTFS}}"
  "--enable-languages=c,c++"
  "--enable-default-pie"
  "--enable-default-ssp"
  "--enable-host-pie"
  "--disable-multilib"
  "--disable-bootstrap"
  "--disable-fixincludes"
  "--with-system-zlib"
)

# Ajustes específicos para musl (evita problemas com libsanitizer etc.)
if [[ "${ADM_PROFILE:-glibc}" == "musl" ]]; then
  PKG_CONFIGURE_OPTS+=(
    "--disable-libsanitizer"
  )
fi
