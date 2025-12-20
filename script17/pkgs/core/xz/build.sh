#!/bin/sh
set -eu

# xz (XZ Utils) 5.8.1
# Fonte (release oficial): https://github.com/tukaani-project/xz/releases/download/v5.8.1/xz-5.8.1.tar.xz
# SHA256 (tar.xz): 0b54f79df85912504de0b14aec7971e3f964491af1812d83447005807513cd9e 1

XZ_URL_PRIMARY="https://github.com/tukaani-project/xz/releases/download/v${PKGVER}/xz-${PKGVER}.tar.xz"
# Fallback opcional: "old releases" (útil se GitHub estiver fora)
# Observação: o SHA256 continua sendo o gate de integridade.
XZ_URL_FALLBACK="https://tukaani.org/xz/xz-${PKGVER}.tar.xz" 2

XZ_TARBALL="${WORKDIR}/xz-${PKGVER}.tar.xz"
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

# Hooks opcionais (o seu pm.sh chama se existirem)
hook_pre_install() { :; }
hook_post_install() { :; }
hook_pre_remove() { :; }
hook_post_remove() { :; }

pkg_fetch() {
  mkdir -p "$WORKDIR"

  # Reaproveita se já existe e checksum bate
  if [ -f "$XZ_TARBALL" ]; then
    sha256_check "$XZ_TARBALL" "$XZ_SHA256"
    return 0
  fi

  # Primário -> fallback
  if fetch_file "$XZ_URL_PRIMARY" "$XZ_TARBALL"; then
    :
  else
    echo "WARN: falha ao baixar de $XZ_URL_PRIMARY; tentando fallback..." >&2
    fetch_file "$XZ_URL_FALLBACK" "$XZ_TARBALL"
  fi

  sha256_check "$XZ_TARBALL" "$XZ_SHA256"
}

pkg_unpack() {
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"
  tar -C "$SRCDIR" --strip-components=1 -xJf "$XZ_TARBALL"
}

pkg_build() {
  cd "$SRCDIR"

  # Mantém dependências mínimas:
  # --disable-nls evita gettext/libintl
  # --disable-silent-rules melhora logs
  #
  # CC/CFLAGS/LDFLAGS podem ser fornecidos pelo ambiente externo ao pm.sh.
  ./configure \
    --prefix="$PM_PREFIX" \
    --disable-nls \
    --disable-silent-rules

  make -j"$PM_JOBS"
}

pkg_install() {
  cd "$SRCDIR"

  # Instala em DESTDIR (nunca em / diretamente)
  make DESTDIR="$DESTDIR" install

  # Remover .la (se aparecer)
  find "$DESTDIR" -type f -name "*.la" -delete 2>/dev/null || true
}
