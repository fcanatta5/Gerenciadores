#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="libpipeline"
version="1.5.8"
release="1"

srcdir_name="libpipeline-1.5.8"

source_urls="
https://download-mirror.savannah.gnu.org/releases/libpipeline/libpipeline-1.5.8.tar.gz
"

depends="core/make"
makedepends="core/pkgconf"

prepare() { :; }

build() {
  enter_srcdir_auto
  do_configure \
    --prefix=/usr \
    --disable-nls \
    --disable-static
  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
