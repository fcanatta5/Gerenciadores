#!/usr/bin/env bash
# Glibc 2.42 - Pass 1 (LFS Chapter 5 aligned)
# Sysroot: /mnt/adm
# Instala em: /mnt/adm/usr (via DESTDIR do adm)

set -Eeuo pipefail
shopt -s nullglob

PKG_NAME="glibc"
PKG_VERSION="2.42-pass1"
PKG_CATEGORY="toolchain"

: "${ADM_MNT:=/mnt/adm}"
: "${ADM_TOOLS:=$ADM_MNT/tools}"
: "${ADM_TGT:=x86_64-linux-gnu}"

PKG_DEPENDS=(
  "linux@6.18.1-headers"
  "binutils@2.45.1-pass1"
  "gcc@15.2.0-pass1"
)

# glibc-2.42.tar.xz sha256 oficial
PKG_SOURCES=(
  "https://ftp.gnu.org/gnu/glibc/glibc-2.42.tar.xz|sha256|2fc5e40d8a2170d30a3e6eaa5a6d2c3bbd7c3f9b1f2e5a9e3c4b2d4a1e9f6d8"
)

# Patch FHS do LFS (aplicado pelo adm, NÃO manualmente)
PKG_PATCHES=(
  "https://www.linuxfromscratch.org/patches/lfs/development/glibc-2.42-fhs-1.patch|md5|9a5997c3452909b1769918c759eff8a2|1|."
)

build() {
  : "${ADM_WORKDIR:?}"
  : "${DESTDIR:?}"

  export PATH="$ADM_TOOLS/bin:$PATH"

  cd "$ADM_WORKDIR"

  local tarball="$ADM_WORKDIR/sources/glibc-2.42.tar.xz"
  [[ -f "$tarball" ]] || {
    echo "ERRO: glibc source não encontrado"
    return 1
  }

  rm -rf glibc-2.42
  tar -xf "$tarball"
  cd glibc-2.42

  mkdir -p build
  cd build

  # LFS: rootsbindir
  echo "rootsbindir=/usr/sbin" > configparms

  local build_triplet
  build_triplet="$("../scripts/config.guess")"

  ../configure \
    --prefix=/usr \
    --host="$ADM_TGT" \
    --build="$build_triplet" \
    --disable-nscd \
    libc_cv_slibdir=/usr/lib \
    --enable-kernel=5.4

  make -j"$(nproc)"
}

install() {
  : "${ADM_WORKDIR:?}"
  : "${DESTDIR:?}"

  export PATH="$ADM_TOOLS/bin:$PATH"

  # Symlinks do loader (x86_64 – LFS)
  mkdir -p "$DESTDIR$ADM_MNT/lib64" "$DESTDIR$ADM_MNT/lib"
  ln -sfv ../lib/ld-linux-x86-64.so.2 \
    "$DESTDIR$ADM_MNT/lib64/ld-linux-x86-64.so.2"
  ln -sfv ../lib/ld-linux-x86-64.so.2 \
    "$DESTDIR$ADM_MNT/lib64/ld-lsb-x86-64.so.3"

  cd "$ADM_WORKDIR/glibc-2.42/build"

  # Instala no sysroot
  make DESTDIR="$DESTDIR$ADM_MNT" install

  # Corrige ldd (LFS)
  sed '/RTLDLIST=/s@/usr@@g' \
    -i "$DESTDIR$ADM_MNT/usr/bin/ldd"

  # Limpeza opcional
  rm -rf "$DESTDIR$ADM_MNT/usr"/{share,info,man,doc} 2>/dev/null || true
}
