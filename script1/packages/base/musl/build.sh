#!/usr/bin/env bash
# Receita ADM para musl 1.2.5 - libc final do perfil musl
#
# Este pacote constrói a libc musl definitiva para o rootfs do perfil -P musl.
# Pressupõe:
#   - Toolchain estável (binutils + gcc) apontando para o triplet musl
#   - Linux API headers instalados em ${ADM_ROOTFS}/usr/include
#   - Patches de segurança (se houver) em patches/*.patch, aplicados pelo adm.sh

###############################################################################
# Metadados básicos do pacote
###############################################################################

PKG_NAME="musl"
PKG_VERSION="1.2.5"

# Tarball oficial do musl
PKG_URLS=(
  "https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"
)

# Opcional: SHA256 do tarball (recomendável preencher com o valor real)
# PKG_SHA256S=(
#   "a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"
# )

# Patches de segurança:
#   Coloque arquivos *.patch em:
#     packages/system/musl/patches/
#   O adm.sh deve aplicar esses patches após o extract do tarball.

# Dependências lógicas dentro do ADM:
#   - binutils final (para o triplet musl)
#   - gcc final (para o triplet musl)
#   - linux-api-headers
PKG_DEPENDS=(
  "toolchain/binutils"
  "toolchain/gcc"
  "toolchain/linux-api-headers"
)

###############################################################################
# Triplet alvo para musl
###############################################################################
# Assumimos que o perfil -P musl já definiu ADM_TARGET_TRIPLET como, por ex.:
#   x86_64-linux-musl
# Caso não tenha vindo, caímos em um default seguro.

PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-linux-musl}}"

###############################################################################
# Configure / Build / Install customizados
###############################################################################
# musl não usa autotools; o configure próprio aceita:
#   --prefix, --syslibdir, --host (== target), CROSS_COMPILE, CC, CFLAGS, etc.
#
# Aqui fazemos build out-of-tree em subdir "build", usando:
#   CC=${PKG_TARGET_TRIPLET}-gcc     (toolchain musl)
#   CROSS_COMPILE=${PKG_TARGET_TRIPLET}-
# e instalando em /usr + /lib dentro do ROOTFS (via DESTDIR).

# CONFIGURE
PKG_CONFIGURE_CMD='
  set -e

  # Estamos em ${build_dir} (raiz do source do musl) neste contexto.
  mkdir -p build
  cd build

  HOST_TRIPLET="${PKG_TARGET_TRIPLET:-${TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-linux-musl}}"
  SYSROOT="${ADM_ROOTFS:-/opt/adm/rootfs}"

  echo "[musl-final/configure] HOST_TRIPLET=${HOST_TRIPLET}"
  echo "[musl-final/configure] SYSROOT=${SYSROOT}"

  # Usa o compilador do toolchain musl (final ou “estável”)
  CC="${HOST_TRIPLET}-gcc"
  CROSS_COMPILE="${HOST_TRIPLET}-"

  # CFLAGS padrão; ajustável via PKG_MUSL_CFLAGS se necessário
  CFLAGS="${PKG_MUSL_CFLAGS:--O2 -pipe}"

  export CC CROSS_COMPILE CFLAGS

  ../configure \
    --prefix=/usr \
    --host="${HOST_TRIPLET}" \
    --syslibdir=/lib
'

# BUILD
PKG_BUILD_CMD='
  set -e
  cd build

  echo "[musl-final/build] Compilando musl ${PKG_VERSION} (final)..."
  make -j"${ADM_JOBS:-$(nproc)}"
'

# INSTALL
PKG_INSTALL_CMD='
  set -e
  cd build

  echo "[musl-final/install] Instalando musl ${PKG_VERSION} (final) em ${destdir}..."
  make DESTDIR="${destdir}" install
'
