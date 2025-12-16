#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="xclip"
version="0.13"
release="1"

srcdir_name="xclip-0.13"

source_urls="
https://github.com/astrand/xclip/archive/refs/tags/0.13.tar.gz
"

depends="
core/make
core/pkgconf
x11/libX11
x11/libXmu
x11/libXt
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  # GitHub tarball geralmente precisa gerar configure
  # xclip usa autotools em vários setups
  if [ -x ./autogen.sh ]; then
    ./autogen.sh
  elif command -v autoreconf >/dev/null 2>&1; then
    autoreconf -fi
  fi

  do_configure --prefix=/usr
  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
