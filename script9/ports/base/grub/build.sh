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

  # UEFI x86_64, sem NLS (evita gettext; mais simples em musl)
  ../configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --sbindir=/usr/sbin \
    --disable-nls \
    --disable-werror \
    --with-platform=efi \
    --target=x86_64 \
    --with-bootdir=/boot

  do_make
}

package() {
  enter_srcdir_auto
  cd build

  make -j1 DESTDIR="$DESTDIR" install

  # Diretórios padrão esperados
  mkdir -p "$DESTDIR/etc/default" "$DESTDIR/boot/grub"

  # Arquivo default opcional (não interfere se você gerar grub.cfg manual)
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
