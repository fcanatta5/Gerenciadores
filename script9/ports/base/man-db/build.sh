#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="man-db"
version="2.13.1"
release="1"

srcdir_name="man-db-2.13.1"

source_urls="
https://download-mirror.savannah.gnu.org/releases/man-db/man-db-2.13.1.tar.xz
"

depends="
core/make
core/pkgconf
core/zlib
core/gzip
core/less
base/libpipeline
base/gdbm
base/groff
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  # musl-friendly:
  # - --disable-nls: evita gettext/catálogos (simplifica muito em musl)
  # - --disable-setuid: não instala man como setuid (seguro e simples)
  # - --without-systemd: evita integração systemd
  # - --with-pager: garante pager previsível
  do_configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --disable-nls \
    --disable-setuid \
    --without-systemd \
    --with-pager=/usr/bin/less

  do_make
}

package() {
  enter_srcdir_auto

  make -j1 DESTDIR="$DESTDIR" install

  # Diretórios comuns que o man-db usa em runtime
  mkdir -p "$DESTDIR/var/cache/man" "$DESTDIR/var/lib/man-db"

  ensure_destdir_nonempty
}

post_install() {
  # Tenta construir a base (não falha se ainda estiver sem algumas páginas)
  if command -v mandb >/dev/null 2>&1; then
    mandb -c 2>/dev/null || true
  fi
}
