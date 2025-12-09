#!/usr/bin/env bash
# Receita ADM para GNU Binutils 2.45.1 - Pass 1 (toolchain inicial em /tools)

# Nome lógico do pacote dentro do ADM
PKG_NAME="binutils-pass1"

# Versão do binutils
PKG_VERSION="2.45.1"

# Fontes oficiais (ajuste se preferir outro mirror)
PKG_URLS=(
  "https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
)

# Opcional: checksums SHA256 para validação das fontes.
# Preencha com os valores reais do mirror que você for usar.
# Exemplo:
# PKG_SHA256S=(
#   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# )

# Dependências lógicas dentro do ADM (por exemplo: "toolchain-host", "glibc-headers" etc).
# Se este for o primeiro passo do toolchain, pode ficar vazio.
PKG_DEPENDS=(
  # "algum-pacote-base"
)

# Configuração (fase ./configure) padrão do adm.sh:
#   ./configure \
#     <flags globais do ADM> \
#     "${PKG_CONFIGURE_OPTS[@]}"
#
# Para o Pass 1 do binutils em /tools, usamos um configure bem enxuto,
# desativando o máximo de componentes que não são necessários nesta etapa.
PKG_CONFIGURE_OPTS=(
  "--prefix=/tools"
  "--disable-nls"
  "--disable-werror"

  # Desliga ferramentas que não são necessárias no Pass 1
  "--disable-gprofng"
  "--disable-gdb"
  "--disable-gdbserver"
  "--disable-gold"

  # Desliga libs auxiliares que não são críticas nesta fase
  "--disable-libquadmath"
  "--disable-libssp"
  "--disable-libvtv"

  # Outras simplificações
  "--disable-multilib"
  "--disable-plugins"
  "--enable-deterministic-archives"
)

# Se você estiver montando um cross-toolchain completo (estilo LFS),
# pode querer fixar o target aqui. Exemplo:
#
# PKG_TARGET_TRIPLET="x86_64-lfs-linux-gnu"
#
# O adm.sh, ao ver PKG_TARGET_TRIPLET, deve ajustar o TARGET_TRIPLET
# e eventualmente injetar um "--target=${TARGET_TRIPLET}" no configure.
# Deixe comentado se estiver usando somente /tools nativo.

# Fase BUILD padrão do adm.sh:
#   make -j"${ADM_JOBS:-$(nproc)}" "${PKG_MAKE_OPTS[@]}"
#
# Para Pass 1 geralmente não precisa de nada especial.
# Se quiser algo extra, descomente e ajuste:
# PKG_MAKE_OPTS=(
#   # opções extras de make, se precisar
# )

# Fase INSTALL padrão do adm.sh:
#   make "${PKG_MAKE_INSTALL_OPTS[@]}" DESTDIR="${destdir}" install
#
# Para binutils Pass 1, "make install" simples em DESTDIR já funciona bem,
# então deixamos PKG_MAKE_INSTALL_OPTS vazio. Se precisar de ajustes
# (por ex. lib-path custom), coloque aqui:
# PKG_MAKE_INSTALL_OPTS=(
#   # opções extras de make para a instalação
# )
