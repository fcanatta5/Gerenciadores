###############################################################################
# glibc 2.42 (BASE) - libc do sistema no SYSROOT/rootfs do target
# Compatível com adm: PKG_WORKDIR/PKG_BUILDDIR/PKG_STAGEDIR, CTARGET, CHOST,
# SYSROOT, TOOLSROOT, MAKEFLAGS.
#
# Observações:
# - Cross-build: não executa test-suite no host.
# - Requer linux-headers em $SYSROOT/usr/include.
###############################################################################

PKG_CATEGORY="base"
PKG_NAME="glibc"
PKG_VERSION="2.42"
PKG_RELEASE="1"
PKG_DESC="GNU C Library ${PKG_VERSION} (base/system libc) instalada no sysroot"
PKG_LICENSE="LGPL-2.1-or-later"
PKG_SITE="https://www.gnu.org/software/libc/"

# Dependências típicas para base:
# - linux headers no sysroot
# - toolchain pass1 para compilar
# - binutils base recomendado (para ferramentas do target no sysroot)
# Ajuste nomes conforme seu repo:
PKG_DEPENDS=(
  "toolchain/binutils-2.45.1-pass1"
  "toolchain/gcc-15.2.0-pass1"
  "toolchain/linux-headers-6.17.9"
  "base/binutils-2.45.1"
)

PKG_URLS=(
  "https://ftp.gnu.org/gnu/glibc/glibc-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/glibc/glibc-${PKG_VERSION}.tar.xz"
)

# Use md5 (publicado em listas/documentação) ou sha256 se você preferir.
PKG_MD5="23c6f5a27932b435cae94e087cb8b1f5"

###############################################################################
# Helpers locais
###############################################################################
_need_kernel_headers() {
  [[ -d "$SYSROOT/usr/include" ]] || return 1
  [[ -f "$SYSROOT/usr/include/linux/types.h" || -f "$SYSROOT/usr/include/linux/version.h" ]] || return 1
  return 0
}

###############################################################################
# Hooks
###############################################################################

pkg_prepare() {
  SRC_DIR="$PKG_WORKDIR/glibc-${PKG_VERSION}"
  [[ -d "$SRC_DIR" ]] || {
    SRC_DIR="$(find "$PKG_WORKDIR" -maxdepth 1 -type d | tail -n +2 | head -n1)"
  }
  export SRC_DIR

  BUILD_DIR="$PKG_BUILDDIR"
  mkdir -p "$BUILD_DIR"

  if ! _need_kernel_headers; then
    echo "ERRO: linux-headers não encontrados em $SYSROOT/usr/include" >&2
    echo "      Instale toolchain/linux-headers antes do glibc." >&2
    return 1
  fi

  if [[ ! -x "$TOOLSROOT/bin/${CTARGET}-gcc" ]]; then
    echo "ERRO: cross-gcc não encontrado: $TOOLSROOT/bin/${CTARGET}-gcc" >&2
    return 1
  fi
}

pkg_configure() {
  cd "$BUILD_DIR"

  # glibc é sensível a flags; evite herdar do ambiente
  unset CFLAGS CXXFLAGS LDFLAGS

  # Ferramentas de build (host)
  export BUILD_CC="${BUILD_CC:-gcc}"
  export BUILD_CXX="${BUILD_CXX:-g++}"

  # Ferramentas do target (usando tools)
  export CC="$TOOLSROOT/bin/${CTARGET}-gcc"
  export CXX="$TOOLSROOT/bin/${CTARGET}-g++"
  export AR="$TOOLSROOT/bin/${CTARGET}-ar"
  export RANLIB="$TOOLSROOT/bin/${CTARGET}-ranlib"

  # Sysroot nos includes do compilador
  export CPPFLAGS="${CPPFLAGS:-} --sysroot=$SYSROOT"

  # Cache de respostas para cross (evita testes que tentariam rodar no host)
  cat >config.cache <<'EOF'
libc_cv_forced_unwind=yes
libc_cv_c_cleanup=yes
libc_cv_ssp=no
EOF

  # BASE: prefix /usr dentro do rootfs
  "$SRC_DIR/configure" \
    --prefix=/usr \
    --host="$CTARGET" \
    --build="$CHOST" \
    --with-headers="$SYSROOT/usr/include" \
    --cache-file="$BUILD_DIR/config.cache" \
    --disable-werror \
    --enable-kernel=4.19 \
    --enable-stack-protector=none

  [[ -f config.status ]] || return 1
}

pkg_build() {
  cd "$BUILD_DIR"
  make $MAKEFLAGS
}

pkg_install() {
  cd "$BUILD_DIR"

  # Instala para o stage (adm sincroniza para o SYSROOT)
  make DESTDIR="$PKG_STAGEDIR" install

  # Garante diretórios essenciais
  mkdir -p "$PKG_STAGEDIR/lib" "$PKG_STAGEDIR/usr/lib"

  # Higiene (opcional)
  rm -rf "$PKG_STAGEDIR/usr/share/info" 2>/dev/null || true
}

pkg_check() {
  local fail=0

  # Headers de libc
  if [[ ! -f "$PKG_STAGEDIR/usr/include/gnu/libc-version.h" ]]; then
    echo "FALTA: /usr/include/gnu/libc-version.h" >&2
    fail=1
  fi

  # libc runtime
  if ! find "$PKG_STAGEDIR" -type f -name "libc.so.6" | grep -q .; then
    echo "FALTA: libc.so.6 (glibc runtime)" >&2
    fail=1
  fi

  # loader (depende de arch; checa de forma robusta)
  if ! find "$PKG_STAGEDIR" -type f -name "ld-linux*.so.*" | grep -q .; then
    echo "WARN: loader ld-linux*.so.* não encontrado (nome varia por arquitetura)" >&2
  fi

  # ldd
  if [[ ! -f "$PKG_STAGEDIR/usr/bin/ldd" ]]; then
    echo "WARN: /usr/bin/ldd não encontrado (pode variar por config/instalação)" >&2
  fi

  return "$fail"
}
