#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="shadow"
version="4.18.0"
release="1"

srcdir_name="shadow-4.18.0"

source_urls="
https://github.com/shadow-maint/shadow/releases/download/4.18.0/shadow-4.18.0.tar.xz
"

# Em musl, use libxcrypt para hash moderno (yescrypt/sha512 etc.)
depends="
core/make
core/pam
core/libxcrypt
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  # musl-friendly: sem NLS; com PAM; evita colisões com util-linux (já desabilitamos su/login lá)
  do_configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --disable-nls \
    --with-libpam \
    --with-yescrypt

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install

  # Garante diretórios padrão esperados
  mkdir -p "$DESTDIR/etc" "$DESTDIR/var/log" "$DESTDIR/var/mail"
  ensure_destdir_nonempty
}

post_install() {
  : # a configuração real de PAM vem depois (arquivos em /etc/pam.d)
}
