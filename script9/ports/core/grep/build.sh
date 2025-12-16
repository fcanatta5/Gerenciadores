#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="grep"
version="3.12"
release="1"

srcdir_name="grep-3.12"

source_urls="
https://ftp.gnu.org/gnu/grep/grep-3.12.tar.xz
"

depends="core/make"
makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  # musl-friendly: sem NLS; evita puxar PCRE2 (per-regexp)
  do_configure \
    --disable-nls \
    --disable-perl-regexp \
    --disable-rpath

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
