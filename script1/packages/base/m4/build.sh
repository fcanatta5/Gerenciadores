#!/usr/bin/env bash
# Receita ADM para GNU M4 1.4.20

# Metadados básicos
PKG_NAME="m4"
PKG_VERSION="1.4.20"

# Fonte oficial + checksum
PKG_URLS=(
  "https://ftp.gnu.org/gnu/m4/m4-1.4.20.tar.xz"
)
PKG_SHA256S=(
  "e236ea3a1ccf5f6c270b1c4bb60726f371fa49459a8eaaebc90b216b328daf2b"
)

# Dependências de runtime/build (ajuste para a sua árvore de pacotes)
# Ex.: se você tiver pacotes core/gcc, core/glibc, etc., liste aqui.
PKG_DEPENDS=(
  # "core/gcc"
  # "core/glibc"
)

# Opções extras de configure/make, se necessário
# (o adm.sh já passa: --host, --build, --prefix=/usr, --sysconfdir=/etc, --localstatedir=/var)
PKG_CONFIGURE_OPTS=(
  "--disable-dependency-tracking"
)

# Se quiser algo extra de compilação:
# PKG_CFLAGS_EXTRA=""
# PKG_LDFLAGS_EXTRA=""

# Caso precise alterar flags do make:
# PKG_MAKE_OPTS=()
# PKG_MAKE_INSTALL_OPTS=()

# NOTA:
#  - Não precisamos definir nenhuma função especial de build.
#  - O adm.sh vai fazer automaticamente:
#       ./configure (com argumentos acima)
#       make -jN
#       make DESTDIR=... install
#
# Se um dia precisar de build custom, você pode:
#   - usar hooks (pre_build, pre_install, post_install), ou
#   - estender o adm.sh para suportar uma função tipo PKG_BUILD_FUNC.
