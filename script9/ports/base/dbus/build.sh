#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="dbus"
version="1.16.2"
release="1"

srcdir_name="dbus-1.16.2"
source_urls="
https://dbus.freedesktop.org/releases/dbus/dbus-1.16.2.tar.xz
"

depends="
core/pkgconf
core/meson
core/ninja
base/expat
"

makedepends=""

prepare(){ :; }

build() {
  enter_srcdir_auto

  rm -rf build
  meson setup build \
    --prefix=/usr \
    --buildtype=release \
    -Dsystemd=disabled \
    -Dselinux=disabled \
    -Dxml_docs=disabled \
    -Ddoxygen_docs=disabled \
    -Dtests=disabled \
    -Ddbus-launch=disabled

  ninja -C build
}

package() {
  enter_srcdir_auto
  DESTDIR="$DESTDIR" ninja -C build install

  # diretórios runtime
  mkdir -p "$DESTDIR/etc/dbus-1" "$DESTDIR/var/lib/dbus" "$DESTDIR/run"
  ensure_destdir_nonempty
}

post_install(){ :; }
