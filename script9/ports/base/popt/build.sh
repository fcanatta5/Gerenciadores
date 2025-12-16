#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="popt"
version="1.19"
release="1"

srcdir_name="popt-1.19"

source_urls="
https://ftp.rpm.org/popt/releases/popt-1.x/popt-1.19.tar.gz
"

depends="core/make"
makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  # popt é autotools clássico; em musl mantenha simples
  do_configure \
    --prefix=/usr \
    --disable-static \
    --disable-nls

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
