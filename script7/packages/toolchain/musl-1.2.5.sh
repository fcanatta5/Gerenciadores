###############################################################################
# musl 1.2.5 (toolchain) + 2 security patches (CVE-2025-26519 hardening/fix)
# Instala no SYSROOT via stage (DESTDIR), compatível com adm.
#
# Requisitos:
# - Um cross-cc funcional para o target (normalmente em $TOOLSROOT/bin/${CTARGET}-gcc)
# - Para uso como libc do sysroot: recomenda-se linux-headers já instalados no sysroot,
#   mas musl em si não exige headers do kernel para compilar (upstream).
###############################################################################

PKG_CATEGORY="toolchain"
PKG_NAME="musl"
PKG_VERSION="1.2.5"
PKG_RELEASE="1"
PKG_DESC="musl libc ${PKG_VERSION} para sysroot do target + patches de segurança"
PKG_LICENSE="MIT"
PKG_SITE="https://musl.libc.org/"

# Dependências mínimas típicas para fluxo de toolchain (ajuste conforme seu repo):
PKG_DEPENDS=(
  "toolchain/binutils-2.45.1-pass1"
  "toolchain/gcc-15.2.0-pass1"
)

PKG_URLS=(
  "https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"
  "https://git.musl-libc.org/cgit/musl/snapshot/musl-${PKG_VERSION}.tar.gz"
)

# SHA256 do tarball do release musl-1.2.5.tar.gz
PKG_SHA256="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

###############################################################################
# Patches de segurança (upstream) – CVE-2025-26519
# 1) fix EUC-KR decoder bounds validation (commit e5adcd97...)
# 2) harden UTF-8 output against decoder bugs (commit c47ad25e...)
###############################################################################

_patch_fetch() {
  # $1=url $2=out $3=must_contain (string para validar)
  local url="$1" out="$2" must="$3"
  command -v curl >/dev/null 2>&1 || { echo "ERRO: curl requerido para baixar patches" >&2; return 1; }
  curl -L --fail --retry 3 --retry-delay 2 -o "$out" "$url"
  grep -qF "$must" "$out" || { echo "ERRO: patch não contém marcador esperado: $must" >&2; return 1; }
}

_patch_apply() {
  # $1=patchfile
  command -v patch >/dev/null 2>&1 || { echo "ERRO: patch requerido para aplicar patches" >&2; return 1; }
  patch -p1 --fuzz=0 --no-backup-if-mismatch <"$1"
}

_get_musl_arch() {
  # Tenta descobrir ARCH usado pelo musl (para ld-musl-$ARCH.path)
  # Lê config.mak gerado pelo configure.
  if [[ -f "$BUILD_DIR/config.mak" ]]; then
    awk -F'=' '/^[[:space:]]*ARCH[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$BUILD_DIR/config.mak"
    return 0
  fi
  echo ""
}

###############################################################################
# Hooks
###############################################################################

pkg_prepare() {
  SRC_DIR="$PKG_WORKDIR/musl-${PKG_VERSION}"
  [[ -d "$SRC_DIR" ]] || {
    SRC_DIR="$(find "$PKG_WORKDIR" -maxdepth 1 -type d | tail -n +2 | head -n1)"
  }
  export SRC_DIR

  BUILD_DIR="$PKG_BUILDDIR"
  mkdir -p "$BUILD_DIR"

  # Sanidade: cross-gcc precisa existir (pass1 em tools normalmente)
  if [[ ! -x "$TOOLSROOT/bin/${CTARGET}-gcc" ]]; then
    echo "ERRO: cross-gcc não encontrado: $TOOLSROOT/bin/${CTARGET}-gcc" >&2
    return 1
  fi

  # Baixa patches (2) e valida cabeçalho "From <commit>"
  PATCH1="$BUILD_DIR/0001-iconv-fix-euc-kr.patch"
  PATCH2="$BUILD_DIR/0002-iconv-harden-utf8-output.patch"

  _patch_fetch \
    "https://www.openwall.com/lists/musl/2025/02/13/1/1" \
    "$PATCH1" \
    "From e5adcd97b5196e29991b524237381a0202a60659"

  _patch_fetch \
    "https://www.openwall.com/lists/musl/2025/02/13/1/2" \
    "$PATCH2" \
    "From c47ad25ea3b484e10326f933e927c0bc8cded3da"
}

pkg_configure() {
  cd "$SRC_DIR"

  # Aplica patches upstream (CVE-2025-26519)
  _patch_apply "$PATCH1"
  _patch_apply "$PATCH2"

  # Configure do musl detecta ARCH pelo compilador; forçamos toolchain do target.
  # Para sysroot: prefix=/usr e syslibdir=/lib (dentro do SYSROOT via DESTDIR).
  export CC="$TOOLSROOT/bin/${CTARGET}-gcc"
  export AR="$TOOLSROOT/bin/${CTARGET}-ar"
  export RANLIB="$TOOLSROOT/bin/${CTARGET}-ranlib"

  # Evita contaminação do host por flags “globais” agressivas
  unset CFLAGS CXXFLAGS LDFLAGS

  # Configure out-of-tree não é padrão no musl; então fazemos in-tree,
  # mas direcionamos build outputs pelo BUILD_DIR via make O=... não existe aqui.
  # Estratégia segura: build separado via 'make -C' não é suportada; então:
  # - executa configure no SRC_DIR, mas força objetos no próprio tree
  # - usa BUILD_DIR apenas para patches/artefatos auxiliares
  ./configure \
    --prefix=/usr \
    --syslibdir=/lib

  [[ -f config.mak ]] || { echo "ERRO: config.mak não gerado pelo configure" >&2; return 1; }

  # Copia config.mak para BUILD_DIR para leitura posterior (ARCH)
  cp -f config.mak "$BUILD_DIR/config.mak"
}

pkg_build() {
  cd "$SRC_DIR"
  make $MAKEFLAGS
}

pkg_install() {
  cd "$SRC_DIR"

  # Instala no STAGE do adm; depois o adm fará rsync para $SYSROOT.
  make DESTDIR="$PKG_STAGEDIR" install

  # Arquivo de path do dynamic linker (recomendado upstream para runtime)
  local arch
  arch="$(_get_musl_arch)"
  if [[ -n "$arch" ]]; then
    mkdir -p "$PKG_STAGEDIR/etc"
    # Paths padrão dentro do sysroot
    printf "%s\n" "/lib" "/usr/lib" >"$PKG_STAGEDIR/etc/ld-musl-${arch}.path"
  fi

  # Higiene opcional
  rm -rf "$PKG_STAGEDIR/usr/share/info" "$PKG_STAGEDIR/usr/share/locale" 2>/dev/null || true
}

pkg_check() {
  local fail=0

  # Header-chave
  if [[ ! -f "$PKG_STAGEDIR/usr/include/stdlib.h" ]]; then
    echo "FALTA: /usr/include/stdlib.h (headers do musl)" >&2
    fail=1
  fi

  # libc shared (musl instala libc.so e libc.musl-*.so.1 conforme arch)
  if ! find "$PKG_STAGEDIR" -type f \( -name "libc.so" -o -name "libc.musl-*.so.1" -o -name "libc.a" \) | grep -q .; then
    echo "FALTA: libc (libc.so/libc.musl-*.so.1/libc.a) no stage" >&2
    fail=1
  fi

  # dynamic linker (deve existir em /lib)
  if ! find "$PKG_STAGEDIR/lib" -maxdepth 1 -type f -name "ld-musl-*.so.1" | grep -q .; then
    echo "FALTA: loader ld-musl-*.so.1 em /lib" >&2
    fail=1
  fi

  return "$fail"
}
