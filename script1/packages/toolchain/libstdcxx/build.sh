#!/usr/bin/env bash
# Receita ADM para Libstdc++ a partir do GCC 15.2.0 (Pass 1 / temporário)
#
# Este pacote constrói apenas a libstdc++ (runtime C++) usando:
#   - Fontes do GCC 15.2.0
#   - Toolchain temporário em /tools (gcc-pass1)
#   - Glibc já instalada no ROOTFS (glibc-pass1)
#
# É o equivalente ao passo "Libstdc++ from GCC" após glibc, antes do GCC final.

###############################################################################
# Metadados básicos do pacote
###############################################################################

PKG_NAME="libstdcxx"
PKG_VERSION="15.2.0"

# Usamos o mesmo tarball do GCC; apenas extraímos dele a subárvore libstdc++-v3.
PKG_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
)

# Opcional: SHA256 do tarball (preencha com o valor real, se quiser validação)
# PKG_SHA256S=(
#   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# )

# Dependências lógicas dentro do ADM:
#   - Toolchain temporário (binutils/gcc em /tools)
#   - Linux API headers já instalados em ROOTFS/usr/include
#   - Glibc já instalada em ROOTFS (glibc-pass1)
PKG_DEPENDS=(
  "toolchain/binutils-pass1"
  "toolchain/gcc-pass1"
  "toolchain/linux-api-headers"
  "toolchain/glibc-pass1"
)

###############################################################################
# Triplet alvo específico do toolchain
###############################################################################
# Mantemos o mesmo padrão dos outros pacotes:
#   ${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu

PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu}"

###############################################################################
# Configure / Build / Install customizados
###############################################################################
# A libstdc++ é construída a partir da subdiretório libstdc++-v3 do source do GCC,
# em uma build out-of-tree. O ADM executará os comandos abaixo em BUILD_DIR.

# CONFIGURE (out-of-tree em libstdc++-v3/build/)
PKG_CONFIGURE_CMD='
  set -e

  # Estamos em ${build_dir} (raiz do source do GCC) neste contexto.
  # A subárvore da libstdc++ fica em libstdc++-v3.
  if [[ ! -d "libstdc++-v3" ]]; then
    echo "[libstdc++-pass1/configure] ERRO: diretório libstdc++-v3 não encontrado no source do GCC." >&2
    exit 1
  fi

  cd libstdc++-v3
  mkdir -p build
  cd build

  BUILD_TRIPLET="$("../../config.guess")"
  HOST_TRIPLET="${PKG_TARGET_TRIPLET:-${TARGET_TRIPLET:-$BUILD_TRIPLET}}"
  SYSROOT="${ADM_ROOTFS:-/opt/adm/rootfs}"

  echo "[libstdc++-pass1/configure] BUILD_TRIPLET=${BUILD_TRIPLET}"
  echo "[libstdc++-pass1/configure] HOST_TRIPLET=${HOST_TRIPLET}"
  echo "[libstdc++-pass1/configure] SYSROOT=${SYSROOT}"

  ../configure \
    --prefix=/usr \
    --host="${HOST_TRIPLET}" \
    --build="${BUILD_TRIPLET}" \
    --disable-multilib \
    --disable-nls \
    --disable-libstdcxx-pch \
    --with-gxx-include-dir=/usr/include/c++/"${PKG_VERSION}"
'

# BUILD
PKG_BUILD_CMD='
  set -e
  cd libstdc++-v3/build

  echo "[libstdc++-pass1/build] Compilando libstdc++ (a partir do GCC ${PKG_VERSION})..."
  make -j"${ADM_JOBS:-$(nproc)}"
'

# INSTALL
PKG_INSTALL_CMD='
  set -e
  cd libstdc++-v3/build

  echo "[libstdc++-pass1/install] Instalando libstdc++ em ${destdir}..."
  make DESTDIR="${destdir}" install
'
