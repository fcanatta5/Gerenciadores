#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="openssl"
version="3.5.4"
release="1"

srcdir_name="openssl-3.5.4"

source_urls="
https://www.openssl.org/source/openssl-3.5.4.tar.gz
"

depends="core/zlib core/perl"
makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  # OpenSSL usa perl Configure (não autotools)
  # linux-x86_64 é o target típico para x86_64
  perl ./Configure linux-x86_64 \
    --prefix=/usr \
    --openssldir=/etc/ssl \
    shared zlib

  do_make
}

package() {
  enter_srcdir_auto

  # Instala só o necessário (libs, headers, binários) + diretórios padrão de ssl
  make DESTDIR="$DESTDIR" install_sw install_ssldirs

  ensure_destdir_nonempty
}

post_install() { :; }
