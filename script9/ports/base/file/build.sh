#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="file"
version="5.46"
release="1"

srcdir_name="file-5.46"

source_urls="
https://astron.com/pub/file/file-5.46.tar.gz
"

depends="
core/make
core/zlib
"

makedepends="core/pkgconf"

prepare() { :; }

build() {
  enter_srcdir_auto

  # musl-friendly: sem gettext/NLS
  do_configure \
    --prefix=/usr \
    --disable-nls \
    --disable-static \
    --enable-shared

  do_make
}

package() {
  enter_srcdir_auto

  # install serial é mais robusto
  make -j1 DESTDIR="$DESTDIR" install

  ensure_destdir_nonempty
}

post_install() { :; }
