###############################################################################
# GCC 15.2.0 (BASE) - "native compiler" para o TARGET, instalado no SYSROOT
# (build canadian/cross): build=CHOST, host=CTARGET, target=CTARGET
#
# Compatível com adm: PKG_WORKDIR/PKG_BUILDDIR/PKG_STAGEDIR, CTARGET, CHOST,
# SYSROOT, TOOLSROOT, MAKEFLAGS.
###############################################################################

PKG_CATEGORY="base"
PKG_NAME="gcc"
PKG_VERSION="15.2.0"
PKG_RELEASE="1"
PKG_DESC="GNU GCC ${PKG_VERSION} (base/native no target) instalado no sysroot"
PKG_LICENSE="GPL-3.0-with-GCC-exception"
PKG_SITE="https://gcc.gnu.org/"

# Dependências típicas (ajuste se seus nomes diferirem):
# - binutils pass1 + gcc pass1: garantem toolchain inicial em tools/
# - linux-headers + libc (glibc/musl) no sysroot
# - binutils base: utilitários nativos no sysroot (recomendado)
PKG_DEPENDS=(
  "toolchain/binutils-2.45.1-pass1"
  "toolchain/gcc-15.2.0-pass1"
  "toolchain/linux-headers-6.17.9"
  "base/binutils-2.45.1"
)

# Fonte do GCC
PKG_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://gcc.gnu.org/pub/gcc/releases/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
)

# Use SHA256 OU MD5 (um ou outro). Recomendado SHA256.
PKG_SHA256="438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e"

###############################################################################
# Helpers locais
###############################################################################
_need_kernel_headers() {
  [[ -d "$SYSROOT/usr/include" ]] || return 1
  [[ -f "$SYSROOT/usr/include/linux/types.h" || -f "$SYSROOT/usr/include/linux/version.h" ]] || return 1
  return 0
}

_need_crt_objects() {
  # CRTs típicos: crt1.o/crti.o/crtn.o em /usr/lib ou /lib (varia por libc/arch)
  find "$SYSROOT" -maxdepth 5 -type f \( -name "crt1.o" -o -name "Scrt1.o" -o -name "crti.o" -o -name "crtn.o" \) | grep -q .
}

_need_libc_present() {
  # glibc: libc.so.6 ; musl: libc.musl-*.so.1 ; também pode existir libc.so
  find "$SYSROOT" -maxdepth 5 -type f \( -name "libc.so.6" -o -name "libc.musl-*.so.1" -o -name "libc.so" \) | grep -q .
}

###############################################################################
# Hooks
###############################################################################

pkg_prepare() {
  # Source dir
  SRC_DIR="$PKG_WORKDIR/gcc-${PKG_VERSION}"
  [[ -d "$SRC_DIR" ]] || {
    SRC_DIR="$(find "$PKG_WORKDIR" -maxdepth 1 -type d | tail -n +2 | head -n1)"
  }
  export SRC_DIR

  # Build dir out-of-tree
  BUILD_DIR="$PKG_BUILDDIR"
  mkdir -p "$BUILD_DIR"

  # Sanidades do sysroot
  if ! _need_kernel_headers; then
    echo "ERRO: linux-headers não encontrados em $SYSROOT/usr/include" >&2
    echo "      Instale toolchain/linux-headers antes." >&2
    return 1
  fi

  if ! _need_libc_present; then
    echo "ERRO: libc não encontrada no SYSROOT ($SYSROOT)." >&2
    echo "      Instale glibc/musl no sysroot antes do GCC base." >&2
    return 1
  fi

  if ! _need_crt_objects; then
    echo "ERRO: objetos CRT (crt1.o/crti.o/crtn.o) não encontrados no SYSROOT ($SYSROOT)." >&2
    echo "      Sua libc não está completa no sysroot." >&2
    return 1
  fi

  # Precisamos do cross-gcc (que roda no host) para compilar binários do target
  if [[ ! -x "$TOOLSROOT/bin/${CTARGET}-gcc" ]]; then
    echo "ERRO: cross-gcc não encontrado: $TOOLSROOT/bin/${CTARGET}-gcc" >&2
    return 1
  fi

  # Baixa prereqs (gmp/mpfr/mpc/isl) dentro do tree do GCC para consistência
  if [[ -x "$SRC_DIR/contrib/download_prerequisites" ]]; then
    if command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then
      ( cd "$SRC_DIR" && ./contrib/download_prerequisites )
    else
      echo "ERRO: Necessário wget ou curl para ./contrib/download_prerequisites" >&2
      return 1
    fi
  else
    echo "ERRO: contrib/download_prerequisites não encontrado no tarball do GCC" >&2
    return 1
  fi
}

pkg_configure() {
  cd "$BUILD_DIR"

  # Evita contaminação do host (GCC base é sensível)
  unset CFLAGS CXXFLAGS LDFLAGS

  # Compiladores de build (rodam na máquina atual)
  export CC_FOR_BUILD="${CC_FOR_BUILD:-gcc}"
  export CXX_FOR_BUILD="${CXX_FOR_BUILD:-g++}"

  # Compiladores/asm/link do "host" do GCC (aqui host==target):
  # Esses compilam binários que rodam no TARGET, mas serão *construídos* no BUILD.
  export CC="$TOOLSROOT/bin/${CTARGET}-gcc"
  export CXX="$TOOLSROOT/bin/${CTARGET}-g++"  # pode não existir (pass1); mas aqui é base -> precisa existir
  export AR="$TOOLSROOT/bin/${CTARGET}-ar"
  export RANLIB="$TOOLSROOT/bin/${CTARGET}-ranlib"
  export STRIP="$TOOLSROOT/bin/${CTARGET}-strip"

  # Binutils do target (ainda usando tools, mas apontando sysroot)
  export AS_FOR_TARGET="$TOOLSROOT/bin/${CTARGET}-as"
  export LD_FOR_TARGET="$TOOLSROOT/bin/${CTARGET}-ld"
  export NM_FOR_TARGET="$TOOLSROOT/bin/${CTARGET}-nm"
  export OBJDUMP_FOR_TARGET="$TOOLSROOT/bin/${CTARGET}-objdump"
  export RANLIB_FOR_TARGET="$TOOLSROOT/bin/${CTARGET}-ranlib"
  export READELF_FOR_TARGET="$TOOLSROOT/bin/${CTARGET}-readelf"
  export STRIP_FOR_TARGET="$TOOLSROOT/bin/${CTARGET}-strip"

  # Força sysroot para headers/libs do target
  export CPPFLAGS="--sysroot=$SYSROOT"
  export CFLAGS_FOR_TARGET="--sysroot=$SYSROOT"
  export CXXFLAGS_FOR_TARGET="--sysroot=$SYSROOT"
  export LDFLAGS_FOR_TARGET="--sysroot=$SYSROOT"

  # Use o dynamic linker e include dirs do sysroot (especialmente importante em musl)
  # Mantemos defaults e evitamos multilib.
  #
  # Observação: --with-native-system-header-dir é importante para sysroot:
  # faz o GCC procurar /usr/include dentro do sysroot como headers “nativos”.
  #
  "$SRC_DIR/configure" \
    --prefix=/usr \
    --build="$CHOST" \
    --host="$CTARGET" \
    --target="$CTARGET" \
    --with-sysroot="$SYSROOT" \
    --with-native-system-header-dir=/usr/include \
    --enable-languages=c,c++ \
    --disable-multilib \
    --disable-nls \
    --enable-shared \
    --enable-threads=posix \
    --enable-__cxa_atexit \
    --enable-default-pie \
    --enable-default-ssp \
    --disable-libsanitizer \
    --disable-werror

  [[ -f config.status ]] || return 1
}

pkg_build() {
  cd "$BUILD_DIR"

  # Build completo (gcc + libs) para host==target
  make $MAKEFLAGS
}

pkg_install() {
  cd "$BUILD_DIR"

  # Instala no STAGE; o adm fará rsync stage -> SYSROOT
  make DESTDIR="$PKG_STAGEDIR" install

  # Higiene opcional (docs/locale)
  rm -rf "$PKG_STAGEDIR/usr/share/info" "$PKG_STAGEDIR/usr/share/locale" 2>/dev/null || true

  # Fixups comuns: garantir symlinks cc/c++
  if [[ -x "$PKG_STAGEDIR/usr/bin/gcc" && ! -e "$PKG_STAGEDIR/usr/bin/cc" ]]; then
    ln -s gcc "$PKG_STAGEDIR/usr/bin/cc"
  fi
  if [[ -x "$PKG_STAGEDIR/usr/bin/g++" && ! -e "$PKG_STAGEDIR/usr/bin/c++" ]]; then
    ln -s g++ "$PKG_STAGEDIR/usr/bin/c++"
  fi
}

pkg_check() {
  local fail=0

  # Não podemos executar o gcc (binário do target) no host.
  # Então validamos presença/estrutura.

  # Binários principais
  for b in gcc g++ cpp; do
    if [[ ! -x "$PKG_STAGEDIR/usr/bin/$b" ]]; then
      echo "FALTA: /usr/bin/$b no stage" >&2
      fail=1
    fi
  done

  # cc1/cc1plus (componentes internos)
  if ! find "$PKG_STAGEDIR/usr/libexec/gcc/$CTARGET/$PKG_VERSION" -maxdepth 1 -type f \( -name "cc1" -o -name "cc1plus" \) | grep -q .; then
    echo "FALTA: cc1/cc1plus em /usr/libexec/gcc/$CTARGET/$PKG_VERSION" >&2
    fail=1
  fi

  # libgcc + libstdc++ (ao menos shared ou static)
  if ! find "$PKG_STAGEDIR" -type f \( -name "libgcc_s.so*" -o -name "libgcc.a" \) | grep -q .; then
    echo "FALTA: libgcc (libgcc_s.so* ou libgcc.a) no stage" >&2
    fail=1
  fi
  if ! find "$PKG_STAGEDIR" -type f \( -name "libstdc++.so*" -o -name "libstdc++.a" \) | grep -q .; then
    echo "FALTA: libstdc++ (libstdc++.so* ou libstdc++.a) no stage" >&2
    fail=1
  fi

  # Headers C++ (versão)
  if [[ ! -d "$PKG_STAGEDIR/usr/include/c++/${PKG_VERSION}" ]]; then
    echo "FALTA: headers C++ em /usr/include/c++/${PKG_VERSION}" >&2
    fail=1
  fi

  return "$fail"
}
