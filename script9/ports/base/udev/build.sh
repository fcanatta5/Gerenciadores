#!/bin/sh
set -e
. /usr/share/adm/helpers.sh
adm_defaults

name="udev"
version="1.0"
release="1"

srcdir_name=""
source_urls=""

depends="base/eudev"
makedepends=""

prepare(){ :; }
build(){ :; }

package() {
  mkdir -p "$DESTDIR/usr/share/adm"
  printf '%s\n' "provider=eudev" > "$DESTDIR/usr/share/adm/udev.provider"
  ensure_destdir_nonempty
}

post_install(){ :; }
