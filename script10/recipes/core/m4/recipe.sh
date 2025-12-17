# /var/lib/adm/recipes/core/m4/recipe.sh

pkgname="m4"
pkgver="1.4.20"
srcext="tar.xz"
srcurl="https://ftpmirror.gnu.org/m4/m4-${pkgver}.tar.xz"

# SHA256 oficial do m4-1.4.20.tar.xz 2
sha256="e236ea3a1ccf5f6c270b1c4bb60726f371fa49459a8eaaebc90b216b328daf2b"
md5=""

description="GNU m4 - processador de macros (necessário para autoconf e toolchain)"
category="core"

# m4 é ferramenta de build; assumimos toolchain básico já pronto.
deps=("core/musl" "core/binutils" "core/gcc")
provides=("cmd:m4")

# Política de minimalismo: sem traduções (evita dependência em gettext)
: "${M4_DISABLE_NLS:=1}"

build() {
  local cfg=(
    "--prefix=${PREFIX:-/usr}"
  )

  if [[ "${M4_DISABLE_NLS}" == "1" ]]; then
    cfg+=("--disable-nls")
  fi

  ./configure "${cfg[@]}"
  make -j"${JOBS}"
}

install_pkg() {
  make DESTDIR="${DESTDIR}" install

  # Opcional: remover info/man se você quiser ultra-minimal
  # rm -rf "${DESTDIR}/usr/share/info" "${DESTDIR}/usr/share/man" 2>/dev/null || true

  # Copia files/ (se existir)
  if [[ -d "${FILES_DIR}" ]]; then
    cp -a "${FILES_DIR}/." "${DESTDIR}/"
  fi
}
