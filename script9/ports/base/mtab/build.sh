#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="mtab"
version="1.0"
release="1"

srcdir_name=""
source_urls=""

depends=""
makedepends=""

prepare(){ :; }
build(){ :; }

package() {
  mkdir -p "$DESTDIR/etc"
  ln -snf /proc/self/mounts "$DESTDIR/etc/mtab"
  ensure_destdir_nonempty
}

post_install(){ :; }
