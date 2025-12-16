#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="readline"
version="8.2"
release="1"

srcdir_name="readline-8.2"

source_urls="
https://ftp.gnu.org/gnu/readline/readline-8.2.tar.gz
"

depends="core/ncurses core/make"
makedepends=""

prepare() {
  :
}

build() {
  enter_srcdir_auto

  # musl-friendly: sem nls, linka com curses (ncurses)
  do_configure \
    --disable-static \
    --with-curses \
    --disable-nls

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
