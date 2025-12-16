#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="ncurses"
version="6.5"
release="1"

srcdir_name="ncurses-6.5"

source_urls="
https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz
"

depends="core/pkgconf core/make"
makedepends=""

prepare() {
  :
}

build() {
  enter_srcdir_auto

  # Build out-of-tree (mais limpo)
  rm -rf build
  mkdir -p build
  cd build

  ../configure \
    --prefix=/usr \
    --mandir=/usr/share/man \
    --with-shared \
    --without-debug \
    --without-normal \
    --with-cxx-shared \
    --enable-pc-files \
    --enable-widec \
    --with-pkg-config-libdir=/usr/lib/pkgconfig

  do_make
}

package() {
  enter_srcdir_auto
  cd build

  make -j1 DESTDIR="$DESTDIR" install

  # Compat: muitos programas ainda linkam -lncurses/-ltinfo
  # Em widec, as libs reais são *w (ncursesw, tinfo).
  libdir="$DESTDIR/usr/lib"
  if [ -d "$libdir" ]; then
    # ncurses
    for so in "$libdir"/libncursesw.so*; do
      [ -e "$so" ] || continue
      ln -sf "$(basename "$so")" "$libdir/libncurses.so.${so##*.}" 2>/dev/null || true
    done
    [ -e "$libdir/libncursesw.so" ] && ln -sf libncursesw.so "$libdir/libncurses.so"

    # tinfo (alguns builds separam libtinfo)
    [ -e "$libdir/libtinfow.so" ] && ln -sf libtinfow.so "$libdir/libtinfo.so" 2>/dev/null || true

    # pkg-config compat
    if [ -f "$libdir/pkgconfig/ncursesw.pc" ] && [ ! -e "$libdir/pkgconfig/ncurses.pc" ]; then
      ln -sf ncursesw.pc "$libdir/pkgconfig/ncurses.pc"
    fi
    if [ -f "$libdir/pkgconfig/tinfow.pc" ] && [ ! -e "$libdir/pkgconfig/tinfo.pc" ]; then
      ln -sf tinfow.pc "$libdir/pkgconfig/tinfo.pc"
    fi
  fi

  ensure_destdir_nonempty
}

post_install() {
  : # ncurses não exige pós-instalação obrigatória
}
