#!/usr/bin/env bash
# m4 1.4.20 (instala no sysroot /mnt/adm)
# Target root: /mnt/adm
# Instala em: /mnt/adm/usr (via DESTDIR do adm)

set -Eeuo pipefail
shopt -s nullglob

PKG_NAME="m4"
PKG_VERSION="1.4.20"
PKG_CATEGORY="toolchain"

: "${ADM_MNT:=/mnt/adm}"
: "${ADM_TOOLS:=$ADM_MNT/tools}"
: "${ADM_TGT:=x86_64-linux-gnu}"

PKG_DEPENDS=(
  # normalmente vazio; m4 é ferramenta do host/build no ambiente do sysroot
)

# GNU m4 1.4.20
PKG_SOURCES=(
  "https://ftp.gnu.org/gnu/m4/m4-1.4.20.tar.xz|sha256|TBD"
)

PKG_PATCHES=(
  # nenhum
)

build() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"

  export PATH="$ADM_TOOLS/bin:$PATH"

  cd "$ADM_WORKDIR"

  local tarball="$ADM_WORKDIR/sources/m4-1.4.20.tar.xz"
  [[ -f "$tarball" ]] || tarball="$(ls -1 "$ADM_WORKDIR/sources"/m4-1.4.20.tar.* 2>/dev/null | head -n1 || true)"
  [[ -f "$tarball" ]] || { echo "ERRO: tarball do m4 não encontrado em $ADM_WORKDIR/sources"; return 1; }

  rm -rf m4-1.4.20 build-m4
  tar -xf "$tarball"
  mkdir -p build-m4
  cd build-m4

  local build_triplet
  build_triplet="$("../m4-1.4.20/build-aux/config.guess")"

  # Instalação no sysroot (/mnt/adm/usr) via DESTDIR
  ../m4-1.4.20/configure \
    --prefix=/usr \
    --build="$build_triplet" \
    --disable-nls

  make -j"$(nproc)"
}

install() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"
  : "${ADM_MNT:=/mnt/adm}"

  cd "$ADM_WORKDIR/build-m4"

  make DESTDIR="$DESTDIR$ADM_MNT" install

  # opcional: enxugar docs
  rm -rf "$DESTDIR$ADM_MNT/usr"/{share,info,man,doc} 2>/dev/null || true
}
