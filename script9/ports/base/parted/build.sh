#!/bin/sh
set -e
. /usr/share/adm/helpers.sh
adm_defaults

name="parted"
version="3.6"
release="1"

srcdir_name="parted-3.6"
source_urls="https://ftp.gnu.org/gnu/parted/parted-3.6.tar.xz"

depends="core/make core/pkgconf core/util-linux core/ncurses core/readline"
makedepends=""

prepare(){ :; }

build() {
  enter_srcdir_auto
  do_configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --disable-nls \
    --disable-device-mapper
  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install(){ :; }
