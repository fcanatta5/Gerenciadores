#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="wpa_supplicant"
version="2.11"
release="1"

srcdir_name="wpa_supplicant-2.11"
source_urls="
https://w1.fi/releases/wpa_supplicant-2.11.tar.gz
"

# Para nl80211 (o driver moderno) você precisa libnl.
# Para WPA-EAP/TLS você precisa openssl.
depends="
core/make
core/gcc
core/pkgconf
core/openssl
base/libnl
"

makedepends=""

prepare() {
  enter_srcdir_auto
  cd wpa_supplicant

  # base config
  cp -f defconfig .config

  # habilita nl80211 + openssl + dbus (opcional; comente se não quiser)
  {
    echo "CONFIG_CTRL_IFACE=y"
    echo "CONFIG_CTRL_IFACE_DBUS_NEW=y"
    echo "CONFIG_CTRL_IFACE_DBUS_INTRO=y"
    echo "CONFIG_DRIVER_NL80211=y"
    echo "CONFIG_LIBNL32=y"
    echo "CONFIG_TLS=openssl"
    echo "CONFIG_IEEE8021X_EAPOL=y"
  } >> .config
}

build() {
  enter_srcdir_auto
  cd wpa_supplicant

  do_make BINDIR=/usr/sbin LIBDIR=/usr/lib
}

package() {
  enter_srcdir_auto
  cd wpa_supplicant

  make -j1 DESTDIR="$DESTDIR" BINDIR=/usr/sbin LIBDIR=/usr/lib install

  # conf padrão (seguro)
  install -Dm644 "$FILESDIR/wpa_supplicant.conf" \
    "$DESTDIR/etc/wpa_supplicant/wpa_supplicant.conf"

  ensure_destdir_nonempty
}

post_install(){ :; }
