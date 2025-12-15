#!/usr/bin/env bash
# Libstdc++ (Target) from GCC 15.2.0 - Pass 1 (LFS Chapter 5.6 aligned)
# Sysroot: /mnt/adm
# Instala em: /mnt/adm/usr (via DESTDIR do adm)
#
# Importante:
# - Libstdc++ depende da Glibc já instalada no sysroot.
# - Usa o cross-compiler (gcc-pass1) em /mnt/adm/tools.
# - Mantém o include-dir em /tools/$TGT/include/c++/15.2.0 (como no LFS),
#   porque o compilador pré-configurado adiciona o sysroot (/mnt/adm) ao caminho.

set -Eeuo pipefail
shopt -s nullglob

PKG_NAME="libstdc++"
PKG_VERSION="15.2.0-pass1"
PKG_CATEGORY="toolchain"

: "${ADM_MNT:=/mnt/adm}"
: "${ADM_TOOLS:=$ADM_MNT/tools}"
: "${ADM_TGT:=x86_64-linux-gnu}"

PKG_DEPENDS=(
  "gcc@15.2.0-pass1"
  "glibc@2.42-pass1"
)

# Fonte oficial do GCC 15.2.0 (sha256 do .tar.xz)
PKG_SOURCES=(
  "https://gcc.gnu.org/pub/gcc/releases/gcc-15.2.0/gcc-15.2.0.tar.xz|sha256|438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e"
)

PKG_PATCHES=(
  # nenhum para esta etapa no LFS
)

build() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"
  : "${ADM_MNT:?ADM_MNT não definido}"
  : "${ADM_TOOLS:?ADM_TOOLS não definido}"
  : "${ADM_TGT:?ADM_TGT não definido}"

  export PATH="$ADM_TOOLS/bin:$PATH"

  # Confere se glibc já existe no sysroot (requisito prático)
  [[ -e "$ADM_MNT/usr/include/stdio.h" ]] || {
    echo "ERRO: glibc (headers) não parece instalada em $ADM_MNT/usr. Construa/instale glibc-pass1 primeiro."
    return 1
  }

  cd "$ADM_WORKDIR"

  local tarball="$ADM_WORKDIR/sources/gcc-15.2.0.tar.xz"
  [[ -f "$tarball" ]] || {
    echo "ERRO: tarball do GCC não encontrado em $ADM_WORKDIR/sources"
    return 1
  }

  rm -rf gcc-15.2.0
  tar -xf "$tarball"
  cd gcc-15.2.0

  # LFS: build dir separado dentro do source do GCC
  rm -rf build
  mkdir -p build
  cd build

  # LFS: configure dentro de libstdc++-v3
  ../libstdc++-v3/configure \
    --host="$ADM_TGT" \
    --build="$(../config.guess)" \
    --prefix=/usr \
    --disable-multilib \
    --disable-nls \
    --disable-libstdcxx-pch \
    --with-gxx-include-dir="/tools/$ADM_TGT/include/c++/15.2.0"

  make -j"$(nproc)"
}

install() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"
  : "${ADM_MNT:?ADM_MNT não definido}"
  : "${ADM_TOOLS:?ADM_TOOLS não definido}"
  : "${ADM_TGT:?ADM_TGT não definido}"

  export PATH="$ADM_TOOLS/bin:$PATH"

  cd "$ADM_WORKDIR/gcc-15.2.0/build"

  # LFS: DESTDIR=$LFS -> aqui: DESTDIR="$DESTDIR$ADM_MNT"
  make DESTDIR="$DESTDIR$ADM_MNT" install

  # LFS: remove .la (nocivos em cross)
  rm -f "$DESTDIR$ADM_MNT/usr/lib/libstdc++.la" \
        "$DESTDIR$ADM_MNT/usr/lib/libstdc++exp.la" \
        "$DESTDIR$ADM_MNT/usr/lib/libstdc++fs.la" \
        "$DESTDIR$ADM_MNT/usr/lib/libsupc++.la" 2>/dev/null || true
}
