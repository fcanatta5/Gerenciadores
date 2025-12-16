#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="m4"
version="1.4.20"
release="1"

sources="
https://ftp.gnu.org/gnu/m4/m4-1.4.20.tar.xz
"

depends=""
makedepends=""

prepare() { :; }

build() {
  enter_srcdir
  do_configure
  do_make
}

package() {
  enter_srcdir
  do_make_install
}
