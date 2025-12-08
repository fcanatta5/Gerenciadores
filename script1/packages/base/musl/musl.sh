#!/usr/bin/env bash
# toolchain/musl/musl.sh
# musl-1.2.5 + patches de segurança (CVE-2025-26519) para perfil musl do ADM

PKG_NAME="musl"
PKG_VERSION="1.2.5"
PKG_CATEGORY="toolchain"

# Tarball oficial do musl
PKG_URLS=(
  "https://musl.libc.org/releases/musl-1.2.5.tar.gz"

  # Patches de segurança (iconv EUC-KR → UTF-8) da Bootlin,
  # equivalentes ao commit upstream que corrige CVE-2025-26519.
  "https://toolchains.bootlin.com/downloads/releases/sources/musl-1.2.5/0004-iconv-fix-erroneous-input-validation-in-EUC-KR-decod.patch"
  "https://toolchains.bootlin.com/downloads/releases/sources/musl-1.2.5/0005-iconv-harden-UTF-8-output-code-path-against-input-de.patch"
)

# SHA256 apenas do tarball principal (os patches podem mudar; se quiser,
# você pode preencher depois os checksums dos patches também).
PKG_SHA256S=(
  "a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"
  ""
  ""
)

# Dependências lógicas: precisa de headers de kernel antes de construir a libc
PKG_DEPENDS=(
  "toolchain/linux-headers"
)

###############################################################################
# Validação de perfil / arquitetura e definição do triplet
###############################################################################

_adm_profile="${ADM_PROFILE:-musl}"
_adm_arch="${ADM_TARGET_ARCH:-x86_64}"

case "${_adm_profile}" in
  musl|aggressive)
    ADM_TARGET_LIBC_EFFECTIVE="musl"
    ;;
  *)
    echo "musl: este pacote só é válido para perfis baseados em musl (musl/aggressive)." >&2
    echo "Perfil atual: '${_adm_profile}'" >&2
    exit 1
    ;;
esac

# Mapeamento de arch -> triplet musl
case "${_adm_arch}" in
  x86_64)
    MUSL_TARGET_TRIPLET="x86_64-linux-musl"
    ;;
  aarch64)
    MUSL_TARGET_TRIPLET="aarch64-linux-musl"
    ;;
  riscv64)
    MUSL_TARGET_TRIPLET="riscv64-linux-musl"
    ;;
  armv7l|armv7hf)
    MUSL_TARGET_TRIPLET="armv7l-linux-musleabihf"
    ;;
  *)
    # Fallback genérico – ajuste se suportar mais arches
    MUSL_TARGET_TRIPLET="${_adm_arch}-linux-musl"
    ;;
esac

# Força o adm a usar esse triplet na configuração
PKG_TARGET_TRIPLET="${MUSL_TARGET_TRIPLET}"

###############################################################################
# Opções de configuração do musl
#
# Recomendado para sistema "root" com musl:
#   --prefix=/usr      → headers em /usr/include
#   --syslibdir=/lib   → ld-musl-*.so.1 e libc.so em /lib
###############################################################################

PKG_CONFIGURE_OPTS=(
  "--prefix=/usr"
  "--syslibdir=/lib"
  "--target=${MUSL_TARGET_TRIPLET}"
)

# Flags extras (opcional, o ADM já define CFLAGS globais)
PKG_CFLAGS_EXTRA="-O2 -pipe"
PKG_LDFLAGS_EXTRA=""

PKG_MAKE_OPTS=()
PKG_MAKE_INSTALL_OPTS=()
