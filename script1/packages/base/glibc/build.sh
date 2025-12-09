#!/usr/bin/env bash
# Receita ADM para Glibc 2.42 - Toolchain final
#
# Esta glibc assume:
#   - binutils final em /usr (no ROOTFS)
#   - GCC funcional já disponível (toolchain “estável”)
#   - Linux API headers instalados em ${ADM_ROOTFS}/usr/include

###############################################################################
# Metadados básicos do pacote
###############################################################################

PKG_NAME="glibc"
PKG_VERSION="2.42"

# Tarball oficial da glibc (ajuste o espelho se quiser)
PKG_URLS=(
  "https://ftp.gnu.org/gnu/libc/glibc-${PKG_VERSION}.tar.xz"
)

# Opcional: SHA256 do tarball (recomendável preencher)
# PKG_SHA256S=(
#   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# )

# Dependências lógicas dentro do ADM:
#   - binutils final
#   - gcc final (ou pelo menos um GCC estável)
#   - linux-api-headers
PKG_DEPENDS=(
  "toolchain/binutils"
  "toolchain/gcc"
  "toolchain/linux-api-headers"
)

###############################################################################
# Triplet alvo
###############################################################################
# Usa o triplet definido pelo perfil (-P glibc):
#   ADM_TARGET_TRIPLET=x86_64-lfs-linux-gnu, por exemplo.

PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_TRIPLET}}"

###############################################################################
# Configure / Build / Install customizados
###############################################################################
# Usamos build out-of-tree em subdir "build".
# O adm.sh executa estes comandos dentro de ${build_dir} do pacote.

# CONFIGURE
PKG_CONFIGURE_CMD='
  set -e

  # Estamos em ${build_dir} (raiz do source da glibc) neste contexto
  mkdir -p build
  cd build

  # Triplets
  BUILD_TRIPLET="$("../scripts/config.guess")"
  HOST_TRIPLET="${PKG_TARGET_TRIPLET:-${TARGET_TRIPLET:-$BUILD_TRIPLET}}"

  # Rootfs onde estão os headers do kernel e a glibc anterior (se houver)
  SYSROOT="${ADM_ROOTFS:-/opt/adm/rootfs}"

  echo "[glibc-final/configure] BUILD_TRIPLET=${BUILD_TRIPLET}"
  echo "[glibc-final/configure] HOST_TRIPLET=${HOST_TRIPLET}"
  echo "[glibc-final/configure] SYSROOT=${SYSROOT}"

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

  echo "[glibc-final/build] Compilando glibc 2.42..."
  make -j"${ADM_JOBS:-$(nproc)}"
'

# INSTALL
PKG_INSTALL_CMD='
  set -e
  cd build

  echo "[glibc-final/install] Instalando glibc 2.42 em ${destdir}..."
  make DESTDIR="${destdir}" install
'
