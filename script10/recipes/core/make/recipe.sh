# /var/lib/adm/recipes/core/make/recipe.sh

pkgname="make"
pkgver="4.4.1"
srcext="tar.gz"
srcurl="https://ftp.gnu.org/gnu/make/make-${pkgver}.tar.gz"

# SHA256 do make-4.4.1.tar.gz (OpenEmbedded/Yocto recipe)
sha256="dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3"
md5=""

description="GNU Make - ferramenta de build"
category="core"

deps=("core/musl" "core/binutils" "core/gcc")
provides=("cmd:make" "cmd:gmake")

: "${MAKE_DISABLE_NLS:=1}"
: "${MAKE_WITHOUT_GUILE:=1}"

build() {
  # Evita que CXX vaze para o binário/config; prática usada por distros 
  unset CXX || true

  rm -rf .adm-build
  mkdir -p .adm-build
  cd .adm-build

  local cfg=(
    "--prefix=${PREFIX:-/usr}"
  )

  if [[ "${MAKE_DISABLE_NLS}" == "1" ]]; then
    cfg+=("--disable-nls")
  fi

  if [[ "${MAKE_WITHOUT_GUILE}" == "1" ]]; then
    cfg+=("--without-guile")
  fi

  ../configure "${cfg[@]}"
  make -j"${JOBS}"
}

install_pkg() {
  cd .adm-build
  make DESTDIR="${DESTDIR}" install

  # Compat: algumas pessoas esperam gmake; crie symlink
  install -d "${DESTDIR}/usr/bin"
  ln -sf make "${DESTDIR}/usr/bin/gmake"

  # Copia files/ se existir
  if [[ -d "${FILES_DIR}" ]]; then
    cp -a "${FILES_DIR}/." "${DESTDIR}/"
  fi
}
