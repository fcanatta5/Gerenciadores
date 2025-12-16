#!/bin/sh
set -e
. /usr/share/adm/helpers.sh
adm_defaults

name="dosfstools"
version="4.2"
release="1"

srcdir_name="dosfstools-4.2"
source_urls="https://github.com/dosfstools/dosfstools/releases/download/v4.2/dosfstools-4.2.tar.gz"

depends="core/make"
makedepends=""

prepare(){ :; }

build() {
  enter_srcdir_auto
  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" PREFIX=/usr install
  ensure_destdir_nonempty
}

post_install(){ :; }
