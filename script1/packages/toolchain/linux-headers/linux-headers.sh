#!/usr/bin/env bash
# toolchain/linux-headers/linux-headers.sh
# Linux-6.17.9 API Headers para o ADM
#
# Resultado final: headers sanitizados em ${ADM_ROOTFS}/usr/include

PKG_NAME="linux-headers"
PKG_VERSION="6.17.9"
PKG_CATEGORY="toolchain"

# Tarball do kernel (ajuste se usar outro mirror/versão)
PKG_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.17.9.tar.xz"

# Opcional: deixe vazio se não tiver o checksum agora
# PKG_SHA256=""

# Em termos de toolchain, o passo de headers só precisa de um compilador/host funcional.
# Se você estiver seguindo o fluxo LFS-like, é natural depender de gcc-pass1:
PKG_DEPENDS=(
  "toolchain/gcc-pass1"
)

###############################################################################
# Perfil / arquitetura
###############################################################################

_adm_profile="${ADM_PROFILE:-glibc}"
_adm_arch="${ADM_TARGET_ARCH:-x86_64}"

# Headers são independentes de glibc/musl, então aceitamos qualquer perfil.
# Mas podemos validar arch para passar ARCH= correto no make.

case "${_adm_arch}" in
  x86_64|aarch64|riscv64|armv7l)
    # Archs comuns – OK
    ;;
  *)
    echo "linux-headers: ADM_TARGET_ARCH='${_adm_arch}' não reconhecido; ajuste a receita se necessário." >&2
    ;;
esac

# Nenhum configure/make especial via PKG_CONFIGURE_OPTS/PKG_MAKE_OPTS:
# nós vamos controlar tudo via hook pre_install criando um Makefile wrapper.
PKG_CONFIGURE_OPTS=()
PKG_MAKE_OPTS=()
PKG_MAKE_INSTALL_OPTS=()

# Não precisamos de CFLAGS/LDFLAGS extras aqui
PKG_CFLAGS_EXTRA=""
PKG_LDFLAGS_EXTRA=""
