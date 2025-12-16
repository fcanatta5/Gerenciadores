#!/bin/sh
set -e
. /usr/share/adm/helpers.sh
adm_defaults

name="gptfdisk"
version="1.0.10"
release="1"

srcdir_name="gptfdisk-1.0.10"
source_urls="https://downloads.sourceforge.net/gptfdisk/gptfdisk-1.0.10.tar.gz"

depends="core/make core/gcc core/ncurses core/util-linux"
makedepends=""

prepare(){ :; }

build() {
  enter_srcdir_auto
  # compila gdisk + cgdisk (ncurses) + sgdisk
  do_make CXX="${CXX:-g++}" CC="${CC:-gcc}"
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" PREFIX=/usr install || {
    # fallback (algumas versões não têm target install padronizado)
    mkdir -p "$DESTDIR/usr/sbin"
    for b in gdisk sgdisk cgdisk fixparts; do
      [ -x "$b" ] && install -m755 "$b" "$DESTDIR/usr/sbin/$b"
    done
  }
  ensure_destdir_nonempty
}

post_install(){ :; }
