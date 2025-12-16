#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="ninja"
version="1.13.2"
release="1"

# Tarball do GitHub extrai para ninja-<version>
srcdir_name="ninja-1.13.2"

source_urls="
https://github.com/ninja-build/ninja/archive/refs/tags/v1.13.2.tar.gz
"

depends=""
makedepends="core/python"

prepare() { :; }

build() {
  enter_srcdir_auto
  ensure_cmd python3

  # bootstrap: gera e compila o ninja sem depender de ninja pré-existente
  python3 configure.py --bootstrap
}

package() {
  enter_srcdir_auto

  install -Dm755 ninja "$DESTDIR/usr/bin/ninja"

  # Útil (opcional, mas leve): script python para gerar arquivos .ninja
  install -Dm644 misc/ninja_syntax.py "$DESTDIR/usr/share/ninja/ninja_syntax.py"

  ensure_destdir_nonempty
}

post_install() { :; }
