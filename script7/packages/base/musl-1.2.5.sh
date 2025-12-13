###############################################################################
# musl 1.2.5 (toolchain) + 2 security patches
# - Instala libc no SYSROOT via stage (DESTDIR = PKG_STAGEDIR)
# - Cross: usa $TOOLSROOT/bin/${CTARGET}-gcc e $SYSROOT como sysroot final
#
# Requisitos no host:
#   bash, make, curl, patch, sha256sum, tar, gzip
###############################################################################

PKG_CATEGORY="toolchain"
PKG_NAME="musl"
PKG_VERSION="1.2.5"
PKG_RELEASE="1"
PKG_DESC="musl libc ${PKG_VERSION} para sysroot do target + 2 patches de segurança"
PKG_LICENSE="MIT"
PKG_SITE="https://musl.libc.org/"

# Dependências típicas de toolchain (ajuste se o seu repo usar nomes diferentes)
PKG_DEPENDS=(
  "toolchain/binutils-2.45.1-pass1"
  "toolchain/gcc-15.2.0-pass1"
)

PKG_URLS=(
  "https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"
)

# SHA256 do tarball do release musl-1.2.5.tar.gz
PKG_SHA256="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

###############################################################################
# 2 patches de segurança (preencha os SHA256!)
#
# Você pode apontar para:
# - um commit patch “raw” do cgit do musl
# - ou um arquivo .patch dentro do seu repo (via file://... não é suportado pelo fetch
#   central do adm, então aqui baixamos com curl)
#
# IMPORTANTE: preencha PATCH*_SHA256 com o sha256 do conteúdo baixado.
###############################################################################

PATCH1_NAME="0001-security-fix-1.patch"
PATCH1_URL="COLOQUE_AQUI_URL_DO_PATCH_1"
PATCH1_SHA256="COLOQUE_AQUI_SHA256_DO_PATCH_1"

PATCH2_NAME="0002-security-fix-2.patch"
PATCH2_URL="COLOQUE_AQUI_URL_DO_PATCH_2"
PATCH2_SHA256="COLOQUE_AQUI_SHA256_DO_PATCH_2"

###############################################################################
# Helpers locais
###############################################################################

_need() { command -v "$1" >/dev/null 2>&1 || { echo "ERRO: comando requerido ausente: $1" >&2; return 1; }; }

_sha256_check() {
  # $1=file $2=sha
  local f="$1" sha="$2"
  [[ -n "$sha" && "$sha" != COLOQUE_AQUI_* ]] || { echo "ERRO: SHA256 não configurado para $f" >&2; return 1; }
  echo "$sha  $f" | sha256sum -c - >/dev/null 2>&1 || { echo "ERRO: SHA256 não confere: $f" >&2; return 1; }
}

_fetch_patch() {
  # $1=url $2=out $3=sha256
  local url="$1" out="$2" sha="$3"
  [[ -n "$url" && "$url" != COLOQUE_AQUI_* ]] || { echo "ERRO: URL do patch não configurada ($out)" >&2; return 1; }
  curl -L --fail --retry 3 --retry-delay 2 -o "$out" "$url"
  _sha256_check "$out" "$sha"
}

_apply_patch() {
  # $1=patchfile
  patch -p1 --fuzz=0 --no-backup-if-mismatch <"$1"
}

_karch_from_target() {
  # Determina ARCH usado pelo musl/loader; fallback razoável.
  case "${CTARGET}" in
    x86_64-*)   echo "x86_64" ;;
    i?86-*)     echo "i386" ;;
    aarch64-*)  echo "aarch64" ;;
    armv7*-*|armv6*-*|arm-*) echo "arm" ;;
    riscv64-*)  echo "riscv64" ;;
    mips64el-*|mips64-*) echo "mips64" ;;
    mipsel-*|mips-*) echo "mips" ;;
    powerpc64le-*|ppc64le-*) echo "powerpc64le" ;;
    powerpc64-*|ppc64-*) echo "powerpc64" ;;
    powerpc-*|ppc-*) echo "powerpc" ;;
    s390x-*) echo "s390x" ;;
    loongarch64-*) echo "loongarch64" ;;
    *) echo "" ;;
  esac
}

###############################################################################
# Hooks
###############################################################################

pkg_prepare() {
  _need make
  _need curl
  _need patch
  _need sha256sum

  SRC_DIR="$PKG_WORKDIR/musl-${PKG_VERSION}"
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

  # Baixa patches (com SHA256 obrigatório)
  PATCH1_FILE="$BUILD_DIR/$PATCH1_NAME"
  PATCH2_FILE="$BUILD_DIR/$PATCH2_NAME"

  rm -f "$PATCH1_FILE" "$PATCH2_FILE"
  _fetch_patch "$PATCH1_URL" "$PATCH1_FILE" "$PATCH1_SHA256"
  _fetch_patch "$PATCH2_URL" "$PATCH2_FILE" "$PATCH2_SHA256"
}

pkg_configure() {
  cd "$SRC_DIR"

  # Aplica patches antes de configurar
  _apply_patch "$PATCH1_FILE"
  _apply_patch "$PATCH2_FILE"

  # Toolchain do target (tools/pass1)
  export CC="$TOOLSROOT/bin/${CTARGET}-gcc"
  export AR="$TOOLSROOT/bin/${CTARGET}-ar"
  export RANLIB="$TOOLSROOT/bin/${CTARGET}-ranlib"
  export STRIP="$TOOLSROOT/bin/${CTARGET}-strip"

  # musl usa CROSS_COMPILE frequentemente
  export CROSS_COMPILE="${CTARGET}-"

  # Evita contaminação do host por flags globais agressivas
  unset CFLAGS CXXFLAGS LDFLAGS

  # Prefix/layout no sysroot:
  # - prefix=/usr (headers e libs de usuário)
  # - syslibdir=/lib (loader e libc runtime em /lib)
  ./configure \
    --prefix=/usr \
    --syslibdir=/lib

  [[ -f config.mak ]] || { echo "ERRO: config.mak não foi gerado" >&2; return 1; }
  cp -f config.mak "$BUILD_DIR/config.mak"
}

pkg_build() {
  cd "$SRC_DIR"
  make $MAKEFLAGS
}

pkg_install() {
  cd "$SRC_DIR"

  # Instala no stage; o adm sincroniza stage -> SYSROOT
  make DESTDIR="$PKG_STAGEDIR" install

  # Cria arquivo de search path do loader (útil em runtime)
  local arch
  arch="$(_karch_from_target)"
  if [[ -n "$arch" ]]; then
    mkdir -p "$PKG_STAGEDIR/etc"
    printf "%s\n" "/lib" "/usr/lib" >"$PKG_STAGEDIR/etc/ld-musl-${arch}.path"
  fi

  # Higiene opcional
  rm -rf "$PKG_STAGEDIR/usr/share/info" "$PKG_STAGEDIR/usr/share/locale" 2>/dev/null || true
}

pkg_check() {
  local fail=0

  # Headers principais
  [[ -f "$PKG_STAGEDIR/usr/include/stdlib.h" ]] || { echo "FALTA: /usr/include/stdlib.h" >&2; fail=1; }
  [[ -f "$PKG_STAGEDIR/usr/include/stdio.h"  ]] || { echo "FALTA: /usr/include/stdio.h"  >&2; fail=1; }

  # libc runtime (musl instala libc.so e libc.musl-*.so.1)
  if ! find "$PKG_STAGEDIR" -type f \( -name "libc.so" -o -name "libc.musl-*.so.1" -o -name "libc.a" \) | grep -q .; then
    echo "FALTA: libc (libc.so/libc.musl-*.so.1/libc.a) no stage" >&2
    fail=1
  fi

  # loader (deve existir em /lib)
  if [[ ! -d "$PKG_STAGEDIR/lib" ]] || ! find "$PKG_STAGEDIR/lib" -maxdepth 1 -type f -name "ld-musl-*.so.1" | grep -q .; then
    echo "FALTA: loader ld-musl-*.so.1 em /lib" >&2
    fail=1
  fi

  return "$fail"
}
