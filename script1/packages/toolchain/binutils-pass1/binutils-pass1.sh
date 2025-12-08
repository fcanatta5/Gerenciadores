# Binutils-2.45.1 - Pass 1 (Toolchain Temporário em /tools)

PKG_NAME="binutils-pass1"
PKG_VERSION="2.45.1"
PKG_CATEGORY="toolchain"

PKG_URL="https://sourceware.org/pub/binutils/releases/binutils-2.45.1.tar.xz"
PKG_SHA256="5fe101e6fe9d18fdec95962d81ed670fdee5f37e3f48f0bef87bddf862513aa5"

PKG_DEPENDS=()

# -------------------------------------------------------------------------
# Validação de perfil (glibc ou musl)
# -------------------------------------------------------------------------
_adm_profile_effective="${ADM_PROFILE:-glibc}"

case "${_adm_profile_effective}" in
  glibc|musl)
    ;;
  *)
    echo "binutils-pass1: perfil inválido: ${ADM_PROFILE}" >&2
    echo "Use ADM_PROFILE=glibc ou ADM_PROFILE=musl." >&2
    exit 1
    ;;
esac

# -------------------------------------------------------------------------
# CONFIGURAÇÃO ESPECÍFICA DO PASS 1
# -------------------------------------------------------------------------
# Forçamos instalação em /tools, isolando do sistema final
# O ADM ainda usará DESTDIR=${ADM_ROOTFS}

PKG_CONFIGURE_OPTS=(
  "--prefix=/tools"
  "--with-sysroot=${ADM_ROOTFS}"
  "--target=${TARGET_TRIPLET}"
  "--disable-nls"
  "--disable-werror"
  "--enable-gprofng=no"
  "--enable-new-dtags"
  "--enable-default-hash-style=gnu"
)

# Evita que o Pass 1 use headers ou libs do sistema final
PKG_CFLAGS_EXTRA="-ffreestanding -fno-stack-protector"
PKG_LDFLAGS_EXTRA=""
