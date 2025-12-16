#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="grub-cfg"
version="1.0"
release="1"

srcdir_name=""   # sem sources
source_urls=""

depends="
base/grub
base/os-prober
core/coreutils
core/util-linux
"

makedepends=""

prepare() { :; }

build() { :; }

package() {
  # Instala o gerador
  install -Dm755 "$FILESDIR/adm-grubcfg" "$DESTDIR/usr/sbin/adm-grubcfg"

  # Instala header template
  install -Dm644 "$FILESDIR/grub.cfg.header" "$DESTDIR/usr/share/adm/grub.cfg.header"

  # Diretórios padrão
  mkdir -p "$DESTDIR/boot/grub" "$DESTDIR/etc/default"

  # /etc/default/grub mínimo (não substitui se já existir)
  if [ ! -e "$DESTDIR/etc/default/grub" ]; then
    cat >"$DESTDIR/etc/default/grub" <<'EOF'
GRUB_TIMEOUT=5
GRUB_DEFAULT=0
GRUB_DISABLE_OS_PROBER=false
# Ajuste se quiser parâmetros extras:
# GRUB_CMDLINE_LINUX_DEFAULT="quiet"
EOF
  fi

  ensure_destdir_nonempty
}

post_install() {
  # Tenta gerar automaticamente (não falha a instalação se algo não estiver pronto)
  if command -v /usr/sbin/adm-grubcfg >/dev/null 2>&1; then
    /usr/sbin/adm-grubcfg --update || true
  fi
}
