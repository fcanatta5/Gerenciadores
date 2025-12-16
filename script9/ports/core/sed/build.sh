#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="sed"
version="4.9"
release="1"

srcdir_name="sed-4.9"

source_urls="
https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz
"

depends="core/make"
makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  do_configure \
    --disable-nls \
    --disable-rpath

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
