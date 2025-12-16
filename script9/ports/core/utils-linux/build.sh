#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="util-linux"
version="2.40.4"
release="1"

srcdir_name="util-linux-2.40.4"

source_urls="
https://www.kernel.org/pub/linux/utils/util-linux/v2.40/util-linux-2.40.4.tar.xz
"

depends="
core/make
core/ncurses
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  # musl-friendly e evita conflitos com shadow (su/login):
  do_configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --disable-nls \
    --disable-static \
    --without-python \
    --without-systemd \
    --disable-su \
    --disable-login

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
