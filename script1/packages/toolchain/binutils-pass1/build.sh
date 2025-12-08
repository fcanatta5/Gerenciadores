#!/usr/bin/env bash
# Receita ADM para GNU Binutils 2.45.1 - Pass 1 (toolchain inicial em /tools)

PKG_NAME="binutils-pass1"
PKG_VERSION="2.45.1"

# Fonte oficial (ajuste se preferir outro mirror)
PKG_URLS=(
  "https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
)

# SHA256 opcional (preencha com o valor que você quiser validar de fato)
# Exemplo (pode não ser o definitivo, confirme no espelho que for usar):
# PKG_SHA256S=(
#   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# )

# Dependências diretas (ajuste conforme sua árvore)
PKG_DEPENDS=(
  # "core/gcc-native"
  # "core/linux-headers"
)

# IMPORTANTE:
# - O adm.sh já passa:
#     --host=...
#     --build=...
#     --prefix=/usr
#     --sysconfdir=/etc
#     --localstatedir=/var
#   via ADM_CONFIGURE_ARGS_COMMON.
#
# - Aqui só colocamos opções específicas deste pacote.
# - NÃO usamos TARGET_TRIPLET aqui porque ele ainda não existe no momento do
#   source do build.sh. Se você quiser um cross de verdade, pode:
#   - definir PKG_TARGET_TRIPLET="x86_64-lfs-linux-gnu" (por exemplo), e
#   - adicionar manualmente um "--target=SEU_TRIPLET" fixo em PKG_CONFIGURE_OPTS.
#   Mas isso é uma decisão de layout da sua toolchain.

PKG_CONFIGURE_OPTS=(
  "--prefix=/tools"              # Isola binutils Pass 1 em /tools
  "--disable-nls"
  "--disable-werror"
  "--disable-gprofng"
  "--disable-gdb"
  "--disable-gdbserver"
  "--disable-gold"
  "--disable-libquadmath"
  "--disable-libssp"
  "--disable-libvtv"
  "--disable-multilib"
  "--disable-plugins"
  "--enable-deterministic-archives"
)

# MAKE padrão do adm:
#   make -j$(nproc) ${PKG_MAKE_OPTS[@]}
# Para Pass 1 geralmente não precisa de nada especial aqui.
# Se quiser algo extra, descomente:
# PKG_MAKE_OPTS=(
#   # opções extras de make, se precisar
# )

# Fase install padrão do adm:
#   make ${PKG_MAKE_INSTALL_OPTS[@]} DESTDIR="${destdir}" install
# Para binutils Pass 1, "make install" simples em DESTDIR já funciona bem,
# então deixamos PKG_MAKE_INSTALL_OPTS vazio.
# Se precisar de ajustes (por ex. lib-path custom), coloque aqui:
# PKG_MAKE_INSTALL_OPTS=(
#   # opções extras de make para a instalação
# )
