#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="xz"
version="5.6.3"
release="1"

# O tarball extrai para xz-<version>
srcdir_name="xz-5.6.3"

source_urls="
https://tukaani.org/xz/xz-5.6.3.tar.xz
"

depends=""
makedepends=""

prepare() {
  # Patches automáticos (se existirem) são aplicados pelo adm
  :
}

build() {
  enter_srcdir_auto

  # xz usa autotools padrão
  do_configure \
    --disable-static \
    --enable-threads \
    --enable-shared

  do_make
}

package() {
  enter_srcdir_auto

  do_make_install

  ensure_destdir_nonempty
}

post_install() {
  : # nenhuma ação pós-instalação necessária
}
