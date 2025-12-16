#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="meson"
version="1.10.0"
release="1"

srcdir_name="meson-1.10.0"

source_urls="
https://pypi.org/packages/source/m/meson/meson-1.10.0.tar.gz
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

  # Instala o meson como pacote python (gera /usr/bin/meson)
  python_install_project
}

package() {
  ensure_destdir_nonempty
}

post_install() { :; }
