#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="wl-clip-persist"
version="0.5.0"
release="1"

srcdir_name="wl-clip-persist-0.5.0"

source_urls="
https://github.com/Linus789/wl-clip-persist/archive/refs/tags/v0.5.0.tar.gz
"

# Upstream é Rust/cargo. Você precisa ter um port de Rust toolchain:
# - rustc + cargo (>= 1.85.0 recomendado pelo upstream)
# E também wayland headers/libs.
depends="
base/rust
core/pkgconf
core/wayland
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  ensure_cmd cargo
  ensure_cmd rustc

  # build release
  cargo build --release
}

package() {
  enter_srcdir_auto

  install -Dm755 target/release/wl-clip-persist \
    "$DESTDIR/usr/bin/wl-clip-persist"

  # (opcional) licença
  if [ -f LICENSE ]; then
    install -Dm644 LICENSE "$DESTDIR/usr/share/licenses/wl-clip-persist/LICENSE"
  fi

  ensure_destdir_nonempty
}

post_install() { :; }
