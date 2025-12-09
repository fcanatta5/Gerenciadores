#!/usr/bin/env bash
# Receita ADM para GCC 15.2.0 - Toolchain final em /usr

###############################################################################
# Metadados básicos do pacote
###############################################################################

PKG_NAME="gcc"
PKG_VERSION="15.2.0"

# Versões dos pré-requisitos internos do GCC
GMP_VERSION="6.3.0"
MPFR_VERSION="4.2.1"
MPC_VERSION="1.3.1"

# Fontes:
#  - GCC
#  - GMP, MPFR, MPC (usados como "in-tree builds" via hook pre_build)
PKG_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VERSION}.tar.xz"
  "https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VERSION}.tar.xz"
  "https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VERSION}.tar.gz"
)

# Opcional: checksums. Preencha se quiser validação estrita.
# PKG_SHA256S=(
#   "sha256-gcc-15.2.0..."
#   "sha256-gmp-6.3.0..."
#   "sha256-mpfr-4.2.1..."
#   "sha256-mpc-1.3.1..."
# )

# Dependências lógicas dentro do ADM:
#   - binutils final em /usr
#   - glibc já instalada no ROOTFS
#   - linux-api-headers (para consistência)
PKG_DEPENDS=(
  "toolchain/binutils"
  "toolchain/linux-api-headers"
  "toolchain/glibc-pass1"
)

###############################################################################
# Triplet alvo do sistema
###############################################################################
# Mantemos o padrão:
#   ${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu

PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu}"

###############################################################################
# Configure / Build / Install customizados
###############################################################################
# Vamos fazer um build out-of-tree em subdir "build" (padrão do GCC).
# O adm.sh, ao ver PKG_CONFIGURE_CMD/BUILD_CMD/INSTALL_CMD, executa esses
# comandos dentro de ${build_dir} do pacote.

# CONFIGURE (out-of-tree em subdir build/)
PKG_CONFIGURE_CMD='
  set -e

  # Estamos em ${build_dir} (raiz do source do GCC) neste contexto.
  mkdir -p build
  cd build

  BUILD_TRIPLET="$("../config.guess")"
  HOST_TRIPLET="${PKG_TARGET_TRIPLET:-${TARGET_TRIPLET:-$BUILD_TRIPLET}}"
  SYSROOT="${ADM_ROOTFS:-/opt/adm/rootfs}"

  echo "[gcc-final/configure] BUILD_TRIPLET=${BUILD_TRIPLET}"
  echo "[gcc-final/configure] HOST_TRIPLET=${HOST_TRIPLET}"
  echo "[gcc-final/configure] SYSROOT=${SYSROOT}"

  ../configure \
    --prefix=/usr \
    --host="${HOST_TRIPLET}" \
    --build="${BUILD_TRIPLET}" \
    --with-sysroot="${SYSROOT}" \
    --with-native-system-header-dir=/usr/include \
    --enable-languages=c,c++,lto \
    --enable-shared \
    --enable-threads=posix \
    --enable-default-pie \
    --enable-default-ssp \
    --disable-multilib \
    --disable-bootstrap \
    --enable-linker-build-id \
    --with-system-zlib \
    --disable-werror
'

# BUILD
PKG_BUILD_CMD='
  set -e
  cd build

  echo "[gcc-final/build] Compilando GCC 15.2.0 (final)..."
  make -j"${ADM_JOBS:-$(nproc)}"
'

# INSTALL
PKG_INSTALL_CMD='
  set -e
  cd build

  echo "[gcc-final/install] Instalando GCC 15.2.0 em ${destdir}..."
  make DESTDIR="${destdir}" install
'
