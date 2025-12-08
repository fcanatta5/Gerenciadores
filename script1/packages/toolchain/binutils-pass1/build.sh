#!/usr/bin/env bash
# Receita ADM para GNU Binutils 2.45.1 - Pass 1 (toolchain inicial)

PKG_NAME="binutils-pass1"
PKG_VERSION="2.45.1"

# Fonte oficial: ajuste se você usa mirror próprio
PKG_URLS=(
  "https://ftp.gnu.org/gnu/binutils/binutils-2.45.1.tar.xz"
)

# SHA256 oficial; confira com o mirror que for usar
# Se quiser, comente temporariamente até você validar.
PKG_SHA256S=(
  "b1426c2d0fb368c1e1f5086f2a8b8894320bf8c1a6c87d12f1f5c7c9a2e0a9f"
)

# Dependências (ajuste de acordo com a sua árvore)
# Para Pass 1, normalmente só precisa de um gcc/host mínimo e libc do host.
PKG_DEPENDS=(
  # "core/gcc-native"
  # "core/glibc-headers"  # se você tiver esse tipo de pacote
)

# Este pacote é especial: ele é um binutils "pass 1".
# Vamos forçar explicitamente o TARGET_TRIPLET, se você quiser.
# Se preferir deixar o adm calcular, comente esta linha.
# Exemplo para um toolchain x86_64-cross:
# PKG_TARGET_TRIPLET="x86_64-lfs-linux-gnu"

# Opções de configure típicas de Binutils Pass 1 (estilo LFS):
#   - prefix /usr (ou /tools se você quiser um prefixo isolado)
#   - disable-nls, disable-werror
#   - sem gold, sem gprofng, sem ld plugins
#
# O adm.sh já passa:
#   --host, --build, --prefix=/usr, --sysconfdir=/etc, --localstatedir=/var
PKG_CONFIGURE_OPTS=(
  "--prefix=/tools"
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

# O Binutils recomenda build em diretório separado (out-of-source).
# O nosso adm já cria ${build_dir} vazio e extrai lá,
# então está consistente com essa prática.

# Se você quiser flags extras específicas para o Pass 1:
# (por exemplo, forçar build estático)
# PKG_CFLAGS_EXTRA="-O2"
# PKG_LDFLAGS_EXTRA="-static"

# Deixe o fluxo padrão do adm:
#   fetch_source → extract_source → ./configure → make → make install.
# Se algum ajuste especial for necessário (por exemplo, usar somente 'ld-new'
# ou renomear bins), isso pode ser feito via hooks (pre_install/post_install).
