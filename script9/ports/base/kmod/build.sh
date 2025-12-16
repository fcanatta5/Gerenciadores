#!/bin/sh
set -e
. /usr/share/adm/helpers.sh
adm_defaults

name="kmod"
version="34.2"
release="1"

srcdir_name="kmod-34.2"
source_urls="https://www.kernel.org/pub/linux/utils/kernel/kmod/kmod-34.2.tar.xz"

depends="core/make core/pkgconf core/zlib core/xz core/zstd"
makedepends=""

prepare(){ :; }

build() {
  enter_srcdir_auto

  do_configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --disable-manpages \
    --with-openssl=no \
    --with-xz \
    --with-zstd \
    --with-zlib

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install

  # kmod fornece modprobe/insmod/lsmod etc via symlinks; mantenha como upstream instala.
  ensure_destdir_nonempty
}

post_install(){ :; }
