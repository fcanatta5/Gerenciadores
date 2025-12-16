#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="make"
version="4.4.1"
release="1"

# O tarball extrai para make-<version>
srcdir_name="make-4.4.1"

source_urls="
https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz
"

depends=""
makedepends=""

prepare() {
  # GNU make já vem com configure pronto
  # Patches automáticos (se existirem) são aplicados pelo adm
  :
}

build() {
  enter_srcdir_auto

  do_configure \
    --disable-static \
    --enable-job-server

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
