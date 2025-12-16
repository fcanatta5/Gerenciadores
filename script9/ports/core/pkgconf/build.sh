#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="pkgconf"
version="2.3.0"
release="1"

# O tarball extrai para pkgconf-<version>
srcdir_name="pkgconf-2.3.0"

source_urls="
https://distfiles.dereferenced.org/pkgconf/pkgconf-2.3.0.tar.xz
"

depends=""
makedepends=""

prepare() {
  # Patches automáticos (se existirem) são aplicados pelo adm
  :
}

build() {
  enter_srcdir_auto

  # Configuração padrão recomendada
  do_configure \
    --disable-static \
    --enable-shared \
    --with-system-libdir=/usr/lib \
    --with-pkg-config-dir="/usr/lib/pkgconfig:/usr/share/pkgconfig:/usr/lib64/pkgconfig"

  do_make
}

package() {
  enter_srcdir_auto

  do_make_install

  # Compatibilidade: pkg-config -> pkgconf
  mkdir -p "$DESTDIR/usr/bin"
  ln -sf pkgconf "$DESTDIR/usr/bin/pkg-config"

  ensure_destdir_nonempty
}

post_install() {
  : # nenhuma ação pós-instalação necessária
}
