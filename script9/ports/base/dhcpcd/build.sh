#!/bin/sh
set -eu

NAME=dhcpcd
VERSION=10.2.4
SOURCE="https://github.com/NetworkConfiguration/dhcpcd/releases/download/v${VERSION}/dhcpcd-${VERSION}.tar.xz"

depends="core/make core/gcc core/pkgconf"

build() {
  # layout padrão e previsível
  ./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --dbdir=/var/lib/dhcpcd \
    --libexecdir=/usr/lib/dhcpcd
  make -j"${JOBS:-$(nproc)}"
}

install() {
  make DESTDIR="${PKG}" install
  install -d "${PKG}/var/lib/dhcpcd"
}
