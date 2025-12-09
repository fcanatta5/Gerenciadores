#!/usr/bin/env bash
# Receita ADM para Linux 6.17.9 - API Headers

###############################################################################
# Metadados básicos do pacote
###############################################################################

PKG_NAME="linux-api-headers"
PKG_VERSION="6.17.9"

# Tarball oficial do kernel (ajuste se usar mirror diferente)
PKG_URLS=(
  "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
)

# Opcional: SHA256 do tarball (recomendado preencher com o valor real)
# PKG_SHA256S=(
#   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# )

# Dependências lógicas dentro do ADM (mínimo: toolchain para compilar headers)
PKG_DEPENDS=(
  "toolchain/binutils-pass1"
  "toolchain/gcc-pass1"
)

###############################################################################
# Triplet alvo (para coerência com o restante do toolchain)
###############################################################################

# PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu}"
PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_TRIPLET}}"

###############################################################################
# Fases customizadas (kernel não usa ./configure padrão)
###############################################################################
# O adm.sh tem suporte a:
#   - PKG_CONFIGURE_CMD
#   - PKG_BUILD_CMD
#   - PKG_INSTALL_CMD
#
# Para os API Headers:
#   - Não há fase configure -> usamos ":" (no-op).
#   - BUILD: "make mrproper" com ARCH adequado.
#   - INSTALL: "make headers_install INSTALL_HDR_PATH=${destdir}/usr"

# Não há configure para o kernel, então no-op.
PKG_CONFIGURE_CMD=":"

# BUILD: limpeza da árvore de fontes (mrproper)
PKG_BUILD_CMD='
  KARCH="${PKG_KARCH:-${ADM_KERNEL_ARCH:-${ADM_TARGET_ARCH:-x86_64}}}"
  echo "[linux-api-headers/build] Fazendo mrproper (ARCH=${KARCH})..."
  make ARCH="${KARCH}" mrproper
'

# INSTALL: instalação dos headers saneados em DESTDIR/usr/include
PKG_INSTALL_CMD='
  KARCH="${PKG_KARCH:-${ADM_KERNEL_ARCH:-${ADM_TARGET_ARCH:-x86_64}}}"
  echo "[linux-api-headers/install] Instalando headers (ARCH=${KARCH}) em ${destdir}/usr..."
  make ARCH="${KARCH}" headers_install INSTALL_HDR_PATH="${destdir}/usr"
'
