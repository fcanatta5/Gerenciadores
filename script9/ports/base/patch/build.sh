#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="patch"
version="2.8"
release="1"

srcdir_name="patch-2.8"

source_urls="
https://ftp.gnu.org/gnu/patch/patch-2.8.tar.xz
"

depends="core/make"
makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  do_configure \
    --prefix=/usr \
    --disable-nls

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
