#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="python"
version="3.12.7"
release="1"

srcdir_name="Python-3.12.7"

source_urls="
https://www.python.org/ftp/python/3.12.7/Python-3.12.7.tar.xz
"

# Dependências mínimas típicas para um Python útil:
# - zlib: compressão
# - xz/bzip2: tarballs e módulos
# (openssl não é estritamente obrigatório para compilar o interpretador,
#  mas é essencial para TLS, pip, etc. então é melhor declarar.)
depends="core/zlib core/xz core/bzip2"
makedepends=""

prepare() {
  :
}

build() {
  enter_srcdir_auto

  # Python é autotools-like (configure + make), mas não requer autoreconf.
  # --enable-shared é importante para muitos usos (extensões, embedding).
  # --with-ensurepip=install tenta instalar pip/setuptools via ensurepip.
  ./configure \
    --prefix=/usr \
    --enable-shared \
    --with-ensurepip=install

  do_make
}

package() {
  enter_srcdir_auto

  make DESTDIR="$DESTDIR" install

  # Alguns sistemas querem garantir o symlink "python" -> "python3"
  # (opcional; você decide política)
  mkdir -p "$DESTDIR/usr/bin"
  if [ -x "$DESTDIR/usr/bin/python3" ] && [ ! -e "$DESTDIR/usr/bin/python" ]; then
    ln -sf python3 "$DESTDIR/usr/bin/python"
  fi

  ensure_destdir_nonempty
}

post_install() {
  :
}
