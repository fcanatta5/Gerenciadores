#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="zstd"
version="1.5.6"
release="1"

# O tarball extrai para zstd-<version>
srcdir_name="zstd-1.5.6"

source_urls="
https://github.com/facebook/zstd/releases/download/v1.5.6/zstd-1.5.6.tar.gz
"

depends=""
makedepends=""

prepare() {
  # Patches automáticos (se existirem) são aplicados pelo adm
  :
}

build() {
  enter_srcdir_auto

  # Build da biblioteca e das ferramentas
  # PREFIX é respeitado pelo makefile do zstd
  do_make PREFIX=/usr
}

package() {
  enter_srcdir_auto

  # Instala biblioteca + headers + binários
  make DESTDIR="$DESTDIR" PREFIX=/usr install

  ensure_destdir_nonempty
}

post_install() {
  : # nenhuma ação pós-instalação necessária
}
