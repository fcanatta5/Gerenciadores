# binutils-pass1/recipe.sh
PKG_NAME="binutils-pass1"
PKG_VERSION="2.45.1"
PKG_DESC="GNU Binutils (Pass 1) for temporary cross-toolchain (/tools)"

PKG_HOMEPAGE="https://www.gnu.org/software/binutils/"
PKG_LICENSE="GPL-3.0-or-later"

# Fonte + hashes (preencha os hashes reais do tarball que você baixar).
# Recomendo você definir pelo menos SHA256. (MD5 opcional.)
PKG_SOURCES=(
  "https://ftp.gnu.org/gnu/binutils/binutils-2.45.1.tar.xz|<SHA256_AQUI>|<MD5_AQUI>"
  # Alternativas espelho (se quiser):
  # "https://ftpmirror.gnu.org/binutils/binutils-2.45.1.tar.xz|<SHA256_AQUI>|<MD5_AQUI>"
)

# Dependências do pass1 (ajuste se você tiver mais coisas no seu fluxo)
# No LFS, binutils-pass1 depende basicamente de um ambiente host funcional.
PKG_BUILD_DEPS=()
PKG_DEPS=()

# Hooks opcionais
pre_configure() {
  # Sanidade: este recipe é para profile tools.
  if [[ "${ADM_PROFILE_KIND:-}" != "tools" ]]; then
    echo "Este pacote deve ser construído com profile 'tools'." >&2
    return 1
  fi
  if [[ -z "${ADM_TARGET_TRIPLE:-}" ]]; then
    echo "ADM_TARGET_TRIPLE não definido no profile tools (ex.: x86_64-lfs-linux-gnu)." >&2
    return 1
  fi
}

pkg_configure() {
  # Build out-of-tree: cria dir build e configura de lá
  mkdir -p build
  cd build

  # DESTDIR será $ADM_BUILD_ROOT/.../dest (definido pelo adm.sh)
  # --prefix=/tools para instalar no /tools
  # --with-sysroot=$ADM_ROOTFS para que o linker encontre libs/headers no sysroot do rootfs
  # --disable-nls e --disable-werror conforme LFS para reduzir variabilidade/fragilidade.
  ../configure \
    --prefix=/tools \
    --with-sysroot="${ADM_ROOTFS}" \
    --target="${ADM_TARGET_TRIPLE}" \
    --disable-nls \
    --disable-werror
}

pkg_build() {
  cd build
  make -j"${MAKEJOBS:-1}"
}

pkg_install() {
  cd build
  # instala em DESTDIR (staging); o adm.sh faz rsync para o rootfs depois.
  make DESTDIR="$DESTDIR" install
}

post_install() {
  # Opcional: remover doc/infos para reduzir tamanho do tools
  # (mantenho conservador; ajuste se quiser)
  :
}
