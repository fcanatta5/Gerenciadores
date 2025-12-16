#!/bin/sh
set -eu

NAME=libnl
VERSION=3.11.0
SOURCE="https://github.com/thom311/libnl/releases/download/libnl3_11_0/libnl-${VERSION}.tar.gz"

depends="core/pkgconf core/make"

build() {
  ./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --disable-static
  make -j"${JOBS:-$(nproc)}"
}

install() {
  make DESTDIR="${PKG}" install
}
