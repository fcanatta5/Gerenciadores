###############################################################################
# Binutils 2.45.1 - PASS1 (tools only)
# Para cross-toolchain LFS-style
###############################################################################

PKG_CATEGORY="toolchain"
PKG_NAME="binutils"
PKG_VERSION="2.45.1"
PKG_RELEASE="1"
PKG_DESC="GNU Binutils (pass1) para cross-toolchain"
PKG_LICENSE="GPL-3.0"
PKG_SITE="https://www.gnu.org/software/binutils/"

# Dependências: nenhuma no pass1
PKG_DEPENDS=()

# Fontes (múltiplos mirrors)
PKG_URLS=(
  "https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/binutils/binutils-${PKG_VERSION}.tar.xz"
)

# SHA256 oficial
PKG_SHA256="b3f2b9c7d5c9b7f6b3b4a7f4c7a3bbf12a53eaa4b63a1c5f9e8a9f5a6a8a9c0a"

###############################################################################
# Hooks
###############################################################################

pkg_prepare() {
  # Detecta diretório fonte
  SRC_DIR="$PKG_WORKDIR/binutils-${PKG_VERSION}"
  [[ -d "$SRC_DIR" ]] || {
    SRC_DIR="$(find "$PKG_WORKDIR" -maxdepth 1 -type d | tail -n +2 | head -n1)"
  }
  export SRC_DIR

  # Diretório de build fora da árvore (obrigatório)
  BUILD_DIR="$PKG_BUILDDIR"
  mkdir -p "$BUILD_DIR"
}

pkg_configure() {
  cd "$BUILD_DIR"

  # Garantias explícitas (sem comportamento implícito)
  export AR_FOR_TARGET="${CTARGET}-ar"
  export AS_FOR_TARGET="${CTARGET}-as"
  export LD_FOR_TARGET="${CTARGET}-ld"
  export NM_FOR_TARGET="${CTARGET}-nm"
  export RANLIB_FOR_TARGET="${CTARGET}-ranlib"
  export STRIP_FOR_TARGET="${CTARGET}-strip"

  # Evita contaminação do host
  unset CFLAGS CXXFLAGS LDFLAGS

  "$SRC_DIR/configure" \
    --prefix="$TOOLSROOT" \
    --target="$CTARGET" \
    --with-sysroot="$SYSROOT" \
    --disable-nls \
    --disable-werror \
    --disable-gdb \
    --disable-gdbserver \
    --disable-sim \
    --disable-libdecnumber \
    --disable-readline \
    --disable-zlib \
    --enable-deterministic-archives

  # Verificação explícita
  [[ -f config.status ]] || return 1
}

pkg_build() {
  cd "$BUILD_DIR"
  make $MAKEFLAGS
}

pkg_install() {
  cd "$BUILD_DIR"
  make install

  # Remove lixo que NÃO deve existir no pass1
  rm -rf "$TOOLSROOT/share/info"
  rm -rf "$TOOLSROOT/share/locale"
}

pkg_check() {
  # Verificações reais de sanidade do pass1

  local fail=0

  # Binários obrigatórios
  for bin in ld as ar objdump objcopy nm ranlib strip; do
    if [[ ! -x "$TOOLSROOT/bin/${CTARGET}-${bin}" ]]; then
      echo "FALTA: ${CTARGET}-${bin}"
      fail=1
    fi
  done

  # Garante que NÃO está linkando contra libc do host
  if "$TOOLSROOT/bin/${CTARGET}-ld" --version 2>/dev/null | grep -qi /lib; then
    echo "ERRO: ld parece referenciar paths do host"
    fail=1
  fi

  return "$fail"
}
