#!/bin/sh
set -eu

NAME=libmnl
VERSION=1.0.5
SOURCE="https://www.netfilter.org/pub/libmnl/libmnl-${VERSION}.tar.bz2"

depends="core/make core/gcc"

build() {
  ./configure --prefix=/usr --disable-static
  make -j"${JOBS:-$(nproc)}"
}

install() {
  make DESTDIR="${PKG}" install
}
