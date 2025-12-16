#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="iproute2"
version="6.18.0"
release="1"

srcdir_name="iproute2-6.18.0"
source_urls="
https://www.kernel.org/pub/linux/utils/net/iproute2/iproute2-6.18.0.tar.xz
"

depends="core/make core/gcc core/pkgconf base/iptables base/libcap"
makedepends=""

prepare(){ :; }

build() {
  enter_srcdir_auto

  # build simples (iproute2 é make-based)
  do_make
}

package() {
  enter_srcdir_auto

  make -j1 DESTDIR="$DESTDIR" PREFIX=/usr install

  ensure_destdir_nonempty
}

post_install(){ :; }
