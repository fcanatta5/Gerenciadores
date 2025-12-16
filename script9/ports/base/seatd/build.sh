#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="seatd"
version="0.9.1"
release="1"

srcdir_name="seatd-0.9.1"
source_urls="
https://git.sr.ht/~kennylevinsen/seatd/archive/0.9.1.tar.gz
"

depends="
core/pkgconf
core/meson
core/ninja
base/elogind
"

makedepends=""

prepare(){ :; }

build() {
  enter_srcdir_auto

  rm -rf build
  meson setup build \
    --prefix=/usr \
    --buildtype=release \
    -Dserver=enabled

  ninja -C build
}

package() {
  enter_srcdir_auto
  DESTDIR="$DESTDIR" ninja -C build install

  # runtime dir padrão
  mkdir -p "$DESTDIR/run/seatd"
  ensure_destdir_nonempty
}

post_install(){ :; }
