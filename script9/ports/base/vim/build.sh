#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="vim"
version="9.1.1806"
release="1"

srcdir_name="vim-9.1.1806"

source_urls="
https://ftp2.osuosl.org/pub/blfs/conglomeration/vim/vim-9.1.1806.tar.gz
"

depends="
core/make
core/ncurses
core/pkgconf
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto
  cd src

  # Terminal-only (sem GUI/X), estável para musl
  # multibyte ligado (útil mesmo sem glibc locales)
  do_configure \
    --prefix=/usr \
    --with-features=huge \
    --enable-multibyte \
    --with-tlib=ncursesw \
    --disable-nls \
    --disable-gui \
    --without-x \
    --disable-netbeans \
    --enable-terminal \
    --with-vim-name=vim \
    --with-ex-name=ex \
    --with-view-name=view \
    --with-global-runtime=/usr/share/vim

  do_make
}

package() {
  enter_srcdir_auto
  cd src

  make -j1 DESTDIR="$DESTDIR" install

  # symlinks vi (muito software assume)
  mkdir -p "$DESTDIR/usr/bin"
  ln -sf vim "$DESTDIR/usr/bin/vi"
  ln -sf vim "$DESTDIR/usr/bin/vimdiff" 2>/dev/null || true

  ensure_destdir_nonempty
}

post_install() { :; }
