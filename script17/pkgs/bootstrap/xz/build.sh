#!/bin/sh
set -eu

# xz 5.8.1 (stable)
# Fonte: GitHub release tarball
XZ_URL="https://github.com/tukaani-project/xz/releases/download/v${PKGVER}/xz-${PKGVER}.tar.xz"
XZ_TARBALL="${WORKDIR}/xz-${PKGVER}.tar.xz"

# SHA256 do xz-5.8.1.tar.xz 1
XZ_SHA256="0b54f79df85912504de0b14aec7971e3f964491af1812d83447005807513cd9e"

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

  # Bootstrap: objetivo é ter xz REAL cedo no sysroot/chroot.
  # Layout tradicional: /bin; libs/headers em /usr.
  #
  # Observação: usamos /usr como prefixo (padrão para libs),
  # e bindir absoluto em /bin (tradicional).
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

  # Garantias para "bin tradicional"
  if [ ! -x "$DESTDIR/bin/xz" ] && [ -x "$DESTDIR/usr/bin/xz" ]; then
    mkdir -p "$DESTDIR/bin"
    mv -f "$DESTDIR/usr/bin/xz" "$DESTDIR/bin/xz"
  fi

  # Limpar /usr/bin se sobrar vazio (evita usr-merge acidental)
  if [ -d "$DESTDIR/usr/bin" ]; then
    rmdir "$DESTDIR/usr/bin" 2>/dev/null || true
  fi
}
