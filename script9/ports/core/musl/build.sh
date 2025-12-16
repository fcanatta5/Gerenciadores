#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="musl"
version="1.2.5"
release="1"

srcdir_name="musl-1.2.5"

source_urls="
https://musl.libc.org/releases/musl-1.2.5.tar.gz
"

depends="core/make"
makedepends=""

prepare() {
  enter_srcdir_auto
  # Patches em patches/*.patch serão aplicados automaticamente pelo adm (seu fluxo).
  :
}

build() {
  enter_srcdir_auto

  # syslibdir=/lib para posicionar o loader corretamente (ld-musl-x86_64.so.1)
  # prefix=/usr para headers e libs em /usr
  ./configure \
    --prefix=/usr \
    --syslibdir=/lib

  do_make
}

package() {
  enter_srcdir_auto

  make -j1 DESTDIR="$DESTDIR" install

  ensure_destdir_nonempty
}

post_install() {
  :
}
