#!/bin/sh
set -e
. /usr/share/adm/helpers.sh
adm_defaults

name="runit"
version="2.3.0"
release="1"

srcdir_name="runit-2.3.0"
source_urls="https://smarden.org/runit/runit-2.3.0.tar.gz"

depends="core/make core/gcc"
makedepends=""

prepare() {
  enter_srcdir_auto
  # garante paths corretos no seu sistema (instala em /usr, não /package)
  # runit usa scripts próprios; não há ./configure.
  :
}

build() {
  enter_srcdir_auto
  # compile padrão upstream
  ./package/compile
}

package() {
  enter_srcdir_auto

  mkdir -p "$DESTDIR/usr/bin" "$DESTDIR/usr/sbin"

  # binários principais (gerados em command/)
  for b in chpst runit runit-init runit-run runsv runsvchdir runsvdir sv svlogd utmpset; do
    [ -x "command/$b" ] || continue
    install -m755 "command/$b" "$DESTDIR/usr/bin/$b"
  done

  # alguns distros colocam runit-init em /sbin; aqui mantemos em /usr/sbin para consistência
  if [ -x "$DESTDIR/usr/bin/runit-init" ]; then
    mkdir -p "$DESTDIR/usr/sbin"
    ln -sf ../bin/runit-init "$DESTDIR/usr/sbin/init"
  fi

  ensure_destdir_nonempty
}

post_install(){ :; }
