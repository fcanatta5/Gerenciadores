#!/usr/bin/env bash
# toolchain/glibc-pass1/glibc-pass1.sh
# Glibc-2.40 - Pass 1 (instalada em ${ADM_ROOTFS}/usr usando toolchain temporário em /tools)

# NÃO usar set -euo aqui: o próprio adm.sh já controla isso.

PKG_NAME="glibc-pass1"
PKG_VERSION="2.40"
PKG_CATEGORY="toolchain"

# Fonte oficial (poderia ser ajustado para 2.41/2.42 se você quiser seguir mais novo)
PKG_URL="https://ftp.gnu.org/gnu/glibc/glibc-2.40.tar.xz"

# Opcional: você pode preencher depois com o SHA256 real, se quiser verificar integridade.
# Se deixar vazio, o ADM apenas vai avisar que não há checksum.
# PKG_SHA256=""

# Dependências mínimas: precisa de binutils-pass1 + gcc-pass1 já instalados em /tools
PKG_DEPENDS=(
  "toolchain/binutils-pass1"
  "toolchain/gcc-pass1"
)

###############################################################################
# Validação de perfil / arquitetura e definição do triplet
###############################################################################

_adm_profile="${ADM_PROFILE:-glibc}"
_adm_arch="${ADM_TARGET_ARCH:-x86_64}"

case "${_adm_profile}" in
  glibc|aggressive)
    # perfis baseados em glibc – OK
    ;;
  *)
    echo "glibc-pass1: este pacote só é válido para perfis baseados em glibc (glibc/aggressive)." >&2
    echo "Perfil atual: '${_adm_profile}'" >&2
    exit 1
    ;;
esac

# Mapeamento alinhado com o que você já usa para gcc/binutils pass1
case "${_adm_arch}" in
  x86_64)
    GLIBC_PASS1_TARGET_TRIPLET="x86_64-linux-gnu"
    ;;
  aarch64)
    GLIBC_PASS1_TARGET_TRIPLET="aarch64-linux-gnu"
    ;;
  *)
    # Fallback genérico – ajuste se suportar mais arches
    GLIBC_PASS1_TARGET_TRIPLET="${_adm_arch}-linux-gnu"
    ;;
esac

# O adm vai usar esse triplet para --host/--target, etc.
PKG_TARGET_TRIPLET="${GLIBC_PASS1_TARGET_TRIPLET}"

###############################################################################
# Opções de configuração (baseado no LFS 12.2, capítulo 5.5 Glibc-2.40)
#
# Em LFS, o configure é usado assim:
#   ../configure --prefix=/usr                      \
#                --host=$LFS_TGT                    \
#                --build=$(../scripts/config.guess) \
#                --enable-kernel=4.19               \
#                --with-headers=$LFS/usr/include    \
#                --disable-nscd                     \
#                libc_cv_slibdir=/usr/lib
#
# No ADM:
#   - --host / --build vêm de ADM_CONFIGURE_ARGS_COMMON
#   - DESTDIR é ${ADM_ROOTFS}, então o prefix real será ${ADM_ROOTFS}/usr
###############################################################################

PKG_CONFIGURE_OPTS=(
  "--prefix=/usr"
  "--enable-kernel=4.19"
  "--with-headers=${ADM_ROOTFS}/usr/include"
  "--disable-nscd"
  "libc_cv_slibdir=/usr/lib"
  "--disable-werror"
)

# Opcional: tunar flags extras – o ADM já define CFLAGS/CXXFLAGS globais.
PKG_CFLAGS_EXTRA="-O2 -pipe"
PKG_LDFLAGS_EXTRA=""

# Normalmente glibc Pass 1 não precisa de opções especiais de make/make install
PKG_MAKE_OPTS=()
PKG_MAKE_INSTALL_OPTS=()
