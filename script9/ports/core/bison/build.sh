#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="bison"
version="3.8.2"
release="1"

srcdir_name="bison-3.8.2"

source_urls="
https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz
"

depends="
core/m4
core/make
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  do_configure \
    --disable-static \
    --disable-werror

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
