#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="python"
version="3.12.7"
release="1"

# Tarball extrai para Python-<version>
srcdir_name="Python-3.12.7"

source_urls="
https://www.python.org/ftp/python/3.12.7/Python-3.12.7.tar.xz
"

# Dependências reais para Python funcional no desktop
depends="
core/zlib
core/xz
core/bzip2
core/openssl
core/certificates
"

makedepends=""

prepare() {
  :
}

build() {
  enter_srcdir_auto

  # Python não requer autoreconf
  # --enable-shared: necessário para extensões, embedding, ctypes
  # --with-ensurepip=install: pip funcional já na instalação
  ./configure \
    --prefix=/usr \
    --enable-shared \
    --with-ensurepip=install

  do_make
}

package() {
  enter_srcdir_auto

  # install sequencial é mais robusto
  make -j1 DESTDIR="$DESTDIR" install

  # Política comum: python -> python3
  mkdir -p "$DESTDIR/usr/bin"
  if [ -x "$DESTDIR/usr/bin/python3" ] && [ ! -e "$DESTDIR/usr/bin/python" ]; then
    ln -sf python3 "$DESTDIR/usr/bin/python"
  fi

  ensure_destdir_nonempty
}

post_install() {
  :
}
