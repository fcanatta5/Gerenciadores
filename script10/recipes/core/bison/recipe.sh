# /var/lib/adm/recipes/core/bison/recipe.sh

pkgname="bison"
pkgver="3.8.2"
srcext="tar.xz"
srcurl="https://ftpmirror.gnu.org/gnu/bison/bison-${pkgver}.tar.xz"

# SHA256 do bison-3.8.2.tar.xz (referenciado por Homebrew para o tarball oficial) 3
sha256="9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2"
md5=""

description="GNU Bison - gerador de parsers (necessário para toolchain e vários builds)"
category="core"

deps=("core/m4" "core/musl" "core/binutils" "core/gcc")
provides=("cmd:bison" "cmd:yacc")

: "${BISON_DISABLE_NLS:=1}"
: "${BISON_M4:=/usr/bin/m4}"

build() {
  rm -rf .adm-build
  mkdir -p .adm-build
  cd .adm-build

  local cfg=(
    "--prefix=${PREFIX:-/usr}"
  )

  if [[ "${BISON_DISABLE_NLS}" == "1" ]]; then
    cfg+=("--disable-nls")
  fi

  # Bison precisa do m4 em runtime/build; forçamos caminho.
  ../configure "${cfg[@]}" "M4=${BISON_M4}"

  make -j"${JOBS}"
}

install_pkg() {
  cd .adm-build
  make DESTDIR="${DESTDIR}" install

  # Copia files/ se existir
  if [[ -d "${FILES_DIR}" ]]; then
    cp -a "${FILES_DIR}/." "${DESTDIR}/"
  fi
}
