#!/usr/bin/env bash
# toolchain/glibc/glibc.sh
# Glibc-2.42 (libc final) para o ADM

PKG_NAME="glibc"
PKG_VERSION="2.42"
PKG_CATEGORY="toolchain"

# Fonte oficial
PKG_URL="https://ftp.gnu.org/gnu/libc/glibc-2.42.tar.xz"
PKG_SHA256="69c1e915c8edd75981cbfc6b7654e8fc4e52a48d06b9f706f463492749a9b6fb"

# Dependências lógicas para a fase final:
#  - headers de kernel
#  - binutils final
#  - gcc final
PKG_DEPENDS=(
  "toolchain/linux-headers"
  "toolchain/binutils"
  "toolchain/gcc-15.2.0"
)

###############################################################################
# Perfil / arquitetura -> triplet alvo
###############################################################################

_adm_profile="${ADM_PROFILE:-glibc}"
_adm_arch="${ADM_TARGET_ARCH:-x86_64}"

case "${_adm_profile}" in
  glibc|aggressive)
    # OK – perfis baseados em glibc
    ;;
  *)
    echo "glibc: este pacote só é válido para perfis baseados em glibc (glibc/aggressive)." >&2
    echo "Perfil atual: '${_adm_profile}'" >&2
    exit 1
    ;;
esac

case "${_adm_arch}" in
  x86_64)
    GLIBC_TARGET_TRIPLET="x86_64-linux-gnu"
    ;;
  aarch64)
    GLIBC_TARGET_TRIPLET="aarch64-linux-gnu"
    ;;
  riscv64)
    GLIBC_TARGET_TRIPLET="riscv64-linux-gnu"
    ;;
  *)
    # fallback genérico – ajuste se suportar mais arches
    GLIBC_TARGET_TRIPLET="${_adm_arch}-linux-gnu"
    ;;
esac

# Diz ao adm que este pacote é para esse triplet.
PKG_TARGET_TRIPLET="${GLIBC_TARGET_TRIPLET}"

###############################################################################
# Opções de configuração (modelo LFS glibc final adaptado ao ADM)
#
# - --prefix=/usr           → libs principais em /usr/lib, bins em /usr/bin
# - --enable-kernel=4.19    → mínima versão de kernel suportada
# - --enable-stack-protector=strong
# - --with-headers=$ADM_ROOTFS/usr/include → usa headers do pacote linux-headers
# - libc_cv_slibdir=/usr/lib → força slibdir em /usr/lib (linker script cuida do resto)
# - --disable-nscd          → nscd opcional, simplifica
# - --disable-werror        → não transformar warnings em erros
###############################################################################

PKG_CONFIGURE_OPTS=(
  "--prefix=/usr"
  "--enable-kernel=4.19"
  "--enable-stack-protector=strong"
  "--with-headers=${ADM_ROOTFS}/usr/include"
  "--disable-nscd"
  "--disable-werror"
  "libc_cv_slibdir=/usr/lib"
)

# Flags extras (o ADM já define CFLAGS/LDFLAGS globais, aqui é só complemento)
PKG_CFLAGS_EXTRA="-O2 -pipe"
PKG_LDFLAGS_EXTRA=""

# Make/make install não precisam de opções especiais para glibc
PKG_MAKE_OPTS=()
PKG_MAKE_INSTALL_OPTS=()
