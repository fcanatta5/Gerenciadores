#!/usr/bin/env bash
# Receita ADM para Glibc 2.42 - Pass 1 (toolchain inicial, instala em /usr dentro do rootfs)

PKG_NAME="glibc-pass1"
PKG_VERSION="2.42"

# Ajuste a URL e checksum se necessário (padrão GNU libc)
PKG_URLS=(
  "https://ftp.gnu.org/gnu/libc/glibc-${PKG_VERSION}.tar.xz"
)

# Coloque o SHA256 real que você for usar (placeholder aqui):
# PKG_SHA256S=(
#   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# )

# Dependências lógicas para o Pass 1
PKG_DEPENDS=(
  "toolchain/linux-headers"   # API headers já instalados no rootfs
  "toolchain/binutils-pass1"  # binutils em /tools
  "toolchain/gcc-pass1"       # gcc em /tools
)

# Se você quiser fixar explicitamente o triplet “alvo” da glibc pass1,
# pode descomentar algo como:
# PKG_TARGET_TRIPLET="x86_64-lfs-linux-gnu"

# IMPORTANTE:
# O adm.sh já monta CONFIGURE_ARGS_COMMON com:
#   --host=${TARGET_TRIPLET}
#   --build=${TARGET_TRIPLET}
#   --prefix=/usr
#   --sysconfdir=/etc
#   --localstatedir=/var
#
# Aqui colocamos APENAS as opções específicas da Glibc, sem repetir host/build/prefix.

PKG_CONFIGURE_OPTS=(
  "--disable-werror"
  "--enable-kernel=4.19"
  "--enable-stack-protector=strong"
  "--with-headers=${ADM_ROOTFS:-/opt/adm/rootfs}/usr/include"
  "libc_cv_slibdir=/usr/lib"
)

# Opcionalmente, flags extras (o adm acrescenta isso em CFLAGS/LDFLAGS)
# PKG_CFLAGS_EXTRA="-O2"
# PKG_LDFLAGS_EXTRA=""

# MAKE padrão:
#   (cd "$build_dir" && make -j$(nproc) ${PKG_MAKE_OPTS[@]})
# Para Glibc Pass 1 normalmente não é necessário mexer.
# PKG_MAKE_OPTS=()

# INSTALL padrão:
#   (cd "$build_dir" && make DESTDIR="${destdir}" install ${PKG_MAKE_INSTALL_OPTS[@]})
# Glibc suporta DESTDIR bem, então não precisamos customizar.
# PKG_MAKE_INSTALL_OPTS=()
