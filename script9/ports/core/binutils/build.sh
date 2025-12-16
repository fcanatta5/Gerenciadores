#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="binutils"
version="2.45.1"
release="1"

srcdir_name="binutils-2.45.1"

source_urls="
https://sourceware.org/pub/binutils/releases/binutils-2.45.1.tar.xz
"

depends="core/zlib core/make"
makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  rm -rf build
  mkdir -p build
  cd build

  ../configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --disable-nls \
    --disable-werror \
    --disable-static \
    --enable-shared \
    --enable-plugins \
    --with-system-zlib

  do_make
}

package() {
  enter_srcdir_auto
  cd build
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
