#!/usr/bin/env bash
# Receita do GCC 15.2.0 para o ADM

# Metadados básicos
PKG_NAME="gcc"
PKG_VERSION="15.2.0"
PKG_CATEGORY="base"

# URLs de download (failover)
PKG_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://sourceware.org/pub/gcc/releases/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
)

# Checksums oficiais do tarball .tar.xz
PKG_SHA256="438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e"
PKG_MD5="b861b092bf1af683c46a8aa2e689a6fd"

# Dependências (ajuste para os nomes reais no seu tree)
PKG_DEPENDS=(
  "libs/gmp"
  "libs/mpfr"
  "libs/mpc"
  "libs/isl"
  "core/zlib"
  "toolchain/binutils"
)

# Flags extras específicas do GCC (opcional, o ADM já define CFLAGS/LDFLAGS padrão)
# Exemplo: otimizações adicionais para aggressive
if [[ "${ADM_PROFILE:-glibc}" == "aggressive" ]]; then
  PKG_CFLAGS_EXTRA="-fno-semantic-interposition"
  PKG_LDFLAGS_EXTRA="-Wl,-O2"
fi

# Opções de configure (serão acrescentadas a ADM_CONFIGURE_ARGS_COMMON)
# Baseadas no LFS 12.4 GCC-15.2.0
PKG_CONFIGURE_OPTS=(
  "--enable-languages=c,c++"
  "--enable-default-pie"
  "--enable-default-ssp"
  "--enable-host-pie"
  "--disable-multilib"
  "--disable-bootstrap"
  "--disable-fixincludes"
  "--with-system-zlib"
)

# Opções extras para make (paralelismo, etc.) - o ADM já usa -j$(nproc) por padrão
PKG_MAKE_OPTS=()

# make install (o ADM injeta DESTDIR automaticamente)
PKG_MAKE_INSTALL_OPTS=()

# Pós-instalação dentro do rootfs (rodado pelo ADM em chroot lógico: cd "${ADM_ROOTFS}")
# Aqui entram os passos de pós-instalação e ajustes recomendados pelo LFS.
PKG_POST_INSTALL_CMDS='
set -eu

# Ajustar owner dos headers instalados do GCC
if command -v gcc >/dev/null 2>&1; then
  chown -v -R root:root /usr/lib/gcc/$(gcc -dumpmachine)/'"${PKG_VERSION}"'/include{,-fixed} || true
fi

# Symlink exigido historicamente pelo FHS
ln -svr /usr/bin/cpp /usr/lib || true

# Manpage de cc -> gcc.1
mkdir -pv /usr/share/man/man1
ln -svf gcc.1 /usr/share/man/man1/cc.1 || true

# Plugin LTO para o bfd
mkdir -pv /usr/lib/bfd-plugins
if command -v gcc >/dev/null 2>&1; then
  ln -sfv ../../libexec/gcc/$(gcc -dumpmachine)/'"${PKG_VERSION}"'/liblto_plugin.so \
    /usr/lib/bfd-plugins/ || true
fi

# Arquivos auto-load do gdb
mkdir -pv /usr/share/gdb/auto-load/usr/lib
if ls /usr/lib/*gdb.py >/dev/null 2>&1; then
  mv -v /usr/lib/*gdb.py /usr/share/gdb/auto-load/usr/lib || true
fi
'

# Opcional: para builds nativos (sem cross toolchain), force ADM_USE_NATIVE=1 antes de chamar o adm:
#   ADM_USE_NATIVE=1 /opt/adm/adm build toolchain/gcc
#
# Caso você queira forçar LD=ld (como no LFS final), pode exportar no ambiente
# antes de rodar o adm:
#   LD=ld /opt/adm/adm build toolchain/gcc
