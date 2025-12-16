#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="wl-clipboard-x11-bridge"
version="1.0"
release="1"

srcdir_name=""
source_urls=""

depends="
base/wl-clipboard
wayland/xclip
"

makedepends=""

prepare() { :; }
build() { :; }

package() {
  install -Dm755 "$FILESDIR/wl-x11-clipboard-bridge" \
    "$DESTDIR/usr/bin/wl-x11-clipboard-bridge"

  # Serviço opcional (para iniciar no login via supervisão do seu choice)
  install -Dm644 "$FILESDIR/wl-x11-clipboard-bridge.service" \
    "$DESTDIR/usr/lib/services/wl-x11-clipboard-bridge.service"

  ensure_destdir_nonempty
}

post_install() { :; }
