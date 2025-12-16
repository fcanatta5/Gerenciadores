#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="groff"
version="1.23.0"
release="1"

srcdir_name="groff-1.23.0"

source_urls="
https://ftp.gnu.org/gnu/groff/groff-1.23.0.tar.gz
"

depends="
core/make
core/perl
core/grep
core/sed
core/gawk
"

# makeinfo ajuda docs; se faltar, ainda dá para compilar, mas pode falhar em alguns setups.
makedepends="core/texinfo"

prepare() { :; }

build() {
  enter_srcdir_auto

  do_configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --disable-nls \
    --without-x

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() { :; }
