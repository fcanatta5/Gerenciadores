#!/bin/sh
set -eu

# Bootstrap GNU Binutils 2.45
# Fonte: https://ftp.gnu.org/gnu/binutils/binutils-2.45.tar.xz
# SHA256: c50c0e7f9cb188980e2cc97e4537626b1672441815587f1eab69d2a1bfbef5d2

BINUTILS_URL="https://ftp.gnu.org/gnu/binutils/binutils-${PKGVER}.tar.xz"
BINUTILS_TARBALL="${WORKDIR}/binutils-${PKGVER}.tar.xz"
BINUTILS_SHA256="c50c0e7f9cb188980e2cc97e4537626b1672441815587f1eab69d2a1bfbef5d2"

: "${TARGET:=x86_64-linux-musl}"
: "${TC_SYSROOT:=}"
: "${BOOTSTRAP:=0}"

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
  if [ -f "$BINUTILS_TARBALL" ]; then
    sha256_check "$BINUTILS_TARBALL" "$BINUTILS_SHA256"
    return 0
  fi
  fetch_file "$BINUTILS_URL" "$BINUTILS_TARBALL"
  sha256_check "$BINUTILS_TARBALL" "$BINUTILS_SHA256"
}

pkg_unpack() {
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"
  tar -C "$SRCDIR" --strip-components=1 -xJf "$BINUTILS_TARBALL"
}

pkg_build() {
  cd "$SRCDIR"
  rm -rf build
  mkdir -p build
  cd build

  conf_sysroot=""
  if [ -n "${TC_SYSROOT:-}" ]; then
    conf_sysroot="--with-sysroot=${TC_SYSROOT}"
  fi

  ../configure \
    --prefix="$PM_PREFIX" \
    --target="$TARGET" \
    $conf_sysroot \
    --disable-nls \
    --disable-werror \
    --enable-plugins \
    --enable-deterministic-archives

  make -j"$PM_JOBS"
}

pkg_install() {
  cd "$SRCDIR/build"
  make DESTDIR="$DESTDIR" install
  find "$DESTDIR" -type f -name "*.la" -delete 2>/dev/null || true
}
