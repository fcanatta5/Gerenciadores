#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="wheel"
version="0.45.1"
release="1"

srcdir_name="wheel-0.45.1"

source_urls="
https://pypi.org/packages/source/w/wheel/wheel-0.45.1.tar.gz
"

depends="
core/python
core/setuptools
"
makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto
  ensure_cmd python3

  # Instala a partir do source local no DESTDIR via --root
  python_install_project
}

package() {
  ensure_destdir_nonempty
}

post_install() { :; }
