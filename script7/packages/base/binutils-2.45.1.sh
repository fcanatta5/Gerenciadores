###############################################################################
# Binutils 2.45.1 (BASE) - binutils "native" para o TARGET, instalado no SYSROOT
# Compatível com adm: PKG_WORKDIR/PKG_BUILDDIR/PKG_STAGEDIR, CTARGET, CHOST,
# SYSROOT, TOOLSROOT, MAKEFLAGS.
###############################################################################

PKG_CATEGORY="base"
PKG_NAME="binutils"
PKG_VERSION="2.45.1"
PKG_RELEASE="1"
PKG_DESC="GNU Binutils ${PKG_VERSION} (native tools do target) para rootfs/sysroot"
PKG_LICENSE="GPL-3.0-or-later"
PKG_SITE="https://www.gnu.org/software/binutils/"

# Dependências mínimas típicas:
# - binutils pass1 (para ter assembler/ld no tools)
# - um cross-gcc (pass1 ou final) que consiga gerar binários do target
# Ajuste nomes se necessário:
PKG_DEPENDS=(
  "toolchain/binutils-2.45.1-pass1"
  "toolchain/gcc-15.2.0-pass1"
)

# Fontes (use .tar.bz2 com hash conhecido publicamente)
PKG_URLS=(
  "https://ftpmirror.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.bz2"
  "https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.bz2"
)

# SHA256 do binutils-2.45.1.tar.bz2 1
PKG_SHA256="860daddec9085cb4011279136fc8ad29eb533e9446d7524af7f517dd18f00224"

###############################################################################
# Hooks
###############################################################################

pkg_prepare() {
  SRC_DIR="$PKG_WORKDIR/binutils-${PKG_VERSION}"
  [[ -d "$SRC_DIR" ]] || {
    SRC_DIR="$(find "$PKG_WORKDIR" -maxdepth 1 -type d | tail -n +2 | head -n1)"
  }
  export SRC_DIR

  BUILD_DIR="$PKG_BUILDDIR"
  mkdir -p "$BUILD_DIR"

  # Sanidade: cross-gcc precisa existir
  if [[ ! -x "$TOOLSROOT/bin/${CTARGET}-gcc" ]]; then
    echo "ERRO: cross-gcc não encontrado: $TOOLSROOT/bin/${CTARGET}-gcc" >&2
    return 1
  fi
}

pkg_configure() {
  cd "$BUILD_DIR"

  # Evita contaminação por flags globais (binutils pode ser sensível)
  unset CFLAGS CXXFLAGS LDFLAGS

  # Compilação para rodar no TARGET (host=target), construída no BUILD (host real)
  export CC="$TOOLSROOT/bin/${CTARGET}-gcc"
  export CXX="$TOOLSROOT/bin/${CTARGET}-g++"   # pode não existir; binutils é majoritariamente C
  export AR="$TOOLSROOT/bin/${CTARGET}-ar"
  export RANLIB="$TOOLSROOT/bin/${CTARGET}-ranlib"

  # Ferramentas para BUILD (executam na máquina atual)
  export BUILD_CC="${BUILD_CC:-gcc}"

  # Configure para binutils "native" do target:
  # - prefix=/usr (dentro do sysroot via DESTDIR)
  # - sem --target (evita tools prefixadas ${CTARGET}-as etc; queremos "as/ld/ar" nativos do target)
  "$SRC_DIR/configure" \
    --prefix=/usr \
    --host="$CTARGET" \
    --build="$CHOST" \
    --disable-nls \
    --disable-werror \
    --enable-plugins \
    --enable-deterministic-archives \
    --disable-gdb \
    --disable-gdbserver \
    --disable-sim \
    --disable-libdecnumber \
    --disable-readline \
    --disable-zlib

  [[ -f config.status ]] || return 1
}

pkg_build() {
  cd "$BUILD_DIR"
  make $MAKEFLAGS
}

pkg_install() {
  cd "$BUILD_DIR"

  # Instala no STAGE (adm fará rsync stage -> SYSROOT)
  make DESTDIR="$PKG_STAGEDIR" install

  # Higiene opcional
  rm -rf "$PKG_STAGEDIR/usr/share/info" "$PKG_STAGEDIR/usr/share/locale" 2>/dev/null || true
}

pkg_check() {
  local fail=0

  # Binários esperados no rootfs (nativos do target)
  for b in ar as ld nm objcopy objdump ranlib readelf size strings strip; do
    if [[ ! -x "$PKG_STAGEDIR/usr/bin/$b" ]]; then
      echo "FALTA: /usr/bin/$b no stage" >&2
      fail=1
    fi
  done

  # Libs do binutils (bfd/opcodes) geralmente ficam em /usr/lib
  if ! find "$PKG_STAGEDIR/usr/lib" -maxdepth 2 -type f \( -name "libbfd*.a" -o -name "libopcodes*.a" -o -name "libctf*.a" \) | grep -q .; then
    echo "WARN: não encontrei libs libbfd/libopcodes/libctf em /usr/lib (pode variar por config/target)" >&2
  fi

  return "$fail"
}
