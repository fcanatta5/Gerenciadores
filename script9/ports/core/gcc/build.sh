#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="gcc"
version="15.2.0"
release="1"

srcdir_name="gcc-15.2.0"

source_urls="
https://gcc.gnu.org/pub/gcc/releases/gcc-15.2.0/gcc-15.2.0.tar.xz
https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz
https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz
https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz
https://libisl.sourceforge.io/isl-0.27.tar.xz
"

depends="
core/binutils
core/zlib
core/zstd
core/xz
core/bzip2
core/make
core/pkgconf
core/perl
"

# ferramentas que comumente são necessárias ao build do gcc em sistemas mínimos
makedepends="
core/python
core/bison
core/flex
core/texinfo
"

prepare() {
  enter_srcdir_auto

  # Injeta prereqs (GMP/MPFR/MPC/ISL) dentro do tree do GCC
  rm -rf gmp mpfr mpc isl

  [ -d "$SRCDIR/gmp-6.3.0" ]  || adm_die "prereq ausente: gmp-6.3.0"
  [ -d "$SRCDIR/mpfr-4.2.1" ] || adm_die "prereq ausente: mpfr-4.2.1"
  [ -d "$SRCDIR/mpc-1.3.1" ]  || adm_die "prereq ausente: mpc-1.3.1"
  [ -d "$SRCDIR/isl-0.27" ]   || adm_die "prereq ausente: isl-0.27"

  mv "$SRCDIR/gmp-6.3.0"  ./gmp
  mv "$SRCDIR/mpfr-4.2.1" ./mpfr
  mv "$SRCDIR/mpc-1.3.1"  ./mpc
  mv "$SRCDIR/isl-0.27"   ./isl
}

build() {
  enter_srcdir_auto

  rm -rf build
  mkdir -p build
  cd build

  ../configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --disable-nls \
    --disable-multilib \
    --enable-languages=c,c++ \
    --enable-shared \
    --enable-threads=posix \
    --enable-__cxa_atexit \
    --enable-lto \
    --enable-plugin \
    --with-system-zlib \
    --disable-werror

  do_make
}

package() {
  enter_srcdir_auto
  cd build

  # install serial é mais confiável para GCC
  make -j1 DESTDIR="$DESTDIR" install

  ensure_destdir_nonempty
}

post_install() { :; }
