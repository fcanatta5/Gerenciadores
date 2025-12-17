# /var/lib/adm/recipes/core/binutils/recipe.sh

pkgname="binutils"
pkgver="2.42"
srcext="tar.xz"
srcurl="https://ftp.gnu.org/gnu/binutils/binutils-${pkgver}.tar.xz"

# SHA256 oficial do tarball binutils-2.42.tar.xz 
sha256="f6e4d41fd5fc778b06b7891457b3620da5ecea1006c6a4a41ae998109f85a800"
md5=""

description="GNU Binutils (as, ld, ar, ranlib, objdump, etc.)"
category="core"

# Para um build nativo no seu rootfs musl:
# - musl já precisa existir (libc + headers básicos)
# - linux headers normalmente já devem estar instalados (para alguns alvos/recursos)
deps=("core/musl" "core/linux-headers")
provides=("cmd:ld" "cmd:as" "cmd:ar")

# Ajustes de política
: "${BINUTILS_PREFIX:=/usr}"
: "${BINUTILS_SYSROOT:=/}"          # dentro do chroot
: "${BINUTILS_DISABLE_NLS:=1}"
: "${BINUTILS_ENABLE_GOLD:=0}"      # 0 = mais simples (só ld.bfd)
: "${BINUTILS_ENABLE_PLUGINS:=1}"   # útil para LTO etc.

build() {
  # build out-of-tree (recomendado pelo upstream)
  rm -rf .adm-build
  mkdir -p .adm-build
  cd .adm-build

  local cfg=(
    "--prefix=${BINUTILS_PREFIX}"
    "--with-sysroot=${BINUTILS_SYSROOT}"
    "--disable-werror"
  )

  if [[ "${BINUTILS_DISABLE_NLS}" == "1" ]]; then
    cfg+=("--disable-nls")
  fi

  if [[ "${BINUTILS_ENABLE_GOLD}" == "1" ]]; then
    cfg+=("--enable-gold")
  else
    cfg+=("--disable-gold")
  fi

  if [[ "${BINUTILS_ENABLE_PLUGINS}" == "1" ]]; then
    cfg+=("--enable-plugins")
  else
    cfg+=("--disable-plugins")
  fi

  # Observação:
  # - Para musl, manter simples costuma ser melhor.
  # - zlib é opcional; se você quiser compressão em debug sections, adicione deps e --with-zlib.
  ../configure "${cfg[@]}"

  make -j"${JOBS}"
}

install_pkg() {
  cd .adm-build

  # Instala em staging (DESTDIR imposto pelo adm)
  make DESTDIR="${DESTDIR}" install

  # Opcional: remover itens que você não quer no core (ex.: info pages)
  # rm -rf "${DESTDIR}/usr/share/info" 2>/dev/null || true

  # Instala arquivos auxiliares versionados via files/ se existirem
  if [[ -d "${FILES_DIR}" ]]; then
    cp -a "${FILES_DIR}/." "${DESTDIR}/"
  fi
}

# Hooks opcionais (se você estiver usando hooks no adm)
post_install() {
  : # nada obrigatório aqui
}
