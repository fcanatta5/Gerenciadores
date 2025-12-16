#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="findutils"
version="4.10.0"
release="1"

srcdir_name="findutils-4.10.0"

source_urls="
https://ftp.gnu.org/gnu/findutils/findutils-4.10.0.tar.xz
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
