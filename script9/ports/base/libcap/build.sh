#!/bin/sh
set -eu

NAME=libcap
VERSION=2.77
SOURCE="https://www.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-${VERSION}.tar.xz"

# runtime: libcap.so, capsh etc
depends=""

build() {
  # libcap usa Makefile próprio (não autotools)
  # Recomendado instalar em /usr e libdir "lib" (x86_64)
  make -j"${JOBS:-$(nproc)}"
}

install() {
  make DESTDIR="${PKG}" prefix=/usr lib=lib install
}
