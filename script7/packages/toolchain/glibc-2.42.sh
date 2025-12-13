###############################################################################
# Glibc 2.42 (toolchain) - instala libc no SYSROOT do target
# Compatível com adm: PKG_WORKDIR/PKG_BUILDDIR/PKG_STAGEDIR, CTARGET, CHOST,
# SYSROOT, TOOLSROOT, MAKEFLAGS.
###############################################################################

PKG_CATEGORY="toolchain"
PKG_NAME="glibc"
PKG_VERSION="2.42"
PKG_RELEASE="1"
PKG_DESC="GNU C Library ${PKG_VERSION} para sysroot do target"
PKG_LICENSE="LGPL-2.1-or-later"
PKG_SITE="https://www.gnu.org/software/libc/"

# Dependências típicas do fluxo:
# - binutils pass1 (tools) e gcc pass1 (tools) precisam existir para $CTARGET
# - linux-headers devem estar instalados em $SYSROOT/usr/include
# Ajuste os specs se os nomes diferirem no seu repo:
PKG_DEPENDS=(
  "toolchain/binutils-2.45.1-pass1"
  "toolchain/gcc-15.2.0-pass1"
  "toolchain/linux-headers-6.17.9"
)

PKG_URLS=(
  "https://ftp.gnu.org/gnu/glibc/glibc-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/glibc/glibc-${PKG_VERSION}.tar.xz"
)

# O LFS 12.4 (stable-systemd) publica o MD5 do tarball glibc-2.42.tar.xz,
# e o índice do ftp.gnu confirma o arquivo. 0
PKG_MD5="23c6f5a27932b435cae94e087cb8b1f5"

###############################################################################
# Hooks
###############################################################################

pkg_prepare() {
  # Source dir
  SRC_DIR="$PKG_WORKDIR/glibc-${PKG_VERSION}"
  [[ -d "$SRC_DIR" ]] || {
    SRC_DIR="$(find "$PKG_WORKDIR" -maxdepth 1 -type d | tail -n +2 | head -n1)"
  }
  export SRC_DIR

  # Build dir out-of-tree
  BUILD_DIR="$PKG_BUILDDIR"
  mkdir -p "$BUILD_DIR"

  # Sanidade: linux headers devem existir no sysroot
  if [[ ! -f "$SYSROOT/usr/include/linux/version.h" && ! -f "$SYSROOT/usr/include/linux/types.h" ]]; then
    echo "ERRO: linux headers não encontrados em $SYSROOT/usr/include" >&2
    echo "      Instale toolchain/linux-headers antes do glibc." >&2
    return 1
  fi

  # Sanidade: cross-gcc precisa existir em tools
  if [[ ! -x "$TOOLSROOT/bin/${CTARGET}-gcc" ]]; then
    echo "ERRO: cross-gcc não encontrado em $TOOLSROOT/bin/${CTARGET}-gcc" >&2
    echo "      Instale gcc-pass1 antes do glibc." >&2
    return 1
  fi
}

pkg_configure() {
  cd "$BUILD_DIR"

  # Evita contaminação do host (glibc é sensível a flags agressivas)
  unset CFLAGS CXXFLAGS LDFLAGS

  # Ferramentas de build (host)
  export BUILD_CC="${BUILD_CC:-gcc}"
  export BUILD_CXX="${BUILD_CXX:-g++}"

  # Ferramentas do target (usando tools/pass1)
  export CC="$TOOLSROOT/bin/${CTARGET}-gcc"
  export CXX="$TOOLSROOT/bin/${CTARGET}-g++"
  export AR="$TOOLSROOT/bin/${CTARGET}-ar"
  export RANLIB="$TOOLSROOT/bin/${CTARGET}-ranlib"

  # Para garantir sysroot no compile/link
  export CPPFLAGS="${CPPFLAGS:-} --sysroot=$SYSROOT"

  # Cache de respostas para cross (evita testes que não podem rodar no host)
  # Esses valores são práticas comuns em builds cross da glibc.
  cat >config.cache <<'EOF'
libc_cv_forced_unwind=yes
libc_cv_c_cleanup=yes
libc_cv_ssp=no
EOF

  # Prefix correto dentro do sysroot:
  # glibc instala libs em /lib e /usr/lib dependendo da config/arch; usamos prefix=/usr
  # e let glibc controlar os diretórios internos.
  #
  # --with-headers aponta para headers do kernel instalados no sysroot.
  #
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

  # Instala no STAGE (não direto no SYSROOT). O adm fará rsync stage->SYSROOT.
  # DESTDIR é o método correto para staged install.
  make DESTDIR="$PKG_STAGEDIR" install

  # Ajustes mínimos de layout em sysroot:
  # Algumas arquiteturas usam /lib64; mantemos o que glibc instalou.
  # Garantimos que /lib exista (alguns layouts colocam ld.so em /lib).
  mkdir -p "$PKG_STAGEDIR/lib" "$PKG_STAGEDIR/usr/lib"

  # Remove arquivos de locale/info do stage (opcional para toolchain early)
  rm -rf "$PKG_STAGEDIR/usr/share/info" "$PKG_STAGEDIR/usr/share/locale" 2>/dev/null || true
}

pkg_check() {
  local fail=0

  # Artefatos-chave esperados
  if [[ ! -f "$PKG_STAGEDIR/usr/include/gnu/libc-version.h" ]]; then
    echo "FALTA: gnu/libc-version.h (headers da glibc não instalados)" >&2
    fail=1
  fi

  # libc.so.6 pode estar em /lib, /lib64, /usr/lib, /usr/lib64; checa de forma robusta
  if ! find "$PKG_STAGEDIR" -type f -name "libc.so.6" | grep -q .; then
    echo "FALTA: libc.so.6 (runtime da glibc)" >&2
    fail=1
  fi

  # loader (ld-linux / ld.so) varia por arch; checa presença de algum loader comum
  if ! find "$PKG_STAGEDIR" -type f \( -name "ld-linux*.so.*" -o -name "ld.so" -o -name "ld-musl-*.so.*" \) | grep -q .; then
    echo "WARN: não encontrei loader (ld-linux/ld.so) no stage; verifique se o target usa nome diferente." >&2
    # não falha duro porque o nome é muito dependente de arch
  fi

  # ldd (script/util)
  if [[ ! -f "$PKG_STAGEDIR/usr/bin/ldd" ]]; then
    echo "WARN: ldd não encontrado em /usr/bin/ldd (pode depender do config/instalação)" >&2
  fi

  return "$fail"
}
