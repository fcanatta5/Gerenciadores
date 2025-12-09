#!/usr/bin/env bash
# Receita ADM para GCC 15.2.0 - Pass 1 (toolchain inicial em /tools)

###############################################################################
# Metadados básicos do pacote
###############################################################################

PKG_NAME="gcc-pass1"
PKG_VERSION="15.2.0"

# Versões dos pré-requisitos internos do GCC
GMP_VERSION="6.3.0"
MPFR_VERSION="4.2.1"
MPC_VERSION="1.3.1"

# Fontes principais:
#  - GCC
#  - GMP, MPFR, MPC (usados como "in-tree builds" via hook pre_build)
PKG_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VERSION}.tar.xz"
  "https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VERSION}.tar.xz"
  "https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VERSION}.tar.gz"
)

# Opcional: checksums. Preencha se quiser validação estrita.
# PKG_SHA256S=(
#   "sha256-gcc-15.2.0..."
#   "sha256-gmp-6.3.0..."
#   "sha256-mpfr-4.2.1..."
#   "sha256-mpc-1.3.1..."
# )

# Dependências lógicas dentro do ADM. Tipicamente:
#   - binutils-pass1 (já instalado em /tools)
PKG_DEPENDS=(
  "toolchain/binutils-pass1"
)

###############################################################################
# Triplet alvo específico do toolchain Pass 1
###############################################################################
# O adm.sh faz:
#   - se PKG_TARGET_TRIPLET estiver definido, copia para TARGET_TRIPLET
#   - setup_profiles() usa TARGET_TRIPLET em --host/--build
#
# Aqui definimos um padrão estilo LFS. Se você já exportar
# PKG_TARGET_TRIPLET no ambiente antes de rodar o ADM, ele prevalece.

PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_ARCH:-x86_64}-lfs-linux-gnu}"

###############################################################################
# Opções de configure
###############################################################################
# O adm.sh monta:
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
# o GCC Pass 1 seja instalado em /tools dentro do ROOTFS.
#
# A ideia do Pass 1 é:
#   - cross/“quase-cross” para ${PKG_TARGET_TRIPLET}
#   - sem headers de libc (sem glibc plena ainda)
#   - build mínimo: compilador + libgcc
#
# OBS: o hook pre_build é quem injeta gmp/mpfr/mpc dentro da árvore do GCC.

PKG_CONFIGURE_OPTS=(
  # Override de prefix padrão do adm.sh para /tools
  "--prefix=/tools"

  # Target explícito do GCC (podendo ser igual ao TARGET_TRIPLET)
  "--target=${PKG_TARGET_TRIPLET}"

  # Usa o rootfs atual como sysroot do GCC
  "--with-sysroot=${ADM_ROOTFS:-/opt/adm/rootfs}"

  # Caminhos típicos do ambiente /tools
  "--with-local-prefix=/tools"
  "--with-native-system-header-dir=/tools/include"

  # Configuração Pass 1 (sem headers de libc)
  "--without-headers"
  "--with-newlib"

  # Segurança e defaults modernos
  "--enable-default-pie"
  "--enable-default-ssp"

  # Desabilita tudo o que depende mais fortemente de libc
  "--disable-nls"
  "--disable-shared"
  "--disable-multilib"
  "--disable-threads"
  "--disable-libatomic"
  "--disable-libgomp"
  "--disable-libquadmath"
  "--disable-libquadmath-support"
  "--disable-libsanitizer"
  "--disable-libssp"
  "--disable-libvtv"
  "--disable-libstdcxx"

  # Linguagens necessárias para o resto da toolchain
  "--enable-languages=c,c++"
)

###############################################################################
# Opções de build (make)
###############################################################################
# O adm.sh vai chamar:
#   make -j"${jobs}" "${PKG_MAKE_OPTS[@]}"
#
# Para o Pass 1 queremos o build mínimo:
#   - all-gcc            (compilador em si)
#   - all-target-libgcc  (libgcc para o target)
#
# Isso evita tentar construir libs que exigem libc completa.

PKG_MAKE_OPTS=(
  "all-gcc"
  "all-target-libgcc"
)

###############################################################################
# Opções de instalação (make install)
###############################################################################
# O adm.sh chama:
#   make DESTDIR="${destdir}" install "${PKG_MAKE_INSTALL_OPTS[@]}"
#
# Para o Pass 1 queremos só instalar:
#   - install-gcc
#   - install-target-libgcc
#
# Então deixamos:
#   DESTDIR=... install install-gcc install-target-libgcc
# Na prática, "install" não deve falhar pois a configuração acima limita
# o que é construído; porém os alvos específicos garantem que gcc e libgcc
# sejam instalados mesmo que a lógica de "install" mude em releases futuros.

PKG_MAKE_INSTALL_OPTS=(
  "install-gcc"
  "install-target-libgcc"
)
