#!/bin/sh
set -eu

# Receita: zlib 1.3.1 (tar.xz) - musl-friendly, makefile clássico
# Fonte oficial: https://zlib.net/zlib-1.3.1.tar.xz
# SHA256 (tar.xz): 38ef96b8dfe510d42707d9c781877914792541133e1870841463bfa73f883e32

ZLIB_URL="https://zlib.net/zlib-${PKGVER}.tar.xz"
ZLIB_TARBALL="${WORKDIR}/zlib-${PKGVER}.tar.xz"
ZLIB_SHA256="38ef96b8dfe510d42707d9c781877914792541133e1870841463bfa73f883e32"

# Hooks opcionais (se você não quiser, pode remover)
hook_pre_install() { :; }
hook_post_install() { :; }
hook_pre_remove() { :; }
hook_post_remove() { :; }

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

verify_sha256() {
  file=$1 expected=$2
  if have sha256sum; then
    got=$(sha256sum "$file" | awk '{print $1}')
  else
    echo "ERRO: sha256sum não encontrado (BusyBox normalmente fornece)." >&2
    exit 1
  fi
  if [ "$got" != "$expected" ]; then
    echo "ERRO: sha256 inválido para $(basename "$file")" >&2
    echo "Esperado: $expected" >&2
    echo "Obtido:   $got" >&2
    exit 1
  fi
}

pkg_fetch() {
  mkdir -p "$WORKDIR"
  # Se já existe e checksum bate, reaproveita (economiza rede)
  if [ -f "$ZLIB_TARBALL" ]; then
    if verify_sha256 "$ZLIB_TARBALL" "$ZLIB_SHA256"; then
      return 0
    fi
    rm -f "$ZLIB_TARBALL"
  fi

  fetch_file "$ZLIB_URL" "$ZLIB_TARBALL"
  verify_sha256 "$ZLIB_TARBALL" "$ZLIB_SHA256"
}

pkg_unpack() {
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"
  # strip-components=1 para não ficar zlib-1.3.1/ dentro do SRCDIR
  tar -C "$SRCDIR" --strip-components=1 -xJf "$ZLIB_TARBALL"
}

pkg_build() {
  cd "$SRCDIR"

  # zlib usa ./configure próprio; define prefix e opções de shared.
  # Para musl normalmente é tranquilo. Você pode adicionar CFLAGS/LDFLAGS via ambiente.
  #
  # --prefix deve ser o prefix final dentro do sistema (PM_PREFIX)
  ./configure --prefix="$PM_PREFIX"

  # build
  make -j"$PM_JOBS"
}

pkg_install() {
  cd "$SRCDIR"

  # Instala em DESTDIR (nunca em / diretamente)
  make DESTDIR="$DESTDIR" install

  # Opcional: também instalar shared se o build gerar e você quiser garantir:
  # (zlib normalmente instala libz.so e libz.a via 'install' dependendo do sistema)
  # make DESTDIR="$DESTDIR" install-shared || true
}
