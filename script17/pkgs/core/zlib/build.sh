#!/bin/sh
set -eu

# zlib 1.3.1
# Fonte oficial: https://zlib.net/zlib-1.3.1.tar.xz
# SHA256: 38ef96b8dfe510d42707d9c781877914792541133e1870841463bfa73f883e32 1

ZLIB_URL_PRIMARY="https://zlib.net/zlib-${PKGVER}.tar.xz"
# fallback opcional (mesmo conteúdo/versão; útil se zlib.net estiver instável)
ZLIB_URL_FALLBACK="https://github.com/madler/zlib/releases/download/v${PKGVER}/zlib-${PKGVER}.tar.xz" 2
ZLIB_TARBALL="${WORKDIR}/zlib-${PKGVER}.tar.xz"
ZLIB_SHA256="38ef96b8dfe510d42707d9c781877914792541133e1870841463bfa73f883e32"

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

# Hooks opcionais (o seu pm.sh chama se existirem)
hook_pre_install() { :; }
hook_post_install() { :; }
hook_pre_remove() { :; }
hook_post_remove() { :; }

pkg_fetch() {
  mkdir -p "$WORKDIR"

  # Reaproveita tarball se já estiver presente e válido
  if [ -f "$ZLIB_TARBALL" ]; then
    sha256_check "$ZLIB_TARBALL" "$ZLIB_SHA256"
    return 0
  fi

  # Tenta fonte primária; se falhar, tenta fallback
  if fetch_file "$ZLIB_URL_PRIMARY" "$ZLIB_TARBALL"; then
    :
  else
    echo "WARN: falha ao baixar de $ZLIB_URL_PRIMARY; tentando fallback..." >&2
    fetch_file "$ZLIB_URL_FALLBACK" "$ZLIB_TARBALL"
  fi

  sha256_check "$ZLIB_TARBALL" "$ZLIB_SHA256"
}

pkg_unpack() {
  # sempre preparar árvore limpa
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"

  # zlib vem como zlib-<ver>/...
  tar -C "$SRCDIR" --strip-components=1 -xJf "$ZLIB_TARBALL"
}

pkg_build() {
  cd "$SRCDIR"

  # zlib usa configure próprio.
  # --prefix define o prefix final (ex.: /usr/local)
  #
  # Você pode exportar CC/CFLAGS/LDFLAGS fora do pm.sh; zlib respeita.
  ./configure --prefix="$PM_PREFIX"

  make -j"$PM_JOBS"
}

pkg_install() {
  cd "$SRCDIR"

  # Instala somente em DESTDIR (o pm.sh empacota e extrai em /)
  make DESTDIR="$DESTDIR" install

  # Remover artefatos que costumam ser dispensáveis
  find "$DESTDIR" -type f -name "*.la" -delete 2>/dev/null || true
}
