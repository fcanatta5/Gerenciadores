#!/bin/sh
set -eu

# Pacote "env only": não baixa nada, só instala arquivos de files/
hook_pre_install() { :; }
hook_post_install() { :; }
hook_pre_remove() { :; }
hook_post_remove() { :; }

pkg_fetch()  { :; }
pkg_unpack() { :; }
pkg_build()  { :; }

pkg_install() {
  # Nada aqui: o pm.sh copiará automaticamente pkgs/.../files/ para DESTDIR
  # via copy_files_overlay().
  :
}
