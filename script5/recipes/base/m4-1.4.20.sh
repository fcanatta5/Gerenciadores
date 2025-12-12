# /opt/adm/packages/base/m4-1.4.20.sh
#
# m4 1.4.20 (base) — instala em /usr no rootfs do profile atual
# Alinhado ao adm.sh:
# - build() instala em DESTDIR="$PKG_BUILD_ROOT"
# - adm.sh empacota e extrai no $PKG_ROOTFS do profile
# - hook de sanity-check em post_install
#
# Observação:
# - m4 é essencial para toolchains/autotools.
# - Requer ambiente de build funcional (make, gcc, etc.) no profile/chroot.

PKG_NAME="m4"
PKG_VERSION="1.4.20"
PKG_DESC="GNU m4 macro processor"
PKG_DEPENDS="glibc"
PKG_CATEGORY="base"
PKG_LIBC="glibc"

build() {
  local url="https://ftp.gnu.org/gnu/m4/m4-${PKG_VERSION}.tar.xz"
  local tar="m4-${PKG_VERSION}.tar.xz"
  local src

  src="$(fetch_source "$url" "$tar")"

  mkdir -p "$PKG_BUILD_WORK"
  cd "$PKG_BUILD_WORK"
  rm -rf "m4-${PKG_VERSION}" build
  tar xf "$src"
  mkdir -p build
  cd build

  # Configure padrão base (/usr)
  ../m4-${PKG_VERSION}/configure \
    --prefix=/usr \
    --disable-nls

  make
  make install DESTDIR="$PKG_BUILD_ROOT"
}

pre_install() {
  echo "==> [m4-${PKG_VERSION}] Instalando m4 no rootfs do profile via adm"
}

post_install() {
  echo "==> [m4-${PKG_VERSION}] Sanity-check pós-instalação"

  local sysroot="${PKG_ROOTFS:-$ADM_CURRENT_ROOTFS}"
  local bin="${sysroot}/usr/bin/m4"

  if [ ! -x "$bin" ]; then
    echo "ERRO: m4 não encontrado ou não executável em: $bin"
    exit 1
  fi

  # Valida versão (1.4.20)
  if ! "$bin" --version 2>/dev/null | head -n1 | grep -q "1\.4\.20"; then
    echo "ERRO: m4 --version não indica ${PKG_VERSION}"
    "$bin" --version 2>/dev/null | head -n2 || true
    exit 1
  fi

  # Teste funcional simples (expansão de macro)
  local out
  out="$("$bin" <<'EOF'
define(X,42)X
EOF
)"
  # remove espaços/linhas vazias para comparar
  out="$(printf '%s' "$out" | tr -d ' \n\r\t')"
  if [ "$out" != "42" ]; then
    echo "ERRO: teste funcional do m4 falhou (resultado='$out')"
    exit 1
  fi

  echo "Sanity-check m4 ${PKG_VERSION}: OK."
}
