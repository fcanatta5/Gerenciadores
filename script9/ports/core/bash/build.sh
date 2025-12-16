#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="bash"
version="5.2.37"
release="1"

srcdir_name="bash-5.2.37"

source_urls="
https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz
"

depends="core/readline core/ncurses core/make"
makedepends=""

prepare() {
  :
}

build() {
  enter_srcdir_auto

  # musl-friendly:
  # - sem bash malloc (evita comportamentos estranhos)
  # - sem nls (gettext)
  do_configure \
    --disable-static \
    --without-bash-malloc \
    --disable-nls \
    --with-installed-readline

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install

  # garante /bin/bash (muito software assume isso)
  mkdir -p "$DESTDIR/bin"
  ln -sf ../usr/bin/bash "$DESTDIR/bin/bash"

  ensure_destdir_nonempty
}

post_install() { :; }
