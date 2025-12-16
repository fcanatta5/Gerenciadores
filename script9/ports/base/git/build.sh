#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="git"
version="2.52.0"
release="1"

srcdir_name="git-2.52.0"

source_urls="
https://www.kernel.org/pub/software/scm/git/git-2.52.0.tar.xz
"

# Dependências reais para um git funcional com HTTPS:
# - curl + openssl: fetch/push via https
# - zlib: packfiles
# - expat: parsing (ex.: http-push/dav e alguns formatos)
# - perl: vários scripts do git
# - certificates: CA bundle para HTTPS
depends="
core/make
core/zlib
core/openssl
core/curl
core/perl
core/certificates
base/expat
"

makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto

  # Release tarball já vem com ./configure.
  # Em musl, evitamos gettext (NLS) e dependências extras de docs/tcltk.
  ./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --sbindir=/usr/sbin

  do_make \
    NO_GETTEXT=YesPlease \
    NO_TCLTK=YesPlease \
    NO_PCRE2=YesPlease \
    NO_DOCS=YesPlease
}

package() {
  enter_srcdir_auto

  make -j1 DESTDIR="$DESTDIR" install \
    NO_GETTEXT=YesPlease \
    NO_TCLTK=YesPlease \
    NO_PCRE2=YesPlease \
    NO_DOCS=YesPlease

  # Garantias úteis
  mkdir -p "$DESTDIR/etc"
  ensure_destdir_nonempty
}

post_install() { :; }
