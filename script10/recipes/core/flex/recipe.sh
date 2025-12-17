# /var/lib/adm/recipes/core/flex/recipe.sh

pkgname="flex"
pkgver="2.6.4"
srcext="tar.gz"
srcurl="https://github.com/westes/flex/releases/download/v${pkgver}/flex-${pkgver}.tar.gz"  # 3

# SHA256 do tarball upstream (mesmo conteúdo do orig.tar.gz distribuído)
# Launchpad publica o SHA-256 do flex_2.6.4.orig.tar.gz: e87aae... 4
sha256="e87aae032bf07c26f85ac0ed3250998c37621d95f8bd748b31f15b33c45ee995"
md5=""

description="Flex - gerador de analisadores léxicos (lex)"
category="core"

# Em geral o tarball já vem com arquivos gerados, então não é obrigatório ter bison para compilar.
# Mantemos deps mínimas e compatíveis com seu core:
deps=("core/musl" "core/binutils" "core/gcc" "core/m4")
provides=("cmd:flex" "cmd:lex")

: "${FLEX_DISABLE_NLS:=1}"

build() {
  rm -rf .adm-build
  mkdir -p .adm-build
  cd .adm-build

  local cfg=(
    "--prefix=${PREFIX:-/usr}"
  )

  if [[ "${FLEX_DISABLE_NLS}" == "1" ]]; then
    cfg+=("--disable-nls")
  fi

  ../configure "${cfg[@]}"
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
