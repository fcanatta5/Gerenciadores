#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="texinfo"
version="7.2"
release="1"

srcdir_name="texinfo-7.2"

source_urls="
https://ftp.gnu.org/gnu/texinfo/texinfo-7.2.tar.gz
"

depends="
core/perl
core/make
core/ncurses
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  do_configure \
    --disable-static \
    --disable-nls

  do_make
}

package() {
  enter_srcdir_auto
  make -j1 DESTDIR="$DESTDIR" install
  ensure_destdir_nonempty
}

post_install() {
  # Atualiza o "dir" do info (se presente). É seguro e comum em sistemas desktop.
  if command -v install-info >/dev/null 2>&1; then
    for f in /usr/share/info/*.info /usr/share/info/*.info.gz; do
      [ -e "$f" ] || continue
      install-info --dir-file=/usr/share/info/dir "$f" 2>/dev/null || true
    done
  fi
}
