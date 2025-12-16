#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="rust"
version="1.92.0"
release="1"

# O standalone installer vem com diretório "rust-<ver>-<triple>"
srcdir_name="rust-1.92.0-x86_64-unknown-linux-musl"

source_urls="
https://static.rust-lang.org/dist/rust-1.92.0-x86_64-unknown-linux-musl.tar.xz
"

# Só instala (não compila). Precisa de tar/xz e uma shell funcional.
depends="
core/bash
core/tar
core/xz
"

makedepends=""

prepare() { :; }

build() { :; }

package() {
  enter_srcdir_auto

  # O standalone installer suporta instalação offline via install.sh.
  # --destdir instala dentro do pacote (DESTDIR) sem tocar no sistema.
  # --prefix define /usr dentro do sysroot.
  # --disable-ldconfig evita tentar mexer em cache de libs no build.
  ./install.sh \
    --prefix=/usr \
    --destdir="$DESTDIR" \
    --disable-ldconfig

  # Garantes úteis: cargo/rustc ficam em /usr/bin
  ensure_destdir_nonempty
}

post_install() { :; }
