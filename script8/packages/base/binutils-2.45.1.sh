#!/usr/bin/env bash
# Binutils 2.45.1 (base system)
# Instala em /usr (via DESTDIR do adm)
#
# Referência de flags: LFS/Multilib chapter 8 (binutils) 1

set -Eeuo pipefail
shopt -s nullglob

PKG_NAME="binutils"
PKG_VERSION="2.45.1"
PKG_CATEGORY="base"

# Sysroot opcional (use /mnt/adm enquanto estiver construindo o sistema lá)
: "${ADM_MNT:=/mnt/adm}"

PKG_DEPENDS=(
  # zlib é recomendado por --with-system-zlib.
  # Se você ainda não empacotou zlib no adm, remova esta dep e remova --with-system-zlib abaixo.
  "zlib@1.3.1"
)

# LFS fornece MD5 para binutils-2.45.1.tar.xz 2
PKG_SOURCES=(
  "https://sourceware.org/pub/binutils/releases/binutils-2.45.1.tar.xz|md5|ff59f8dc1431edfa54a257851bea74e7"
)

PKG_PATCHES=(
  # nenhum
)

build() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"

  cd "$ADM_WORKDIR"

  local tarball="$ADM_WORKDIR/sources/binutils-2.45.1.tar.xz"
  [[ -f "$tarball" ]] || tarball="$(ls -1 "$ADM_WORKDIR/sources"/binutils-2.45.1.tar.* 2>/dev/null | head -n1 || true)"
  [[ -f "$tarball" ]] || { echo "ERRO: tarball do binutils não encontrado em $ADM_WORKDIR/sources"; return 1; }

  rm -rf binutils-2.45.1 build-binutils
  tar -xf "$tarball"

  mkdir -p build-binutils
  cd build-binutils

  ../binutils-2.45.1/configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --enable-ld=default \
    --enable-plugins \
    --enable-shared \
    --disable-werror \
    --enable-64-bit-bfd \
    --enable-new-dtags \
    --with-system-zlib \
    --enable-default-hash-style=gnu

  make -j"$(nproc)" tooldir=/usr
}

install() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"
  : "${ADM_MNT:=/mnt/adm}"

  cd "$ADM_WORKDIR/build-binutils"

  # Instala no sysroot (/mnt/adm) via staging do adm
  make DESTDIR="$DESTDIR$ADM_MNT" tooldir=/usr install

  # Limpeza recomendada no LFS (remove libs estáticas e docs do gprofng) 3
  rm -rfv \
    "$DESTDIR$ADM_MNT/usr/lib/libbfd.a" \
    "$DESTDIR$ADM_MNT/usr/lib/libctf.a" \
    "$DESTDIR$ADM_MNT/usr/lib/libctf-nobfd.a" \
    "$DESTDIR$ADM_MNT/usr/lib/libgprofng.a" \
    "$DESTDIR$ADM_MNT/usr/lib/libopcodes.a" \
    "$DESTDIR$ADM_MNT/usr/lib/libsframe.a" \
    "$DESTDIR$ADM_MNT/usr/share/doc/gprofng" 2>/dev/null || true
}
