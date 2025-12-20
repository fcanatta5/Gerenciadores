#!/bin/sh
set -eu

# Receita: xz (XZ Utils) 5.8.1
# Fonte (release oficial): https://github.com/tukaani-project/xz/releases/download/v5.8.1/xz-5.8.1.tar.xz
# SHA256 (tar.xz): 0b54f79df85912504de0b14aec7971e3f964491af1812d83447005807513cd9e
# Ref: Mozilla toolchains fetch + release notes. (CVE-2025-31115 fix em 5.8.1) 1

XZ_URL="https://github.com/tukaani-project/xz/releases/download/v${PKGVER}/xz-${PKGVER}.tar.xz"
XZ_TARBALL="${WORKDIR}/xz-${PKGVER}.tar.xz"
XZ_SHA256="0b54f79df85912504de0b14aec7971e3f964491af1812d83447005807513cd9e"

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

  # Reaproveita se já existe e checksum bate
  if [ -f "$XZ_TARBALL" ]; then
    verify_sha256 "$XZ_TARBALL" "$XZ_SHA256"
    return 0
  fi

  fetch_file "$XZ_URL" "$XZ_TARBALL"
  verify_sha256 "$XZ_TARBALL" "$XZ_SHA256"
}

pkg_unpack() {
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"
  tar -C "$SRCDIR" --strip-components=1 -xJf "$XZ_TARBALL"
}

pkg_build() {
  cd "$SRCDIR"

  # Mantém dependências mínimas:
  # --disable-nls evita depender de gettext/libintl
  # --disable-silent-rules deixa logs mais úteis
  #
  # Para musl, isso costuma ser o caminho mais simples e robusto.
  #
  # Se você quiser só liblzma (sem tools), dá para usar --disable-xz --disable-xzdec etc,
  # mas aqui é "completo" (lib + tools).
  #
  # Observação: CC/CFLAGS/LDFLAGS podem ser fornecidos pelo ambiente.
  ./configure \
    --prefix="$PM_PREFIX" \
    --disable-nls \
    --disable-silent-rules

  make -j"$PM_JOBS"
}

pkg_install() {
  cd "$SRCDIR"
  make DESTDIR="$DESTDIR" install

  # Opcional: remover arquivos desnecessários (ex.: .la), caso apareçam
  find "$DESTDIR" -type f -name "*.la" -delete 2>/dev/null || true
}
