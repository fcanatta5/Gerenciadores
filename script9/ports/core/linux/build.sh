#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="linux"
version="6.18.1"
release="1"

srcdir_name="linux-6.18.1"

source_urls="
https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.18.1.tar.xz
"

# Dependências típicas para build de kernel.
# (pahole/dwarves é opcional; sem ele você só perde BTF)
depends="
core/make
core/bc
core/bison
core/flex
core/perl
core/python
core/openssl
core/tar
core/xz
"

makedepends=""

prepare() {
  enter_srcdir_auto

  # Se você colocou files/config, usamos ela
  if [ -f "$FILESDIR/config" ]; then
    adm_msg "usando config do port: files/config"
    cp -f "$FILESDIR/config" .config
    yes "" | make olddefconfig
  else
    adm_msg "sem files/config; usando defconfig"
    make defconfig
  fi
}

build() {
  enter_srcdir_auto

  # Se você tiver pahole instalado e quiser BTF, mantenha como está.
  # Se não tiver, o kernel desabilita/ignora dependendo do config.
  do_make
}

package() {
  enter_srcdir_auto

  # Descobre release real (inclui LOCALVERSION se configurado)
  KREL="$(make -s kernelrelease)"
  [ -n "$KREL" ] || adm_die "não foi possível obter kernelrelease"

  # 1) Módulos
  make -j1 DESTDIR="$DESTDIR" modules_install

  # 2) Kernel image + System.map + config em /boot
  mkdir -p "$DESTDIR/boot"
  install -m644 System.map "$DESTDIR/boot/System.map-$KREL"
  install -m644 .config    "$DESTDIR/boot/config-$KREL"

  # x86_64: bzImage padrão
  if [ -f "arch/x86/boot/bzImage" ]; then
    install -m644 arch/x86/boot/bzImage "$DESTDIR/boot/vmlinuz-$KREL"
  else
    adm_die "bzImage não encontrado (arch/x86/boot/bzImage). Arquitetura/config inesperada?"
  fi

  # 3) Headers do kernel (para /usr/include do sistema final)
  # Isso instala headers sanitizados (UAPI), não o source inteiro.
  make -j1 headers_install INSTALL_HDR_PATH="$DESTDIR/usr"

  ensure_destdir_nonempty
}

post_install() {
  # Atualiza dependências de módulos se depmod existir
  if command -v depmod >/dev/null 2>&1; then
    KREL="$(ls -1 /lib/modules 2>/dev/null | tail -n1 || true)"
    [ -n "$KREL" ] && depmod -a "$KREL" || true
  fi
}
