#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="flex"
version="2.6.4"
release="1"

srcdir_name="flex-2.6.4"

# Tarball oficial do release no GitHub
source_urls="
https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz
"

depends="core/m4 core/make"
makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  do_configure \
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
