#!/usr/bin/env bash
# Receita ADM para GNU Binutils 2.45.1 - Pass 1 (toolchain inicial em /tools)

###############################################################################
# Metadados básicos do pacote
###############################################################################

PKG_NAME="binutils-pass1"
PKG_VERSION="2.45.1"

# Fonte oficial (ajuste se preferir outro mirror)
PKG_URLS=(
  "https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
)

# SHA256 opcional (preencha com o valor real do tarball, se quiser validação)
# Exemplos:
# PKG_SHA256S=(
#   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# )

# Dependências lógicas dentro do ADM (se houver). Para um Pass 1 puro, em geral
# não há dependências além do toolchain/ambiente base.
PKG_DEPENDS=(
  # "algum-pacote-base"
)

###############################################################################
# Triplet alvo específico do toolchain Pass 1
###############################################################################
# O adm.sh faz:
#   - se PKG_TARGET_TRIPLET estiver definido, copia para TARGET_TRIPLET
#   - setup_profiles() usa TARGET_TRIPLET para --host/--build
#
# Aqui definimos um padrão estilo LFS. Se quiser customizar, basta exportar
# PKG_TARGET_TRIPLET antes de chamar o ADM ou editar a linha abaixo.
# PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu}"
PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_TRIPLET}}"

###############################################################################
# Opções de configure
###############################################################################
# O adm.sh vai montar algo assim:
#
#   ./configure \
#     --host=${TARGET_TRIPLET} \
#     --build=${TARGET_TRIPLET} \
#     --prefix=/usr \
#     --sysconfdir=/etc \
#     --localstatedir=/var \
#     "${PKG_CONFIGURE_OPTS[@]}"
#
# Como o último --prefix prevalece, colocamos --prefix=/tools aqui para que
# o binutils Pass 1 seja instalado em /tools dentro do ROOTFS.
#
# ADM_ROOTFS é o "sysroot" do gerenciador; passamos isso para o binutils com
# --with-sysroot=${ADM_ROOTFS} e ajustamos o caminho de libs.

PKG_CONFIGURE_OPTS=(
  # Override de prefix padrão do adm.sh para /tools (toolchain temporário)
  "--prefix=/tools"

  # Usa o rootfs atual como sysroot do binutils
  "--with-sysroot=${ADM_ROOTFS:-/opt/adm/rootfs}"

  # Caminho de libs de /tools (típico do Pass 1)
  "--with-lib-path=/tools/lib"

  # Desativa internacionalização e warnings fatais
  "--disable-nls"
  "--disable-werror"

  # Desliga ferramentas que não são necessárias no Pass 1
  "--disable-gprofng"
  "--disable-gdb"
  "--disable-gdbserver"
  "--disable-gold"

  # Desliga libs auxiliares não necessárias nesta etapa
  "--disable-libquadmath"
  "--disable-libssp"
  "--disable-libvtv"

  # Outras simplificações
  "--disable-multilib"
  "--disable-plugins"
  "--enable-deterministic-archives"
)

###############################################################################
# Opções de build (make)
###############################################################################
# O adm.sh faz algo como:
#
#   jobs = ADM_JOBS ou nproc
#   make -j"${jobs}" "${PKG_MAKE_OPTS[@]}"
#
# Para o Pass 1 normalmente não é necessário nada especial. Se quiser tunar o
# build (por exemplo, desabilitar alguma subdir), adicione aqui.

# PKG_MAKE_OPTS=(
#   # opções extras de make, se precisar
# )

###############################################################################
# Opções de instalação (make install)
###############################################################################
# O adm.sh faz:
#
#   make DESTDIR="${destdir}" install "${PKG_MAKE_INSTALL_OPTS[@]}"
#
# Para o binutils Pass 1 um "make install" simples em DESTDIR já funciona bem.
# Se precisar de ajustes (por ex. instalar apenas binutils sem docs), coloque
# aqui.

# PKG_MAKE_INSTALL_OPTS=(
#   # opções extras de make para a instalação
# )
