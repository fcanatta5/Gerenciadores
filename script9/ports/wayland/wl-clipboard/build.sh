#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="wl-clipboard"
version="2.2.1"
release="1"

srcdir_name="wl-clipboard-2.2.1"

source_urls="
https://github.com/bugaevc/wl-clipboard/releases/download/v2.2.1/wl-clipboard-2.2.1.tar.gz
"

depends="
core/pkgconf
core/meson
core/ninja
core/wayland
core/wayland-protocols
core/wayland-scanner
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  rm -rf build
  meson setup build \
    --prefix=/usr \
    --buildtype=release

  ninja -C build
}

package() {
  enter_srcdir_auto

  DESTDIR="$DESTDIR" ninja -C build install

  # Wrapper para vim no terminal (Wayland)
  install -Dm755 "$FILESDIR/vim-wl" "$DESTDIR/usr/bin/vim-wl"

  # Snippet de vimrc (carregado automaticamente pelo wrapper)
  install -Dm644 "$FILESDIR/vim-wl-clipboard.vim" \
    "$DESTDIR/usr/share/vim/vimrc.d/90-wayland-clipboard.vim"

  ensure_destdir_nonempty
}

post_install() { :; }
