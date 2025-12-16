#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="efivar"
version="39"
release="1"

srcdir_name="efivar-39"

# Tarball oficial do release (padrão usado também em spec)
source_urls="
https://github.com/rhboot/efivar/releases/download/39/efivar-39.tar.bz2
"

depends="
core/make
core/pkgconf
core/util-linux
base/popt
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  # build baseado em Makefile
  # (mantemos LIBDIR=/usr/lib para x86_64 musl padrão do seu sistema)
  do_make \
    PREFIX=/usr \
    LIBDIR=/usr/lib \
    MANDIR=/usr/share/man
}

package() {
  enter_srcdir_auto

  make -j1 DESTDIR="$DESTDIR" install \
    PREFIX=/usr \
    LIBDIR=/usr/lib \
    MANDIR=/usr/share/man

  ensure_destdir_nonempty
}

post_install() { :; }
