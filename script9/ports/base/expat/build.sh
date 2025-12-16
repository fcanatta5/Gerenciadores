#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="expat"
version="2.7.3"
release="1"

srcdir_name="expat-2.7.3"

source_urls="
https://sourceforge.net/projects/expat/files/expat/2.7.3/expat-2.7.3.tar.xz
"

depends="core/make"
makedepends="core/pkgconf"

prepare() {
  enter_srcdir_auto
  # Se houver patches em patches/*.patch, o seu adm (pelo padrão que você vem usando)
  # deve aplicá-los antes do build; aqui não precisamos fazer nada.
  :
}

build() {
  enter_srcdir_auto

  # Expat normalmente fornece ./configure; isso evita depender de cmake no bootstrap.
  if [ -x ./configure ]; then
    do_configure \
      --prefix=/usr \
      --disable-static \
      --enable-shared
    do_make
    return 0
  fi

  # Fallback (caso venha sem configure por algum motivo): cmake+ninja/make
  if command -v cmake >/dev/null 2>&1; then
    rm -rf build
    mkdir -p build
    cd build
    cmake .. \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DBUILD_SHARED_LIBS=ON \
      -DEXPAT_BUILD_TESTS=OFF
    do_make
    return 0
  fi

  adm_die "expat: sem ./configure e sem cmake disponível"
}

package() {
  enter_srcdir_auto

  if [ -x ./configure ]; then
    make -j1 DESTDIR="$DESTDIR" install
  else
    cd build
    make -j1 DESTDIR="$DESTDIR" install
  fi

  ensure_destdir_nonempty
}

post_install() { :; }
