#!/usr/bin/env bash
# Script de construção do Binutils 2.45.1 para o adm

PKG_NAME="binutils"
PKG_VERSION="2.45.1"

# URLs oficiais (tar.xz)
PKG_URLS=(
  "https://ftp.gnu.org/gnu/binutils/binutils-2.45.1.tar.xz"
  "https://sourceware.org/pub/binutils/releases/binutils-2.45.1.tar.xz"
)

# Checksum oficial (LFS development)
# Fonte: página de packages do LFS (development) com binutils-2.45.1.tar.xz
PKG_MD5="ff59f8dc1431edfa54a257851bea74e7"

# Dependências de runtime/build dentro do sistema alvo
# Usamos zlib do sistema (--with-system-zlib)
PKG_DEPENDS=(
  "core/zlib"
)

# Opções extras de ./configure (as comuns vêm de ADM_CONFIGURE_ARGS_COMMON)
# Baseado em LFS 8.21 Binutils-2.45.1 final 
PKG_CONFIGURE_OPTS=(
  "--enable-ld=default"
  "--enable-plugins"
  "--enable-shared"
  "--disable-werror"
  "--enable-64-bit-bfd"
  "--enable-new-dtags"
  "--with-system-zlib"
  "--enable-default-hash-style=gnu"
)

# make e make install com tooldir=/usr (como LFS)
PKG_MAKE_OPTS=(
  "tooldir=/usr"
)

PKG_MAKE_INSTALL_OPTS=(
  "tooldir=/usr"
)

# Limpeza pós-instalação (rodado dentro do ROOTFS pelo adm)
# Remove libs estáticas e doc do gprofng, como recomendado pelo LFS
PKG_POST_INSTALL_CMDS='
set -e
rm -rfv usr/lib/lib{bfd,ctf,ctf-nobfd,gprofng,opcodes,sframe}.a \
       usr/share/doc/gprofng/
'
