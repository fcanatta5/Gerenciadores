#!/usr/bin/env bash
# toolchain/binutils/binutils.sh
# GNU Binutils-2.45.1 - toolchain "final" para o ADM (instala em /usr)

PKG_NAME="binutils"
PKG_VERSION="2.45.1"
PKG_CATEGORY="toolchain"

# Tarball oficial
PKG_URL="https://ftp.gnu.org/gnu/binutils/binutils-2.45.1.tar.xz"
# SHA256 do binutils-2.45.1.tar.xz
PKG_SHA256="5fe101e6fe9d18fdec95962d81ed670fdee5f37e3f48f0bef87bddf862513aa5"

# Dependências lógicas: precisa de um GCC já funcional para o triplet destino.
# Ajuste o nome abaixo para o seu "gcc final" (por exemplo, toolchain/gcc-pass2
# ou o pacote de GCC que você estiver usando).
PKG_DEPENDS=(
  "toolchain/gcc-pass1"
)

###############################################################################
# Detecção de perfil / arquitetura e definição do triplet
###############################################################################

_adm_profile="${ADM_PROFILE:-glibc}"
_adm_arch="${ADM_TARGET_ARCH:-x86_64}"

case "${_adm_profile}" in
  glibc|aggressive|musl)
    ;;
  *)
    echo "binutils: ADM_PROFILE='${_adm_profile}' inválido (esperado: glibc, musl ou aggressive)." >&2
    exit 1
    ;;
esac

# Mapeamento alinhado com o que você já vem usando (glibc vs musl)
case "${_adm_arch}-${_adm_profile}" in
  x86_64-glibc|x86_64-aggressive)
    BINUTILS_TARGET_TRIPLET="x86_64-linux-gnu"
    ;;
  x86_64-musl)
    BINUTILS_TARGET_TRIPLET="x86_64-linux-musl"
    ;;
  aarch64-glibc|aarch64-aggressive)
    BINUTILS_TARGET_TRIPLET="aarch64-linux-gnu"
    ;;
  aarch64-musl)
    BINUTILS_TARGET_TRIPLET="aarch64-linux-musl"
    ;;
  *)
    # fallback genérico, caso você adicione novos perfis/arch no futuro
    BINUTILS_TARGET_TRIPLET="${_adm_arch}-linux-${_adm_profile}"
    ;;
esac

# Diz para o adm que este pacote deve ser construído para este triplet.
# build_and_install_pkg vai:
#   - definir TARGET_TRIPLET="${PKG_TARGET_TRIPLET}"
#   - chamar setup_profiles, que ajusta CC/CFLAGS/PATH/PKG_CONFIG, etc.
PKG_TARGET_TRIPLET="${BINUTILS_TARGET_TRIPLET}"

###############################################################################
# Opções de configuração
#
# Estamos construindo um binutils cruzado (host = sua máquina, target = rootfs),
# instalado em /usr dentro do ${ADM_ROOTFS}, usando o sysroot do ADM.
###############################################################################

PKG_CONFIGURE_OPTS=(
  "--prefix=/usr"
  "--target=${BINUTILS_TARGET_TRIPLET}"
  "--with-sysroot=${ADM_ROOTFS}"
  "--disable-nls"
  "--enable-gold"
  "--enable-ld=default"
  "--enable-plugins"
  "--enable-shared"
  "--enable-64-bit-bfd"
  "--with-system-zlib"
  "--enable-new-dtags"
  "--enable-default-hash-style=gnu"
)

# O ADM já injeta CFLAGS/LDFLAGS globais por perfil; aqui só complementamos se quiser.
PKG_CFLAGS_EXTRA="-O2 -pipe"
PKG_LDFLAGS_EXTRA=""

PKG_MAKE_OPTS=()
PKG_MAKE_INSTALL_OPTS=()
