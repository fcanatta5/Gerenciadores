#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="dhcpcd"
version="10.2.4"
release="1"

srcdir_name="dhcpcd-10.2.4"
source_urls="
https://github.com/NetworkConfiguration/dhcpcd/releases/download/v10.2.4/dhcpcd-10.2.4.tar.xz
"

depends="core/make core/gcc core/pkgconf"
makedepends=""

prepare(){ :; }

build() {
  enter_srcdir_auto

  # dhcpcd usa ./configure próprio
  ./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --dbdir=/var/lib/dhcpcd \
    --libexecdir=/usr/lib/dhcpcd

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install

  mkdir -p "$DESTDIR/var/lib/dhcpcd"
  ensure_destdir_nonempty
}

post_install(){ :; }
