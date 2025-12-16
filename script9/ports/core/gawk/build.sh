#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="gawk"
version="5.3.2"
release="1"

srcdir_name="gawk-5.3.2"

source_urls="
https://ftp.gnu.org/gnu/gawk/gawk-5.3.2.tar.xz
"

depends="core/make"
makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  do_configure \
    --disable-nls \
    --disable-rpath

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install

  # Alguns scripts esperam /usr/bin/awk; gawk normalmente provê também,
  # mas garantimos aqui sem risco.
  mkdir -p "$DESTDIR/usr/bin"
  [ -x "$DESTDIR/usr/bin/gawk" ] && ln -sf gawk "$DESTDIR/usr/bin/awk" || true

  ensure_destdir_nonempty
}

post_install() { :; }
