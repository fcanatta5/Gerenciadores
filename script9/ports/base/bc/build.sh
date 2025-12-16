#!/bin/sh
set -e
. /usr/share/adm/helpers.sh
adm_defaults

name="bc"
version="1.07.1"
release="1"

srcdir_name="bc-1.07.1"
source_urls="https://ftp.gnu.org/gnu/bc/bc-1.07.1.tar.gz"

depends="core/make"
makedepends=""

prepare(){ :; }

build() {
  enter_srcdir_auto
  do_configure --prefix=/usr --disable-nls
  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install(){ :; }
