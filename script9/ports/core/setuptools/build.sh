#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="setuptools"
version="80.9.0"
release="1"

srcdir_name="setuptools-80.9.0"

source_urls="
https://pypi.org/packages/source/s/setuptools/setuptools-80.9.0.tar.gz
"

depends="core/python"
makedepends=""

prepare() { :; }

build() {
  enter_srcdir_auto
  ensure_cmd python3

  # O build “real” do setuptools é python-only; pip instala a partir do source local
  # e grava em DESTDIR via --root.
  python_install_project
}

package() {
  # python_install_project já instala em DESTDIR. Apenas valida.
  ensure_destdir_nonempty
}

post_install() { :; }
