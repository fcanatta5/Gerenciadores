#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="zlib"
version="1.3.1"
release="1"

# O tarball do zlib extrai para zlib-<version>
srcdir_name="zlib-1.3.1"

source_urls="
https://zlib.net/zlib-1.3.1.tar.xz
"

depends=""
makedepends=""

prepare() {
  # zlib não usa autotools
  :
}

build() {
  enter_srcdir_auto

  # zlib usa configure próprio
  CHOST="$(gcc -dumpmachine 2>/dev/null || echo x86_64-linux-gnu)"

  ./configure \
    --prefix=/usr

  do_make
}

package() {
  enter_srcdir_auto

  make DESTDIR="$DESTDIR" install

  # zlib instala libz.so corretamente em /usr/lib
  ensure_destdir_nonempty
}

post_install() {
  : # nenhuma ação necessária
}
