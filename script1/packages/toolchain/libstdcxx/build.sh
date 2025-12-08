#!/usr/bin/env bash
# Receita ADM para Libstdc++ (a partir do GCC 15.2.0) - Pass 1

PKG_NAME="libstdcxx-pass1"
PKG_VERSION="15.2.0"

# Usamos o tarball do GCC 15.2.0, mas aqui só nos interessa libstdc++
PKG_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
)

# Preencha o SHA256 real que você for usar (placeholder):
# PKG_SHA256S=(
#   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# )

# Dependências lógicas:
# - GCC pass1 em /tools (para compilar C++)
# - Glibc pass1 já instalada no rootfs
# - Binutils pass1 e headers do kernel
PKG_DEPENDS=(
  "toolchain/binutils-pass1"
  "toolchain/gcc-pass1"
  "toolchain/linux-headers"
  "toolchain/glibc-pass1"
)

# IMPORTANTE:
# O adm.sh já monta ADM_CONFIGURE_ARGS_COMMON com:
#   --host=${TARGET_TRIPLET}
#   --build=${TARGET_TRIPLET}
#   --prefix=/usr
#   --sysconfdir=/etc
#   --localstatedir=/var
#
# Aqui colocamos apenas as opções específicas de libstdc++.
# Não usamos TARGET_TRIPLET diretamente, porque ele só existe depois
# de load_pkg_metadata + setup_profiles (e o build.sh é "sourceado" antes).

PKG_CONFIGURE_OPTS=(
  "--disable-multilib"
  "--disable-nls"
  "--disable-libstdcxx-pch"
  "--enable-languages=c++"
  "--with-system-zlib"
  "--with-sysroot=${ADM_ROOTFS:-/opt/adm/rootfs}"
)

# Opcional: flags extras
# PKG_CFLAGS_EXTRA="-O2"
# PKG_LDFLAGS_EXTRA=""

# Make padrão do adm:
# (cd "$build_dir" && make -jN ${PKG_MAKE_OPTS[@]})
# Não precisamos de opções especiais aqui.
# PKG_MAKE_OPTS=()

# Install padrão do adm:
# (cd "$build_dir" && make DESTDIR="${destdir}" install ${PKG_MAKE_INSTALL_OPTS[@]})
# Para libstdc++, um "make install" completo em DESTDIR funciona.
# PKG_MAKE_INSTALL_OPTS=()
