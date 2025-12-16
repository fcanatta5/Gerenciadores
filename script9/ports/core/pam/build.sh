#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="pam"
version="1.7.1"
release="1"

srcdir_name="Linux-PAM-1.7.1"

source_urls="
https://github.com/linux-pam/linux-pam/releases/download/v1.7.1/Linux-PAM-1.7.1.tar.xz
"

depends="
core/make
core/pkgconf
core/ninja
core/meson
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  rm -rf build
  mkdir -p build
  cd build

  # musl-friendly: sem systemd; usa meson/ninja
  meson setup .. \
    --prefix=/usr \
    --libdir=lib \
    -Ddefault_library=shared \
    -Db_pie=true \
    -Dselinux=disabled \
    -Dsystemd=disabled

  ninja
}

package() {
  enter_srcdir_auto
  cd build

  DESTDIR="$DESTDIR" ninja install
  ensure_destdir_nonempty
}

post_install() { :; }
