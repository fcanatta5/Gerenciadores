#!/usr/bin/env bash
# GCC 15.2.0 - Pass 1 (toolchain temporária)
# Target: x86_64-linux-gnu
# Prefix: /mnt/adm/tools (não suja o rootfs fora de /mnt/adm)
#
# Estratégia pass1 (estilo LFS):
# - cross compiler para $ADM_TGT
# - sem headers/libc do sistema final: --without-headers + --with-newlib
# - builda somente compiler + libgcc (all-gcc, all-target-libgcc)
# - instala somente gcc + libgcc (install-gcc, install-target-libgcc)

set -Eeuo pipefail
shopt -s nullglob

PKG_NAME="gcc"
PKG_VERSION="15.2.0-pass1"
PKG_CATEGORY="toolchain"

: "${ADM_MNT:=/mnt/adm}"
: "${ADM_TOOLS:=$ADM_MNT/tools}"
: "${ADM_TGT:=x86_64-linux-gnu}"

# Depende do binutils pass1 (use @ para versão conter "-pass1")
PKG_DEPENDS=(
  "binutils@2.45.1-pass1"
)

# Fontes: GCC + prereqs (embedded) gmp/mpfr/mpc/isl
PKG_SOURCES=(
  "https://gcc.gnu.org/pub/gcc/releases/gcc-15.2.0/gcc-15.2.0.tar.xz|sha256|438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e"
  "https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz|sha256|a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"
  "https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz|sha256|277807353a6726978996945af13e52829e3abd7a9a5b7fb2793894e18f1fcbb2"
  "https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz|sha256|ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8"
  "https://libisl.sourceforge.io/isl-0.26.tar.xz|sha256|a0b5cb06d24f9fa9e77b55fabbe9a3c94a336190345c2555f9915bb38e976504"
)

PKG_PATCHES=(
  # opcional
)

build() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"
  : "${ADM_TOOLS:?ADM_TOOLS não definido}"
  : "${ADM_MNT:?ADM_MNT não definido}"
  : "${ADM_TGT:?ADM_TGT não definido}"

  export PATH="$ADM_TOOLS/bin:$PATH"

  cd "$ADM_WORKDIR"

  local gcc_tar="$ADM_WORKDIR/sources/gcc-15.2.0.tar.xz"
  local gmp_tar="$ADM_WORKDIR/sources/gmp-6.3.0.tar.xz"
  local mpfr_tar="$ADM_WORKDIR/sources/mpfr-4.2.1.tar.xz"
  local mpc_tar="$ADM_WORKDIR/sources/mpc-1.3.1.tar.gz"
  local isl_tar="$ADM_WORKDIR/sources/isl-0.26.tar.xz"

  [[ -f "$gcc_tar" ]] || { echo "ERRO: gcc tarball não encontrado em $gcc_tar"; return 1; }
  [[ -f "$gmp_tar" ]] || { echo "ERRO: gmp tarball não encontrado em $gmp_tar"; return 1; }
  [[ -f "$mpfr_tar" ]] || { echo "ERRO: mpfr tarball não encontrado em $mpfr_tar"; return 1; }
  [[ -f "$mpc_tar" ]] || { echo "ERRO: mpc tarball não encontrado em $mpc_tar"; return 1; }
  [[ -f "$isl_tar" ]] || { echo "ERRO: isl tarball não encontrado em $isl_tar"; return 1; }

  rm -rf gcc-15.2.0 build-gcc-pass1
  tar -xf "$gcc_tar"

  # Embed prereqs dentro do source tree do GCC (evita depender de libs do host)
  tar -xf "$gmp_tar"
  tar -xf "$mpfr_tar"
  tar -xf "$mpc_tar"
  tar -xf "$isl_tar"

  rm -rf gcc-15.2.0/gmp gcc-15.2.0/mpfr gcc-15.2.0/mpc gcc-15.2.0/isl
  mv -f gmp-6.3.0   gcc-15.2.0/gmp
  mv -f mpfr-4.2.1  gcc-15.2.0/mpfr
  mv -f mpc-1.3.1   gcc-15.2.0/mpc
  mv -f isl-0.26    gcc-15.2.0/isl

  mkdir -p build-gcc-pass1
  cd build-gcc-pass1

  # Triplet do build system
  local build_triplet=""
  build_triplet="$("../gcc-15.2.0/config.guess")"

  # Pass1 (cross, sem headers):
  # - --with-newlib + --without-headers: evita procurar libc/headers do sysroot
  # - desliga tudo que puxa runtime pesado
  # - multilib off
  ../gcc-15.2.0/configure \
    --prefix="$ADM_TOOLS" \
    --target="$ADM_TGT" \
    --with-sysroot="$ADM_MNT" \
    --build="$build_triplet" \
    --with-newlib \
    --without-headers \
    --disable-nls \
    --disable-shared \
    --disable-multilib \
    --disable-threads \
    --disable-libatomic \
    --disable-libgomp \
    --disable-libquadmath \
    --disable-libssp \
    --disable-libvtv \
    --disable-libstdcxx \
    --disable-bootstrap \
    --enable-languages=c,c++ \
    --enable-initfini-array

  # Compila apenas o necessário no pass1
  make -j"$(nproc)" all-gcc
  make -j"$(nproc)" all-target-libgcc
}

install() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"
  : "${ADM_TOOLS:?ADM_TOOLS não definido}"
  : "${ADM_MNT:?ADM_MNT não definido}"
  : "${ADM_TGT:?ADM_TGT não definido}"

  export PATH="$ADM_TOOLS/bin:$PATH"

  cd "$ADM_WORKDIR/build-gcc-pass1"

  # Instala apenas o compiler e libgcc para o target
  make DESTDIR="$DESTDIR" install-gcc
  make DESTDIR="$DESTDIR" install-target-libgcc

  # Enxuga docs do tools (pass1)
  rm -rf "$DESTDIR$ADM_TOOLS"/{share,info,man,doc} 2>/dev/null || true

  # Garante presença de libs em lib64 se seu ambiente usa lib64 (comum em x86_64)
  # Sem isso alguns fluxos esperam /mnt/adm/tools/lib64 existir.
  mkdir -p "$DESTDIR$ADM_TOOLS/lib64"
}
