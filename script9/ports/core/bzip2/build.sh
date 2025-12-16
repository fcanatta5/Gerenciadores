#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="bzip2"
version="1.0.8"
release="1"

# O tarball extrai para bzip2-<version>
srcdir_name="bzip2-1.0.8"

source_urls="
https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz
"

depends=""
makedepends=""

prepare() {
  # bzip2 upstream não usa autotools
  # Patches automáticos (se existirem) são aplicados pelo adm
  :
}

build() {
  enter_srcdir_auto

  # Compila biblioteca e ferramentas
  do_make \
    CFLAGS="$CFLAGS -fPIC"
}

package() {
  enter_srcdir_auto

  # O Makefile do bzip2 ignora DESTDIR.
  # Estratégia correta: instalar em PREFIX temporário e copiar para DESTDIR.
  TMPROOT="$WORKDIR/_install"
  rm -rf "$TMPROOT"
  mkdir -p "$TMPROOT"

  make PREFIX="$TMPROOT/usr" install

  # Copia tudo para DESTDIR
  mkdir -p "$DESTDIR"
  ( cd "$TMPROOT" && tar -cpf - . ) | ( cd "$DESTDIR" && tar -xpf - )

  ensure_destdir_nonempty
}

post_install() {
  : # nenhuma ação pós-instalação necessária
}
