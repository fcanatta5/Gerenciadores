#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="tar"
version="1.35"
release="1"

srcdir_name="tar-1.35"

source_urls="
https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz
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
