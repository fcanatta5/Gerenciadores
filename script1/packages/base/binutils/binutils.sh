#!/usr/bin/env bash
# Receita ADM para GNU Binutils 2.45.1 (final, instalado em /usr)

###############################################################################
# Metadados básicos do pacote
###############################################################################

PKG_NAME="binutils"
PKG_VERSION="2.45.1"

# Tarball oficial (ajuste o mirror se quiser)
PKG_URLS=(
  "https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
)

# Opcional: SHA256 do tarball (recomendável preencher com o valor real)
# PKG_SHA256S=(
#   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# )

# Dependências lógicas dentro do ADM:
#   - Toolchain funcional (gcc + glibc) já disponível
# Ajuste conforme a sua árvore de pacotes:
PKG_DEPENDS=(
  "toolchain/gcc-pass1"
  "system/glibc-pass1"
)

###############################################################################
# Triplet alvo do sistema
###############################################################################
# Mantemos o mesmo padrão dos outros pacotes:
#   ${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu
# Se você já exportar PKG_TARGET_TRIPLET, ele prevalece.

PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu}"

###############################################################################
# Opções de configure
###############################################################################
# O adm.sh monta algo como:
#
#   ./configure \
#     --host=${TARGET_TRIPLET} \
#     --build=${TARGET_TRIPLET} \
#     --prefix=/usr \
#     --sysconfdir=/etc \
#     --localstatedir=/var \
#     "${PKG_CONFIGURE_OPTS[@]}"
#
# Aqui usamos /usr mesmo (binutils “definitivo”), com sysroot apontando
# para o ROOTFS, e ativando recursos modernos (plugins, gold, etc.).

PKG_CONFIGURE_OPTS=(
  # Preferimos deixar o prefix padrão do ADM (/usr); não precisamos repetir
  # explicitamente "--prefix=/usr" aqui, mas não há problema se você quiser.

  # Usa o rootfs atual como sysroot (útil em chroot/envs isolados)
  "--with-sysroot=${ADM_ROOTFS:-/opt/adm/rootfs}"

  # Caminhos e recursos adicionais
  "--with-system-zlib"
  "--enable-gold"
  "--enable-ld=default"
  "--enable-plugins"
  "--enable-shared"
  "--enable-64-bit-bfd"
  "--enable-deterministic-archives"

  # Comportamento mais “amistoso”
  "--disable-werror"
)

###############################################################################
# Opções de build (make)
###############################################################################
# O adm.sh chamará:
#   make -j"${ADM_JOBS:-$(nproc)}" "${PKG_MAKE_OPTS[@]}"
#
# Para o binutils final, deixar vazio faz com que todas as ferramentas sejam
# construídas normalmente.

# PKG_MAKE_OPTS=(
#   # opções extras de make, se você quiser
# )

###############################################################################
# Opções de instalação (make install)
###############################################################################
# O adm.sh chamará:
#   make DESTDIR="${destdir}" install "${PKG_MAKE_INSTALL_OPTS[@]}"
#
# Em geral, um "make install" puro é suficiente. Se quiser ajustar algo
# (ex.: não instalar info, ou mover ld.old, etc.), pode acrescentar aqui.

# PKG_MAKE_INSTALL_OPTS=(
#   # opções extras de make para a instalação
# )
