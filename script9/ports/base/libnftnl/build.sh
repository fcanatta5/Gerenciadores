#!/bin/sh
set -eu

NAME=libnftnl
VERSION=1.3.1
SOURCE="https://www.netfilter.org/projects/libnftnl/files/libnftnl-${VERSION}.tar.xz"

depends="core/make core/gcc core/pkgconf base/libmnl"

build() {
  ./configure --prefix=/usr --disable-static
  make -j"${JOBS:-$(nproc)}"
}

install() {
  make DESTDIR="${PKG}" install
}
