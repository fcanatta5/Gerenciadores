#!/usr/bin/env bash
# Receita ADM para GCC 15.2.0 - Pass 1 (toolchain inicial em /tools)

PKG_NAME="gcc-pass1"
PKG_VERSION="15.2.0"

PKG_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
)

# SHA256 opcional (confirme com o mirror que você usar)
# PKG_SHA256S=(
#   "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy"
# )

# Dependências típicas:
PKG_DEPENDS=(
  "core/binutils-pass1"
  # "core/linux-headers"
  # "core/glibc-headers"
)

# OBS IMPORTANTES:
# - O adm.sh já monta ADM_CONFIGURE_ARGS_COMMON com:
#     --host=...
#     --build=...
#     --prefix=/usr
#     --sysconfdir=/etc
#     --localstatedir=/var
# - Aqui só colocamos as opções específicas do GCC Pass 1.
# - NÃO vamos usar TARGET_TRIPLET diretamente aqui, pelo mesmo motivo do binutils
#   (não está definido no momento do source).
#
# Caso você queira um cross de verdade, pode:
#   - definir PKG_TARGET_TRIPLET="x86_64-lfs-linux-gnu" (por exemplo), e
#   - editar PKG_CONFIGURE_OPTS para adicionar um "--target=SEU_TRIPLET" fixo.

PKG_CONFIGURE_OPTS=(
  "--prefix=/tools"          # Prefix temporário para Pass 1
  "--without-headers"
  "--with-newlib"
  "--disable-nls"
  "--disable-shared"
  "--disable-multilib"
  "--disable-decimal-float"
  "--disable-libatomic"
  "--disable-libgomp"
  "--disable-libquadmath"
  "--disable-libssp"
  "--disable-libvtv"
  "--disable-libstdcxx"
  "--enable-languages=c"
)

# Se quiser, você pode adicionar flags extras:
# PKG_CFLAGS_EXTRA="-O2"
# PKG_LDFLAGS_EXTRA=""

# MAKE padrão:
#   make -j$(nproc) ${PKG_MAKE_OPTS[@]}
# Em Pass 1, normalmente não precisa de nada especial aqui.
# PKG_MAKE_OPTS=()

# INSTALL padrão:
#   make ${PKG_MAKE_INSTALL_OPTS[@]} DESTDIR="${destdir}" install
# Para GCC Pass 1, em muitos cenários basta "make install". Se você quiser
# algo mais fino (por exemplo, instalar só certas partes), pode customizar:
# PKG_MAKE_INSTALL_OPTS=(
#   # opções extras de make install, se necessário
# )
