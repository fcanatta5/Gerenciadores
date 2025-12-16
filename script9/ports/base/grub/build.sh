#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="grub"
version="2.12"
release="1"

srcdir_name="grub-2.12"

source_urls="
https://ftp.gnu.org/gnu/grub/grub-2.12.tar.xz
"

# Dependências reais para build do GRUB.
# efibootmgr e os-prober são runtime/integração, mas manter aqui ajuda no "set desktop" sem esquecer.
depends="
core/make
core/pkgconf
core/bison
core/flex
core/perl
core/openssl
base/efibootmgr
base/os-prober
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  rm -rf build
  mkdir -p build
  cd build

  # UEFI x86_64
  # --disable-nls: evita gettext/NLS (mais simples e estável em musl)
  # --disable-device-mapper: evita puxar LVM/device-mapper (dependência surpresa)
  ../configure \
    --prefix=/usr \
    --sbindir=/usr/sbin \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --disable-nls \
    --disable-werror \
    --disable-device-mapper \
    --with-platform=efi \
    --target=x86_64 \
    --with-bootdir=/boot

  do_make
}

package() {
  enter_srcdir_auto
  cd build

  make -j1 DESTDIR="$DESTDIR" install

  # Diretórios esperados
  mkdir -p "$DESTDIR/boot/grub" "$DESTDIR/etc/default"

  # Default simples (você pode gerar grub.cfg manualmente depois)
  if [ ! -f "$DESTDIR/etc/default/grub" ]; then
    cat >"$DESTDIR/etc/default/grub" <<'EOF'
GRUB_TIMEOUT=5
GRUB_DEFAULT=0
GRUB_DISABLE_OS_PROBER=false
EOF
  fi

  ensure_destdir_nonempty
}

post_install() { :; }
