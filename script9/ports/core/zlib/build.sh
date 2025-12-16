#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="zlib"
version="1.3.1"
release="1"

sources="
https://zlib.net/zlib-1.3.1.tar.xz
"

depends=""
makedepends=""

prepare() { :; }

build() {
  enter_srcdir
  ./configure --prefix=/usr
  do_make
}

package() {
  enter_srcdir
  make DESTDIR="$DESTDIR" install
}
