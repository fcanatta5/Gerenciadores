#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="libxcrypt"
version="4.5.2"
release="1"

srcdir_name="libxcrypt-4.5.2"

source_urls="
https://github.com/besser82/libxcrypt/releases/download/v4.5.2/libxcrypt-4.5.2.tar.xz
"

depends="core/make core/pkgconf"
makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  do_configure \
    --prefix=/usr \
    --disable-static \
    --enable-shared

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
