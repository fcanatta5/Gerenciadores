#!/usr/bin/env bash
# Receita ADM para GNU M4 1.4.20 (ferramenta de macro processamento)
#
# Este pacote é neutro em relação à libc:
#   - Funciona tanto com glibc quanto com musl.
#   - O que muda é somente o perfil do ADM (-P glibc / -P musl),
#     que define TARGET_TRIPLET, ROOTFS, etc.

###############################################################################
# Metadados básicos do pacote
###############################################################################

PKG_NAME="m4"
PKG_VERSION="1.4.20"

# Tarball oficial do GNU M4
PKG_URLS=(
  "https://ftp.gnu.org/gnu/m4/m4-${PKG_VERSION}.tar.xz"
)

# Opcional: SHA256 do tarball (recomendável preencher com o valor real)
# PKG_SHA256S=(
#   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# )

# Dependências lógicas dentro do ADM:
#   - GCC final em /usr (toolchain estável)
PKG_DEPENDS=(
  "toolchain/gcc"
)

###############################################################################
# Triplet alvo
###############################################################################
# Usa o triplet definido pelo perfil:
#   -P glibc -> ADM_TARGET_TRIPLET=x86_64-lfs-linux-gnu (por exemplo)
#   -P musl  -> ADM_TARGET_TRIPLET=x86_64-linux-musl
#
# Se PKG_TARGET_TRIPLET for exportado antes da chamada, ele prevalece.

PKG_TARGET_TRIPLET="${PKG_TARGET_TRIPLET:-${ADM_TARGET_TRIPLET}}"

###############################################################################
# Opções de configure / build / install
###############################################################################
# O adm.sh monta algo como:
#
#   ./configure \
#     --host="${TARGET_TRIPLET}" \
#     --build="${TARGET_TRIPLET}" \
#     --prefix=/usr \
#     --sysconfdir=/etc \
#     --localstatedir=/var \
#     "${PKG_CONFIGURE_OPTS[@]}"
#
# Para o M4 final, podemos usar um configure bem simples. Se quiser tunar
# (ex.: desativar NLS), use PKG_CONFIGURE_OPTS.

PKG_CONFIGURE_OPTS=(
  # Exemplo: desativar NLS para reduzir dependências
  "--disable-nls"
)

# BUILD:
#   O adm.sh fará: make -j"${ADM_JOBS:-$(nproc)}" "${PKG_MAKE_OPTS[@]}"
#   No M4 não precisamos de nada especial.
# PKG_MAKE_OPTS=()

# INSTALL:
#   O adm.sh fará: make DESTDIR="${destdir}" install "${PKG_MAKE_INSTALL_OPTS[@]}"
#   Também não precisamos de ajustes especiais aqui.
# PKG_MAKE_INSTALL_OPTS=()
