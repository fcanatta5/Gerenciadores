#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="less"
version="685"
release="1"

srcdir_name="less-685"

source_urls="
https://www.greenwoodsoftware.com/less/less-685.tar.gz
"

depends="
core/make
core/ncurses
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  # less usa termcap/curses; em musl é tranquilo com ncurses
  do_configure \
    --prefix=/usr \
    --sysconfdir=/etc

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() {
  # /etc/lesskey (opcional) pode ser criado depois pelo usuário
  :
}
