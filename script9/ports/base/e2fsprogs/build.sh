#!/bin/sh
set -e
. /usr/share/adm/helpers.sh
adm_defaults

name="e2fsprogs"
version="1.47.2"
release="1"

srcdir_name="e2fsprogs-1.47.2"
source_urls="https://www.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v1.47.2/e2fsprogs-1.47.2.tar.xz"

depends="core/make core/pkgconf core/util-linux"
makedepends=""

prepare(){ :; }

build() {
  enter_srcdir_auto
  rm -rf build
  mkdir -p build
  cd build

  ../configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --disable-nls \
    --enable-elf-shlibs

  do_make
}

package() {
  enter_srcdir_auto
  cd build
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install(){ :; }
