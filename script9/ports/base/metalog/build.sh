#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="metalog"
version="3"
release="1"

srcdir_name="metalog-3"
source_urls="
https://downloads.sourceforge.net/project/metalog/metalog-3.tar.xz
"

depends="core/make core/gcc"
makedepends=""

prepare(){ :; }

build() {
  enter_srcdir_auto
  do_make
}

package() {
  enter_srcdir_auto

  # upstream geralmente instala em /usr/local; forçamos /usr
  make -j1 DESTDIR="$DESTDIR" PREFIX=/usr install || {
    # fallback manual
    install -Dm755 metalog "$DESTDIR/usr/sbin/metalog"
    install -Dm644 metalog.conf "$DESTDIR/etc/metalog.conf"
  }

  # config mínima se não veio
  if [ ! -f "$DESTDIR/etc/metalog.conf" ]; then
    install -Dm644 "$FILESDIR/metalog.conf" "$DESTDIR/etc/metalog.conf"
  fi

  ensure_destdir_nonempty
}

post_install(){ :; }
