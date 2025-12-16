#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="m4"
version="1.4.20"
release="1"

# O tarball do m4 extrai para m4-<version>
srcdir_name="m4-1.4.20"

# Fonte oficial
source_urls="
https://ftp.gnu.org/gnu/m4/m4-1.4.20.tar.xz
"

depends=""
makedepends=""

prepare() {
  # O adm aplica patches automaticamente se existirem em patches/
  # Aqui fica reservado para ajustes adicionais se necessário.
  :
}

build() {
  enter_srcdir_auto
  # Autotools padrão (bootstrap/autoreconf se necessário, configure, make)
  # Em releases do GNU m4 já vem com configure pronto, então é tranquilo.
  do_configure
  do_make
}

package() {
  enter_srcdir_auto
  do_make_install
  ensure_destdir_nonempty
}

post_install() {
  : # sem ações pós-instalação necessárias para m4
}
