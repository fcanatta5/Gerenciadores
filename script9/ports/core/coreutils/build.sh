#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="coreutils"
version="9.7"
release="1"

srcdir_name="coreutils-9.7"

source_urls="
https://ftp.gnu.org/gnu/coreutils/coreutils-9.7.tar.xz
"

depends="core/make"
makedepends=""

prepare() {
  :
}

build() {
  enter_srcdir_auto

  # musl-friendly: desliga NLS
  # evita colisões futuras com util-linux (kill/uptime)
  do_configure \
    --disable-nls \
    --enable-no-install-program=kill,uptime

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
