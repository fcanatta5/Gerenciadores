#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="man-pages"
version="6.16"
release="1"

srcdir_name="man-pages-6.16"

source_urls="
https://www.kernel.org/pub/linux/docs/man-pages/man-pages-6.16.tar.xz
"

depends="core/make"
makedepends=""

prepare() { :; }

build() {
  : # sem build
}

package() {
  enter_srcdir_auto

  # Instala em /usr/share/man
  make -j1 DESTDIR="$DESTDIR" install

  ensure_destdir_nonempty
}

post_install() { :; }
