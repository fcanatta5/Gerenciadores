###############################################################################
# libstdc++ (libstdc++-v3) from GCC 15.2.0
# Instala no SYSROOT via stage (DESTDIR), compatível com adm.
###############################################################################

PKG_CATEGORY="toolchain"
PKG_NAME="libstdcxx"
PKG_VERSION="15.2.0"
PKG_RELEASE="1"
PKG_DESC="libstdc++-v3 (C++ standard library) do GCC ${PKG_VERSION} para sysroot do target"
PKG_LICENSE="GPL-3.0-with-GCC-exception"
PKG_SITE="https://gcc.gnu.org/"

# Dependências mínimas para link/headers no sysroot:
# Ajuste os nomes conforme seu repositório.
PKG_DEPENDS=(
  "toolchain/linux-headers-6.17.9"
  "toolchain/glibc-2.42"
)

# Fonte do GCC (vamos usar apenas libstdc++-v3)
PKG_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://gcc.gnu.org/pub/gcc/releases/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
)

# Use SHA256 OU MD5 (um ou outro). Preencha com o valor correto do seu espelho.
# Recomendo SHA256.
PKG_SHA256="438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e"
# PKG_MD5="..."

###############################################################################
# Helpers locais
###############################################################################
_need_sysroot_headers() {
  [[ -d "$SYSROOT/usr/include" ]] || return 1
  [[ -f "$SYSROOT/usr/include/linux/types.h" || -f "$SYSROOT/usr/include/linux/version.h" ]] || return 1
  return 0
}

_need_glibc_present() {
  # libc.so.6 em sysroot costuma estar em /lib, /lib64, /usr/lib, /usr/lib64
  find "$SYSROOT" -maxdepth 4 -type f -name "libc.so.6" | grep -q .
}

###############################################################################
# Hooks
###############################################################################

pkg_prepare() {
  SRC_DIR="$PKG_WORKDIR/gcc-${PKG_VERSION}"
  [[ -d "$SRC_DIR" ]] || {
    SRC_DIR="$(find "$PKG_WORKDIR" -maxdepth 1 -type d | tail -n +2 | head -n1)"
  }
  export SRC_DIR

  BUILD_DIR="$PKG_BUILDDIR"
  mkdir -p "$BUILD_DIR"

  # Sanidades objetivas
  if ! _need_sysroot_headers; then
    echo "ERRO: linux headers não encontrados em $SYSROOT/usr/include" >&2
    echo "      Instale toolchain/linux-headers antes." >&2
    return 1
  fi

  if ! _need_glibc_present; then
    echo "ERRO: glibc (libc.so.6) não encontrada no SYSROOT ($SYSROOT)." >&2
    echo "      Instale toolchain/glibc antes de libstdc++." >&2
    return 1
  fi

  if [[ ! -x "$TOOLSROOT/bin/${CTARGET}-g++" ]]; then
    echo "ERRO: cross g++ não encontrado: $TOOLSROOT/bin/${CTARGET}-g++" >&2
    echo "      Você precisa de um GCC com C++ habilitado (ex.: gcc-final com --enable-languages=c,c++)." >&2
    return 1
  fi
}

pkg_configure() {
  cd "$BUILD_DIR"

  # Evita contaminação do host
  unset CFLAGS CXXFLAGS LDFLAGS

  # Compiladores do target (devem usar sysroot para link/headers)
  export CC="$TOOLSROOT/bin/${CTARGET}-gcc"
  export CXX="$TOOLSROOT/bin/${CTARGET}-g++"
  export AR="$TOOLSROOT/bin/${CTARGET}-ar"
  export RANLIB="$TOOLSROOT/bin/${CTARGET}-ranlib"
  export STRIP="$TOOLSROOT/bin/${CTARGET}-strip"

  # Assegura sysroot no preprocess/link
  export CPPFLAGS="${CPPFLAGS:-} --sysroot=$SYSROOT"
  export CXXFLAGS_FOR_TARGET="${CXXFLAGS_FOR_TARGET:-} --sysroot=$SYSROOT"
  export CFLAGS_FOR_TARGET="${CFLAGS_FOR_TARGET:-} --sysroot=$SYSROOT"
  export LDFLAGS_FOR_TARGET="${LDFLAGS_FOR_TARGET:-} --sysroot=$SYSROOT"

  # Build apenas do libstdc++-v3
  # Prefix /usr (dentro do sysroot via DESTDIR)
  # gxx include dir fixo (evita caminhos estranhos)
  local gxx_inc="/usr/include/c++/${PKG_VERSION}"

  "$SRC_DIR/libstdc++-v3/configure" \
    --host="$CTARGET" \
    --build="$CHOST" \
    --prefix=/usr \
    --with-sysroot="$SYSROOT" \
    --with-gxx-include-dir="$gxx_inc" \
    --disable-multilib \
    --disable-nls \
    --disable-libstdcxx-pch \
    --disable-werror

  [[ -f config.status ]] || return 1
}

pkg_build() {
  cd "$BUILD_DIR"
  make $MAKEFLAGS
}

pkg_install() {
  cd "$BUILD_DIR"

  # Instala no stage (adm fará rsync stage -> SYSROOT)
  make DESTDIR="$PKG_STAGEDIR" install

  # Higiene (opcional)
  rm -rf "$PKG_STAGEDIR/usr/share/info" "$PKG_STAGEDIR/usr/share/locale" 2>/dev/null || true
}

pkg_check() {
  local fail=0

  # Headers C++
  if [[ ! -d "$PKG_STAGEDIR/usr/include/c++/${PKG_VERSION}" ]]; then
    echo "FALTA: headers C++ em /usr/include/c++/${PKG_VERSION}" >&2
    fail=1
  fi

  # Bibliotecas: libstdc++.so.* (dinâmica) e/ou libstdc++.a (estática)
  if ! find "$PKG_STAGEDIR" -type f \( -name "libstdc++.so*" -o -name "libstdc++.a" \) | grep -q .; then
    echo "FALTA: libstdc++ (libstdc++.so* ou libstdc++.a) no stage" >&2
    fail=1
  fi

  # Teste mínimo de link (compila e linka com sysroot; requer crt/loader e libc ok)
  if [[ "$fail" -eq 0 ]]; then
    local tdir; tdir="$(mktemp -d)"
    cat >"$tdir/t.cpp" <<'EOF'
#include <iostream>
int main(){ std::cout << "ok\n"; return 0; }
EOF
    if ! "$TOOLSROOT/bin/${CTARGET}-g++" --sysroot="$SYSROOT" "$tdir/t.cpp" -o "$tdir/a.out" >/dev/null 2>&1; then
      echo "ERRO: falhou ao linkar programa C++ de teste (sysroot/toolchain incompletos)" >&2
      fail=1
    fi
    rm -rf "$tdir"
  fi

  return "$fail"
}
