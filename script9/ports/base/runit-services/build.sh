#!/bin/sh
set -eu

NAME=runit-services
VERSION=1
SOURCE=""  # sem tarball, só arquivos em files/

depends="core/runit base/metalog base/dbus base/elogind base/seatd base/dhcpcd base/wpa_supplicant"

build() { :; }

install() {
  # instala árvore /etc/sv
  mkdir -p "${PKG}/etc"
  cp -a files/etc/sv "${PKG}/etc/"

  # habilita serviços por padrão (symlinks)
  mkdir -p "${PKG}/etc/runit/runsvdir/default"
  for s in metalog dbus elogind seatd dhcpcd wpa_supplicant; do
    ln -snf "/etc/sv/$s" "${PKG}/etc/runit/runsvdir/default/$s"
  done

  # cria diretórios base de log (svlogd)
  mkdir -p "${PKG}/var/log"
  for s in metalog dbus elogind seatd dhcpcd wpa_supplicant; do
    mkdir -p "${PKG}/var/log/$s"
  done
}
