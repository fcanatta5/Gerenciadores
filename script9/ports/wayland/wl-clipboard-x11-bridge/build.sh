#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="wl-clipboard-x11-bridge"
version="1.1"
release="2"

srcdir_name=""
source_urls=""

depends="
base/wl-clipboard
wayland/wl-clip-persist
wayland/xclip
"

makedepends=""

prepare() { :; }
build() { :; }

package() {
  install -Dm755 "$FILESDIR/wl-x11-clipboard-bridge" \
    "$DESTDIR/usr/bin/wl-x11-clipboard-bridge"

  install -Dm755 "$FILESDIR/wl-clipboard-session" \
    "$DESTDIR/usr/bin/wl-clipboard-session"

  install -Dm644 "$FILESDIR/wl-clipboard-session.service" \
    "$DESTDIR/usr/lib/services/wl-clipboard-session.service"

  ensure_destdir_nonempty
}

post_install() { :; }
