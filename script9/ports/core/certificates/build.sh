#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="certificates"
# Versão como data do bundle (você pode atualizar com adm checksum + upgrade)
version="20251202"
release="1"

# Não há diretório extraído; é um arquivo direto
srcdir_name=""

source_urls="
https://curl.se/ca/cacert.pem
"

depends=""
makedepends=""

prepare() { :; }

build() {
  : # nada a compilar
}

package() {
  # O adm já baixou para /var/cache/adm/distfiles/cacert.pem
  CACERT="/var/cache/adm/distfiles/cacert.pem"
  [ -f "$CACERT" ] || adm_die "cacert.pem não encontrado em distfiles"

  install -d "$DESTDIR/etc/ssl/certs"
  install -m 0644 "$CACERT" "$DESTDIR/etc/ssl/certs/ca-certificates.crt"

  # symlink tradicional
  mkdir -p "$DESTDIR/etc/ssl"
  ln -sf certs/ca-certificates.crt "$DESTDIR/etc/ssl/cert.pem"

  ensure_destdir_nonempty
}

post_install() { :; }
