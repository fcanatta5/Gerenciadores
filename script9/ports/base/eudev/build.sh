#!/bin/sh
set -e
. /usr/share/adm/helpers.sh
adm_defaults

name="eudev"
version="3.2.14"
release="1"

srcdir_name="eudev-3.2.14"
source_urls="https://edf.amd.com/sswreleases/rel-v2024.2/downloads/eudev-3.2.14.tar.gz"

depends="core/make core/pkgconf core/gperf core/util-linux base/kmod"
makedepends=""

prepare(){ :; }

build() {
  enter_srcdir_auto

  # autotools clássico
  do_configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --sbindir=/usr/sbin \
    --bindir=/usr/bin \
    --libdir=/usr/lib \
    --disable-static \
    --disable-selinux \
    --disable-manpages

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install

  # diretórios padrão (rules/hwdb)
  mkdir -p "$DESTDIR/etc/udev/rules.d" "$DESTDIR/usr/lib/udev/rules.d" "$DESTDIR/usr/lib/udev/hwdb.d"

  ensure_destdir_nonempty
}

post_install(){ :; }
