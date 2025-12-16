#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="os-prober"
version="1.83"
release="1"

srcdir_name="os-prober-1.83"

# Tarball oficial do source package Debian
source_urls="
https://deb.debian.org/debian/pool/main/o/os-prober/os-prober_1.83.tar.xz
"

depends="
core/make
core/coreutils
core/util-linux
core/grep
core/sed
core/gawk
core/findutils
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto
  # Não há build “compilado”; são scripts.
  :
}

package() {
  enter_srcdir_auto

  # O upstream/Debian fornece Makefile com install
  make -j1 DESTDIR="$DESTDIR" install

  ensure_destdir_nonempty
}

post_install() { :; }
