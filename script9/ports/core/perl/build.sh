#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="perl"
version="5.40.0"
release="1"

srcdir_name="perl-5.40.0"

source_urls="
https://www.cpan.org/src/5.0/perl-5.40.0.tar.xz
"

depends=""
makedepends=""

prepare() {
  :
}

build() {
  enter_srcdir_auto

  # Perl usa seu próprio Configure (não é autotools)
  sh ./Configure -des \
    -Dprefix=/usr \
    -Dvendorprefix=/usr \
    -Dsiteprefix=/usr \
    -Dprivlib=/usr/lib/perl5/core_perl \
    -Darchlib=/usr/lib/perl5/core_perl \
    -Dman1dir=/usr/share/man/man1 \
    -Dman3dir=/usr/share/man/man3

  do_make
}

package() {
  enter_srcdir_auto

  make DESTDIR="$DESTDIR" install

  ensure_destdir_nonempty
}

post_install() {
  :
}
