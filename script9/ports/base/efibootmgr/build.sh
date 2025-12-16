#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="efibootmgr"
version="18"
release="1"

srcdir_name="efibootmgr-18"

# Tarball oficial do release (melhor que "archive/18" para builds reproduzíveis)
source_urls="
https://github.com/rhboot/efibootmgr/releases/download/18/efibootmgr-18.tar.bz2
"

depends="
core/make
core/pkgconf
base/efivar
base/popt
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  ensure_cmd pkg-config

  # Alguns ambientes têm efiboot.pc (do efivar), outros não.
  # Montamos a lista PKGS de forma tolerante.
  PKGS="efivar popt"
  if pkg-config --exists efiboot 2>/dev/null; then
    PKGS="efivar efiboot popt"
  fi

  # EFIDIR define o diretório “padrão” usado quando você cria entradas (ex.: \\EFI\\ADM\\grubx64.efi)
  # Ajuste o BOOTLOADER-ID do seu grub-install para combinar (ex.: ADM).
  do_make \
    PREFIX=/usr \
    LIBDIR=/usr/lib \
    EFIDIR="EFI/ADM" \
    GCC_IGNORE_WERROR=1 \
    PKGS="$PKGS"
}

package() {
  enter_srcdir_auto

  make -j1 DESTDIR="$DESTDIR" install \
    PREFIX=/usr \
    LIBDIR=/usr/lib \
    EFIDIR="EFI/ADM"

  ensure_destdir_nonempty
}

post_install() { :; }
