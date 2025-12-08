#!/usr/bin/env bash
# Receita ADM para GCC 15.2.0 - Pass 1 (toolchain inicial em /tools)

PKG_NAME="gcc-pass1"
PKG_VERSION="15.2.0"

# URLs oficiais do GCC 15.2.0
PKG_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
)

# SHA256 do tarball principal (confira no seu mirror se quiser):
# gcc-15.2.0.tar.xz → SHA256 oficial em https://ftp.gnu.org
PKG_SHA256S=(
  "3b734d1fc0c158f5ad7881e5341c04a7e7a1a9ad4550f8e910a2c8421c0db172"
)

# Dependências (ajuste conforme sua árvore)
# Em Pass 1, você precisa de:
# - binutils-pass1 (já em /tools)
# - headers mínimos (glibc headers ou similares) se for fazer um cross já com libc
PKG_DEPENDS=(
  "core/binutils-pass1"
  # "core/linux-headers"   # se você tiver
  # "core/glibc-headers"   # opcional, depende da estratégia
)

# Se quiser forçar explicitamente um target estilo LFS:
# Exemplo para x86_64:
# PKG_TARGET_TRIPLET="x86_64-lfs-linux-gnu"
# Se deixar sem, o adm calcula com base em ADM_TARGET_ARCH + ADM_PROFILE.

# GCC precisa de bibliotecas de suporte no source tree (gmp, mpfr, mpc etc.)
# Em ambiente LFS-like, costuma-se usar as cópias internas do tarball do GCC,
# ou apontar para pacotes externos. Aqui vou assumir uso das libs internas que
# vêm junto no tarball (GCC 15.x oferece --with-gmp=..., mas o caminho padrão
# já resolve se você extrair gmp/mpfr/mpc na árvore do GCC).
#
# Se você quiser usar libs externas, adicione PKG_DEPENDS e configure:
#   --with-gmp=/algum/caminho  etc.

# PREFIX de Pass 1: /tools (isolado do sistema final)
PKG_CONFIGURE_OPTS=(
  "--prefix=/tools"
  "--build=${ADM_TARGET_ARCH}-pc-linux-gnu"  # ajuste conforme host se quiser
  "--host=${ADM_TARGET_ARCH}-pc-linux-gnu"
  "--target=${TARGET_TRIPLET}"              # definido pelo adm em setup_profiles
  "--with-sysroot=${ADM_ROOTFS}"
  "--with-newlib"
  "--without-headers"
  "--disable-nls"
  "--disable-shared"
  "--disable-multilib"
  "--disable-decimal-float"
  "--disable-libatomic"
  "--disable-libgomp"
  "--disable-libquadmath"
  "--disable-libssp"
  "--disable-libvtv"
  "--disable-libstdcxx"
  "--enable-languages=c"
)

# GCC Pass 1 não precisa de C++ ainda; só C.
# Flags extras, se quiser "segurar" otimizações no Pass 1:
# PKG_CFLAGS_EXTRA="-O2"
# PKG_LDFLAGS_EXTRA=""

# Como o adm.sh faz build diretamente dentro de ${build_dir}, e o
# binutils recomenda out-of-source build, você pode optar por
# reconfigurar o adm para criar um subdir "build" dentro de gcc, mas
# aqui vamos assumir build-in-tree mesmo, para simplificar.
#
# Se você QUISER explicitamente out-of-source, o caminho é usar um
# hook pre_build que crie um subdir e rode configure/make lá, mas aí o
# adm precisa ser adaptado para não rodar ./configure na raiz.
