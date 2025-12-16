#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="efibootmgr"
version="18"
release="1"

srcdir_name="efibootmgr-18"

# Observação: o tarball "efibootmgr-18.tar.gz" é a forma comum de distribuição por tag.
source_urls="
https://github.com/rhboot/efibootmgr/archive/18/efibootmgr-18.tar.gz
"

depends="
core/make
core/pkgconf
base/efivar
base/popt
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  # build simples via makefile
  do_make \
    PREFIX=/usr \
    LIBDIR=/usr/lib
}

package() {
  enter_srcdir_auto

  make -j1 DESTDIR="$DESTDIR" install \
    PREFIX=/usr \
    LIBDIR=/usr/lib

  ensure_destdir_nonempty
}

post_install() { :; }
