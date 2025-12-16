#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="gdbm"
version="1.26"
release="1"

srcdir_name="gdbm-1.26"

source_urls="
https://ftp.gnu.org/gnu/gdbm/gdbm-1.26.tar.gz
"

depends="core/make"
makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  do_configure \
    --prefix=/usr \
    --disable-nls \
    --disable-static \
    --enable-libgdbm-compat

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
