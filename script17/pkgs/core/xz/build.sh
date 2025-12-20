#!/bin/sh
set -eu

# XZ Utils 5.8.1
# Fonte (release tarball): GitHub Releases (tukaani-project/xz) 1
XZ_URL="https://github.com/tukaani-project/xz/releases/download/v${PKGVER}/xz-${PKGVER}.tar.xz"
XZ_TARBALL="${WORKDIR}/xz-${PKGVER}.tar.xz"
XZ_SHA256="ca52a888d7fcfec1f85157beb231bd6d4466632fbdb7411c8e6aa5ca0e0e50c2"  # 2

have() { command -v "$1" >/dev/null 2>&1; }

fetch_file() {
  url=$1 out=$2
  if have wget; then
    wget -O "$out.tmp" "$url"
  elif have curl; then
    curl -L -o "$out.tmp" "$url"
  else
    echo "ERRO: precisa de wget ou curl para baixar fontes." >&2
    exit 1
  fi
  mv -f "$out.tmp" "$out"
}

sha256_check() {
  file=$1 expected=$2
  got=$(sha256sum "$file" | awk '{print $1}')
  if [ "$got" != "$expected" ]; then
    echo "ERRO: SHA256 inválido para $(basename "$file")" >&2
    echo "Esperado: $expected" >&2
    echo "Obtido:   $got" >&2
    exit 1
  fi
}

# Hooks opcionais (o pm chama se existirem)
hook_pre_install() { :; }
hook_post_install() { :; }
hook_pre_remove() { :; }
hook_post_remove() { :; }

pkg_fetch() {
  mkdir -p "$WORKDIR"
  if [ -f "$XZ_TARBALL" ]; then
    sha256_check "$XZ_TARBALL" "$XZ_SHA256"
    return 0
  fi
  fetch_file "$XZ_URL" "$XZ_TARBALL"
  sha256_check "$XZ_TARBALL" "$XZ_SHA256"
}

pkg_unpack() {
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"

  # Extração robusta de .tar.xz:
  # 1) tenta tar -xJf
  # 2) fallback: xz -dc | tar -xf -
  if tar -C "$SRCDIR" --strip-components=1 -xJf "$XZ_TARBALL" >/dev/null 2>&1; then
    :
  else
    if have xz; then
      xz -dc "$XZ_TARBALL" | tar -C "$SRCDIR" --strip-components=1 -xf -
    else
      echo "ERRO: não foi possível extrair .tar.xz (precisa tar com -J ou xz)." >&2
      exit 1
    fi
  fi
}

pkg_build() {
  cd "$SRCDIR"

  # Layout tradicional: binários em /bin, libs em /usr/lib
  # prefix=/usr é padrão para libs/headers/manpages.
  #
  # Nota: bindir=/bin é absoluto (tradicional). Evita /usr/bin (usr-merge).
  ./configure \
    --prefix=/usr \
    --bindir=/bin \
    --sbindir=/sbin \
    --libdir=/usr/lib \
    --includedir=/usr/include \
    --mandir=/usr/share/man \
    --disable-static

  make -j"$PM_JOBS"
}

pkg_install() {
  cd "$SRCDIR"

  make DESTDIR="$DESTDIR" install

  # Segurança/consistência: garantir que xz está em /bin no pacote
  if [ ! -x "$DESTDIR/bin/xz" ] && [ -x "$DESTDIR/usr/bin/xz" ]; then
    mkdir -p "$DESTDIR/bin"
    mv -f "$DESTDIR/usr/bin/xz" "$DESTDIR/bin/xz"
  fi

  # Se algum wrapper caiu em /usr/bin, não queremos usr-merge.
  # Mantemos /usr/bin apenas para o que for realmente "não essencial" (aqui, melhor não deixar nada).
  if [ -d "$DESTDIR/usr/bin" ]; then
    # Se ficou vazio, remove.
    rmdir "$DESTDIR/usr/bin" 2>/dev/null || true
  fi
}
