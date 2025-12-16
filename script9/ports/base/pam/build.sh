#!/bin/sh
set -eu

NAME=pam
VERSION=1.7.1
SOURCE="https://github.com/linux-pam/linux-pam/releases/download/v${VERSION}/Linux-PAM-${VERSION}.tar.xz"

depends="core/meson core/ninja core/pkgconf core/gcc core/make"

build() {
  mkdir -p build
  cd build

  meson setup .. \
    --prefix=/usr \
    --buildtype=release \
    -D docdir="/usr/share/doc/Linux-PAM-${VERSION}"

  ninja
}

install() {
  cd build
  DESTDIR="${PKG}" ninja install

  # BLFS recomenda setuid em unix_chkpwd após instalar no sistema real. 6
  # Em staging (DESTDIR) fazemos o chmod para já vir certo no pacote:
  chmod 4755 "${PKG}/usr/sbin/unix_chkpwd" 2>/dev/null || true

  # Não usamos systemd; se algo criar /usr/lib/systemd, removemos.
  rm -rf "${PKG}/usr/lib/systemd" 2>/dev/null || true
}
