#!/bin/sh
set -e

. /usr/share/adm/helpers.sh
adm_defaults

name="rust-src"
version="1.92.0"
release="1"

srcdir_name="rust-src-1.92.0"

source_urls="
https://static.rust-lang.org/dist/rust-src-1.92.0.tar.xz
"

depends="
base/rust
core/tar
core/xz
"

makedepends=""

prepare() { :; }
build() { :; }

package() {
  enter_srcdir_auto

  # O tarball normalmente contém um diretório "rust-src-<ver>/rust-src/..."
  # Instalamos o conteúdo em /usr/lib/rustlib/src/rust (layout esperado por ferramentas).
  out="$DESTDIR/usr/lib/rustlib/src/rust"
  mkdir -p "$out"

  if [ -d "./rust-src" ]; then
    # Layout comum: rust-src-<ver>/rust-src/library/...
    cp -a ./rust-src/* "$out/"
  elif [ -d "./library" ]; then
    # Fallback: já veio “no nível”
    cp -a ./library "$out/"
  else
    # Fallback robusto: procure o diretório "library"
    libdir="$(find . -maxdepth 3 -type d -name library 2>/dev/null | head -n1 || true)"
    [ -n "$libdir" ] || adm_die "rust-src: não encontrei diretório 'library' no tarball"
    cp -a "$libdir" "$out/"
  fi

  # (Opcional) marcação
  mkdir -p "$DESTDIR/usr/share/adm"
  printf '%s\n' "$version" >"$DESTDIR/usr/share/adm/rust-src.version"

  ensure_destdir_nonempty
}

post_install() { :; }
