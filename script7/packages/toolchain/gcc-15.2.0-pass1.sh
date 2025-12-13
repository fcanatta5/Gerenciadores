###############################################################################
# GCC 15.2.0 - PASS1 (tools only, sem headers/libc)
# Modelo: LFS/cross-toolchain (all-gcc + all-target-libgcc)
###############################################################################

PKG_CATEGORY="toolchain"
PKG_NAME="gcc"
PKG_VERSION="15.2.0"
PKG_RELEASE="1"
PKG_DESC="GNU GCC (pass1) para cross-toolchain (somente gcc + libgcc)"
PKG_LICENSE="GPL-3.0-with-GCC-exception"
PKG_SITE="https://gcc.gnu.org/"

# Pass1: normalmente depende do binutils-pass1 já instalado em TOOLSROOT
# Ajuste o spec conforme você nomeou o binutils pass1 no seu repositório:
PKG_DEPENDS=(
  "toolchain/binutils-2.45.1-pass1"
)

# Fontes
PKG_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://gcc.gnu.org/pub/gcc/releases/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://mirrorservice.org/sites/sourceware.org/pub/gcc/releases/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
)

# SHA256 conhecido do gcc-15.2.0.tar.xz  
PKG_SHA256="438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e"
# Opcional (alternativo ao SHA256):
# PKG_MD5="b861b092bf1af683c46a8aa2e689a6fd"  

###############################################################################
# Hooks
###############################################################################

pkg_prepare() {
  # Detecta diretório fonte
  SRC_DIR="$PKG_WORKDIR/gcc-${PKG_VERSION}"
  [[ -d "$SRC_DIR" ]] || {
    SRC_DIR="$(find "$PKG_WORKDIR" -maxdepth 1 -type d | tail -n +2 | head -n1)"
  }
  export SRC_DIR

  # Build dir fora da árvore (obrigatório/recomendado)
  BUILD_DIR="$PKG_BUILDDIR"
  mkdir -p "$BUILD_DIR"

  # Baixa prerequisitos (gmp/mpfr/mpc/isl) no SOURCE TREE
  # Isso evita depender de libs do host com versões inconsistentes.
  # Requer wget OU curl. O script do GCC usa normalmente wget; em alguns ambientes aceita curl.
  if [[ -x "$SRC_DIR/contrib/download_prerequisites" ]]; then
    if command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then
      ( cd "$SRC_DIR" && ./contrib/download_prerequisites )
    else
      echo "ERRO: Necessário wget ou curl para ./contrib/download_prerequisites" >&2
      return 1
    fi
  else
    echo "ERRO: contrib/download_prerequisites não encontrado no GCC tarball" >&2
    return 1
  fi
}

pkg_configure() {
  cd "$BUILD_DIR"

  # Pass1: evite “contaminação” do compilador do host por flags agressivas
  unset CFLAGS CXXFLAGS LDFLAGS

  # Garantir que binutils do target (pass1) será usado
  export AR_FOR_TARGET="${CTARGET}-ar"
  export AS_FOR_TARGET="${CTARGET}-as"
  export LD_FOR_TARGET="${CTARGET}-ld"
  export NM_FOR_TARGET="${CTARGET}-nm"
  export OBJDUMP_FOR_TARGET="${CTARGET}-objdump"
  export RANLIB_FOR_TARGET="${CTARGET}-ranlib"
  export READELF_FOR_TARGET="${CTARGET}-readelf"
  export STRIP_FOR_TARGET="${CTARGET}-strip"

  # Ferramentas de build (host)
  export CC_FOR_BUILD="${CC_FOR_BUILD:-gcc}"
  export CXX_FOR_BUILD="${CXX_FOR_BUILD:-g++}"

  # Configure: somente C, sem headers, sem libc, somente o essencial
  "$SRC_DIR/configure" \
    --prefix="$TOOLSROOT" \
    --target="$CTARGET" \
    --with-sysroot="$SYSROOT" \
    --with-newlib \
    --without-headers \
    --enable-languages=c \
    --disable-nls \
    --disable-multilib \
    --disable-shared \
    --disable-threads \
    --disable-libatomic \
    --disable-libgomp \
    --disable-libquadmath \
    --disable-libquadmath-support \
    --disable-libssp \
    --disable-libvtv \
    --disable-libstdcxx \
    --disable-libsanitizer \
    --disable-lto \
    --disable-plugin

  [[ -f config.status ]] || return 1
}

pkg_build() {
  cd "$BUILD_DIR"

  # Pass1: constrói somente o compilador e libgcc do target
  make $MAKEFLAGS all-gcc
  make $MAKEFLAGS all-target-libgcc
}

pkg_install() {
  cd "$BUILD_DIR"

  # Instala somente gcc + libgcc no TOOLSROOT
  make install-gcc
  make install-target-libgcc

  # Higiene: remove lixo não necessário no pass1
  rm -rf "$TOOLSROOT/share/info" "$TOOLSROOT/share/locale" || true
}

pkg_check() {
  local fail=0

  # 1) cross-gcc instalado
  if [[ ! -x "$TOOLSROOT/bin/${CTARGET}-gcc" ]]; then
    echo "FALTA: $TOOLSROOT/bin/${CTARGET}-gcc" >&2
    fail=1
  fi

  # 2) libgcc para o target
  # Caminho típico: $TOOLSROOT/lib/gcc/$CTARGET/$PKG_VERSION/...
  local libgcc_dir="$TOOLSROOT/lib/gcc/$CTARGET/$PKG_VERSION"
  if [[ ! -d "$libgcc_dir" ]]; then
    # fallback: localiza libgcc.a em toda árvore tools
    if ! find "$TOOLSROOT" -type f -name "libgcc.a" -path "*/gcc/$CTARGET/*" | grep -q .; then
      echo "FALTA: libgcc.a para $CTARGET em $TOOLSROOT" >&2
      fail=1
    fi
  else
    if [[ ! -f "$libgcc_dir/libgcc.a" ]] && ! find "$libgcc_dir" -maxdepth 2 -type f -name "libgcc.a" | grep -q .; then
      echo "FALTA: libgcc.a em $libgcc_dir" >&2
      fail=1
    fi
  fi

  # 3) Teste mínimo: compila objeto (não linka, então não exige libc/headers do sysroot)
  if [[ "$fail" -eq 0 ]]; then
    local tdir; tdir="$(mktemp -d)"
    printf "int x(void){return 0;}\n" >"$tdir/t.c"
    if ! "$TOOLSROOT/bin/${CTARGET}-gcc" -c "$tdir/t.c" -o "$tdir/t.o" >/dev/null 2>&1; then
      echo "ERRO: ${CTARGET}-gcc falhou ao compilar objeto" >&2
      fail=1
    fi
    rm -rf "$tdir"
  fi

  return "$fail"
}
