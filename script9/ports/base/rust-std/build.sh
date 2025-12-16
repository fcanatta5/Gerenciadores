#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="rust-std"
version="1.92.0"
release="1"

# Diretório do tarball padrão (musl host)
srcdir_name="rust-std-1.92.0-x86_64-unknown-linux-musl"

source_urls="
https://static.rust-lang.org/dist/rust-std-1.92.0-x86_64-unknown-linux-musl.tar.xz
"

# Instalação offline do componente (não compila)
depends="
base/rust
core/bash
core/tar
core/xz
"

makedepends=""

prepare() { :; }
build() { :; }

package() {
  enter_srcdir_auto

  # O standalone component installer suporta:
  #   ./install.sh --prefix=/usr --destdir=$DESTDIR
  # (fluxo oficial de instalação offline)
  ./install.sh \
    --prefix=/usr \
    --destdir="$DESTDIR" \
    --disable-ldconfig

  ensure_destdir_nonempty
}

post_install() { :; }
