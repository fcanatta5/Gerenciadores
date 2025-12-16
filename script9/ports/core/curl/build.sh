#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="curl"
version="8.17.0"
release="1"

srcdir_name="curl-8.17.0"

source_urls="
https://curl.se/download/curl-8.17.0.tar.xz
"

depends="core/openssl core/zlib core/certificates"
makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  do_configure \
    --disable-static \
    --with-openssl=/usr \
    --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt

  do_make
}

package() {
  enter_srcdir_auto
  do_make_install
  ensure_destdir_nonempty
}

post_install() { :; }
