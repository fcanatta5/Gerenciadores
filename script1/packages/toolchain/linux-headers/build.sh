#!/usr/bin/env bash
# Receita ADM para Linux API Headers 6.17.9

PKG_NAME="linux-headers"
PKG_VERSION="6.17.9"

PKG_URLS=(
  "https://www.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
)

# Coloque o checksum real quando desejar validar
# PKG_SHA256S=(
#   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# )

PKG_DEPENDS=()

# Kernel NÃO usa ./configure
PKG_CONFIGURE_OPTS=()

# Somente as fases válidas:
PKG_MAKE_OPTS=(
  "mrproper"
)

# ⚠️ MUITO IMPORTANTE:
# Não permitir que o adm rode:
#   make install
# A instalação real será feita via HOOK.
PKG_MAKE_INSTALL_OPTS=()
