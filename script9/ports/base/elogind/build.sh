#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="elogind"
version="255.17"
release="1"

srcdir_name="elogind-255.17"
source_urls="
https://github.com/elogind/elogind/archive/refs/tags/v255.17.tar.gz
"

depends="
core/pkgconf
core/meson
core/ninja
base/dbus
base/pam
base/libcap
"

makedepends=""

prepare(){ :; }

build() {
  enter_srcdir_auto

  rm -rf build
  meson setup build \
    --prefix=/usr \
    --buildtype=release \
    -Dman=false \
    -Dtests=false \
    -Ddoc=false \
    -Ddefault-hierarchy=unified \
    -Dsmack=false \
    -Dselinux=false

  ninja -C build
}

package() {
  enter_srcdir_auto
  DESTDIR="$DESTDIR" ninja -C build install

  # layout usado por logind compat
  mkdir -p "$DESTDIR/run/systemd"
  ensure_destdir_nonempty
}

post_install(){ :; }
