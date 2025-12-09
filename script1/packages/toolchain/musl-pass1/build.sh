#!/usr/bin/env bash
# Receita ADM para musl 1.2.5 - Pass 1 (libc principal do perfil musl)
#
# Este passo constrói e instala o musl no ROOTFS do perfil -P musl, usando:
#   - Binutils/GCC pass1 em /tools (TARGET=*-linux-musl)
#   - Linux API headers já instalados em ${ADM_ROOTFS}/usr/include
#
# Patches de segurança:
#   Coloque arquivos *.patch em:
#     packages/.../system/musl-pass1/patches/
#   O adm.sh (via extract_source) aplica todos os patches antes do build.

###############################################################################
# Metadados básicos do pacote
###############################################################################

PKG_NAME="musl-pass1"
PKG_VERSION="1.2.5"

# Tarball oficial do musl
PKG_URLS=(
  "https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"
)

# Opcional: SHA256 do tarball (recomendável preencher com o valor real)
# PKG_SHA256S=(
#   "a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"
# )

# Dependências lógicas dentro do ADM:
#   - Toolchain temporário em /tools (binutils/gcc pass1 para musl)
#   - Linux API headers já instalados no ROOTFS
PKG_DEPENDS=(
  "toolchain/binutils-pass1"
  "toolchain/gcc-pass1"
  "system/linux-api-headers"
)

###############################################################################
# Triplet alvo para musl
###############################################################################
# Padrão comum: x86_64-linux-musl, aarch64-linux-musl, etc.
# Se você exportar PKG_TARGET_TRIPLET antes de rodar o ADM, ele prevalece.

PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-linux-musl}"

###############################################################################
# Configure / Build / Install customizados
###############################################################################
# musl não usa autotools padrão; o configure próprio aceita:
#   --prefix, --syslibdir, --host (== target), CROSS_COMPILE, CC, etc.
#
# Aqui fazemos um build out-of-tree em subdir "build", usando:
#   CC=${PKG_TARGET_TRIPLET}-gcc em /tools
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

  echo "[musl-pass1/configure] HOST_TRIPLET=${HOST_TRIPLET}"
  echo "[musl-pass1/configure] SYSROOT=${SYSROOT}"

  # Usa o cross-compiler do toolchain em /tools:
  CC="${HOST_TRIPLET}-gcc"
  CROSS_COMPILE="${HOST_TRIPLET}-"

  # CFLAGS moderados; pode ajustar via PKG_MUSL_CFLAGS se quiser.
  CFLAGS="${PKG_MUSL_CFLAGS:--Os -pipe}"

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

  echo "[musl-pass1/build] Compilando musl 1.2.5 (Pass 1)..."
  make -j"${ADM_JOBS:-$(nproc)}"
'

# INSTALL
PKG_INSTALL_CMD='
  set -e
  cd build

  echo "[musl-pass1/install] Instalando musl 1.2.5 (Pass 1) em ${destdir}..."
  make DESTDIR="${destdir}" install
'
