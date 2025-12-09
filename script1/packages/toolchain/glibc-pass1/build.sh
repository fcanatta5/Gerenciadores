#!/usr/bin/env bash
# Receita ADM para Glibc 2.42 - Pass 1
#
# Este passo constrói a glibc usando o toolchain Pass 1 em /tools
# e os Linux API headers já instalados em ${ADM_ROOTFS}/usr/include.

###############################################################################
# Metadados básicos do pacote
###############################################################################

PKG_NAME="glibc-pass1"
PKG_VERSION="2.42"

# Tarball oficial da glibc (ajuste o mirror se quiser)
PKG_URLS=(
  "https://ftp.gnu.org/gnu/libc/glibc-${PKG_VERSION}.tar.xz"
)

# Opcional: SHA256 do tarball (recomendável preencher com o valor real)
# PKG_SHA256S=(
#   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# )

# Dependências lógicas dentro do ADM:
#   - binutils/gcc pass1 para /tools
#   - linux-api-headers já instalados em ${ADM_ROOTFS}/usr/include
PKG_DEPENDS=(
  "toolchain/binutils-pass1"
  "toolchain/gcc-pass1"
  "toolchain/linux-api-headers"
)

###############################################################################
# Triplet alvo específico do toolchain
###############################################################################
# Mantemos o mesmo esquema dos outros pacotes:
#   ${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu
# PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu}"
PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_TRIPLET}}"

###############################################################################
# Configure / Build / Install customizados
###############################################################################
# A glibc é chata de cross-build; por isso aqui usamos:
#   - PKG_CONFIGURE_CMD  -> faz um build out-of-tree em subdir "build"
#   - PKG_BUILD_CMD      -> roda make a partir de "build"
#   - PKG_INSTALL_CMD    -> roda make DESTDIR=... install a partir de "build"
#
# O adm.sh, quando vê essas variáveis, executa exatamente os comandos
# abaixo dentro do diretório de build do pacote.

# CONFIGURE (out-of-tree em subdir build/)
PKG_CONFIGURE_CMD='
  set -e

  # Estamos em ${build_dir} (definido pelo adm.sh)
  mkdir -p build
  cd build

  # Descobre o triplet de build (máquina host real)
  BUILD_TRIPLET="$("../scripts/config.guess")"

  # Triplet de host/target da glibc (o mesmo do toolchain)
  HOST_TRIPLET="${PKG_TARGET_TRIPLET:-${TARGET_TRIPLET:-$BUILD_TRIPLET}}"

  # Rootfs (sysroot) onde os headers do Linux já foram instalados
  SYSROOT="${ADM_ROOTFS:-/opt/adm/rootfs}"

  echo "[glibc-pass1/configure] BUILD_TRIPLET=${BUILD_TRIPLET}"
  echo "[glibc-pass1/configure] HOST_TRIPLET=${HOST_TRIPLET}"
  echo "[glibc-pass1/configure] SYSROOT=${SYSROOT}"

  ../configure \
    --prefix=/usr \
    --host="${HOST_TRIPLET}" \
    --build="${BUILD_TRIPLET}" \
    --enable-kernel=4.19 \
    --with-headers="${SYSROOT}/usr/include" \
    --disable-werror
'

# BUILD
PKG_BUILD_CMD='
  set -e
  cd build

  echo "[glibc-pass1/build] Compilando glibc 2.42 (Pass 1)..."
  make -j"${ADM_JOBS:-$(nproc)}"
'

# INSTALL
PKG_INSTALL_CMD='
  set -e
  cd build

  echo "[glibc-pass1/install] Instalando glibc 2.42 (Pass 1) em ${destdir}..."
  make DESTDIR="${destdir}" install
'
