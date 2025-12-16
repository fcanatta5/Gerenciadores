#!/bin/sh
set -eu

NAME=iptables
VERSION=1.8.11
SOURCE="https://www.netfilter.org/projects/iptables/files/iptables-${VERSION}.tar.xz"

# Ajuste conforme seus ports reais:
depends="core/pkgconf base/libnl base/libcap base/libmnl base/libnftnl"

build() {
  # Para desktop: manter compat (iptables-legacy/nft) é útil
  ./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --enable-shared \
    --disable-static
  make -j"${JOBS:-$(nproc)}"
}

install() {
  make DESTDIR="${PKG}" install
}
