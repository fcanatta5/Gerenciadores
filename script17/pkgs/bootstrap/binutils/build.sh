#!/bin/sh
set -eu

# Binutils 2.45.1
# Download oficial (GNU FTP): 1
# SHA256 do .tar.bz2 é publicado por fórmula do Homebrew: 2
BINUTILS_URL="https://ftp.gnu.org/gnu/binutils/binutils-${PKGVER}.tar.bz2"
TARBALL="${WORKDIR}/binutils-${PKGVER}.tar.bz2"
SHA256="860daddec9085cb4011279136fc8ad29eb533e9446d7524af7f517dd18f00224"  # 3

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
  if [ -f "$TARBALL" ]; then
    sha256_check "$TARBALL" "$SHA256"
    return 0
  fi
  fetch_file "$BINUTILS_URL" "$TARBALL"
  sha256_check "$TARBALL" "$SHA256"
}

pkg_unpack() {
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"

  # Extração robusta de .tar.bz2:
  # 1) tenta tar -xjf
  # 2) fallback: bzcat/bunzip2 | tar -xf -
  if tar -C "$SRCDIR" --strip-components=1 -xjf "$TARBALL" >/dev/null 2>&1; then
    :
  else
    if have bzcat; then
      bzcat "$TARBALL" | tar -C "$SRCDIR" --strip-components=1 -xf -
    elif have bunzip2; then
      bunzip2 -c "$TARBALL" | tar -C "$SRCDIR" --strip-components=1 -xf -
    else
      echo "ERRO: não foi possível extrair .tar.bz2 (precisa tar com -j ou bzcat/bunzip2)." >&2
      exit 1
    fi
  fi
}

pkg_build() {
  cd "$SRCDIR"

  # Build out-of-tree (mais limpo e previsível)
  rm -rf build
  mkdir -p build
  cd build

  # Para o seu pm-bootstrap.sh:
  # - PM_PREFIX aponta para TC_PREFIX (prefixo do toolchain)
  # - TC_SYSROOT aponta para sysroot do target
  #
  # Binutils deve instalar em TC_PREFIX, mas conhecer o sysroot para linkagem.
  # --with-sysroot ajuda ld/as e ferramentas a resolverem paths do target.
  #
  # Flags:
  # --disable-nls          reduz dependências
  # --disable-werror       evita falhas por warnings
  # --disable-multilib     simplifica
  # --enable-deterministic-archives reprodutibilidade
  # --disable-gdb          não construir gdb aqui (você quer só binutils)
  #
  ../configure \
    --prefix="$PM_PREFIX" \
    --target="$TARGET" \
    --with-sysroot="$TC_SYSROOT" \
    --disable-nls \
    --disable-werror \
    --disable-multilib \
    --enable-deterministic-archives \
    --disable-gdb \
    --disable-gprofng

  make -j"$PM_JOBS"
}

pkg_install() {
  cd "$SRCDIR/build"
  make DESTDIR="$DESTDIR" install

  # Sanity checks (não falham o build, mas avisam via stdout do pm)
  if [ ! -x "$DESTDIR$PM_PREFIX/bin/${TARGET}-ld" ] && [ ! -x "$DESTDIR$PM_PREFIX/bin/${TARGET}-as" ]; then
    echo "AVISO: binutils parece não ter instalado ${TARGET}-ld/as em $PM_PREFIX/bin" >&2
  fi
}
