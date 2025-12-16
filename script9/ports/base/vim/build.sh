#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="vim"
version="9.1.1806"
release="2"

srcdir_name="vim-9.1.1806"

source_urls="
https://ftp2.osuosl.org/pub/blfs/conglomeration/vim/vim-9.1.1806.tar.gz
"

# Para GUI/clipboard completo em X11/Wayland via GTK3:
# - gtk3 puxa todo stack (glib/cairo/pango/etc.)
# - xorg libs para clipboard e integração X11
# - ncurses para o vim terminal
depends="
core/make
core/pkgconf
core/ncurses
core/python
core/perl
core/gtk3
core/xorgproto
core/libxcb
"

makedepends=""

prepare() {
  :
}

build() {
  enter_srcdir_auto
  cd src

  # GUI GTK3:
  # - --enable-gui=gtk3: gvim com GTK3 (Wayland/X11 via backend do GTK)
  # - --with-x: habilita recursos X (inclui +clipboard via X11)
  # - --enable-clipboard: força suporte a clipboard
  # - --with-features=huge: build completo
  # - --enable-multibyte: UTF-8 útil mesmo em musl
  # - --disable-nls: evita gettext/NLS
  # - --enable-fail-if-missing: falha cedo se deps não existirem (melhor que “meio instalado”)
  #
  # Nota: removi --with-tlib=ncursesw porque em build GUI isso pode variar; pkg-config resolve.
  do_configure \
    --prefix=/usr \
    --with-features=huge \
    --enable-multibyte \
    --enable-terminal \
    --enable-gui=gtk3 \
    --with-x \
    --enable-clipboard \
    --disable-nls \
    --enable-fail-if-missing \
    --with-vim-name=vim \
    --with-ex-name=ex \
    --with-view-name=view \
    --with-global-runtime=/usr/share/vim \
    --enable-python3interp=yes \
    --enable-perlinterp=yes \
    --disable-netbeans

  do_make
}

package() {
  enter_srcdir_auto
  cd src

  make -j1 DESTDIR="$DESTDIR" install

  # Symlinks tradicionais
  mkdir -p "$DESTDIR/usr/bin"
  ln -sf vim  "$DESTDIR/usr/bin/vi"
  ln -sf gvim "$DESTDIR/usr/bin/gview" 2>/dev/null || true

  # Desktop integration (opcional)
  if [ -f "$FILESDIR/gvim.desktop" ]; then
    install -Dm644 "$FILESDIR/gvim.desktop" \
      "$DESTDIR/usr/share/applications/gvim.desktop"
  fi

  if [ -f "$FILESDIR/gvim.png" ]; then
    install -Dm644 "$FILESDIR/gvim.png" \
      "$DESTDIR/usr/share/icons/hicolor/48x48/apps/gvim.png"
  fi

  ensure_destdir_nonempty
}

post_install() { :; }
