#!/bin/sh
set -e
. /usr/share/adm/helpers.sh
adm_defaults

name="runit-boot"
version="1.0"
release="1"

srcdir_name=""
source_urls=""

depends="
core/runit
base/udev
base/kmod
core/util-linux
core/coreutils
core/bash
"

makedepends=""

prepare(){ :; }
build(){ :; }

package() {
  # instala /etc/runit/* e serviços iniciais
  cp -a "$FILESDIR/etc/." "$DESTDIR/etc/"

  # garante permissões executáveis
  chmod 0755 \
    "$DESTDIR/etc/runit/1" \
    "$DESTDIR/etc/runit/2" \
    "$DESTDIR/etc/runit/3" \
    "$DESTDIR/etc/runit/runsvdir/default/"*/run 2>/dev/null || true

  ensure_destdir_nonempty
}

post_install(){ :; }
