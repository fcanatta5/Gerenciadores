#!/usr/bin/env bash
# Binutils 2.45.1 - Pass 1 (toolchain temporária)
# Target: x86_64-linux-gnu
# Prefix: /mnt/adm/tools (não suja o rootfs fora do /mnt/adm)

set -Eeuo pipefail
shopt -s nullglob

PKG_NAME="binutils"
PKG_VERSION="2.45.1-pass1"
PKG_CATEGORY="toolchain"

: "${ADM_MNT:=/mnt/adm}"
: "${ADM_TOOLS:=$ADM_MNT/tools}"
: "${ADM_TGT:=x86_64-linux-gnu}"

PKG_SOURCES=(
  "https://ftp.gnu.org/gnu/binutils/binutils-2.45.1.tar.xz|sha256|860daddec9085cb4011279136fc8ad29eb533e9446d7524af7f517dd18f00224"
)

PKG_DEPENDS=(
  # pass1 normalmente não exige deps aqui; mantenha vazio
)

PKG_PATCHES=(
  # opcional
)

build() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"

  cd "$ADM_WORKDIR"

  local tarball="$ADM_WORKDIR/sources/binutils-2.45.1.tar.xz"
  [[ -f "$tarball" ]] || tarball="$(ls -1 "$ADM_WORKDIR/sources"/binutils-2.45.1.tar.* 2>/dev/null | head -n1 || true)"
  [[ -f "$tarball" ]] || { echo "ERRO: tarball binutils não encontrado em $ADM_WORKDIR/sources"; return 1; }

  rm -rf "binutils-2.45.1" "build-binutils-pass1"
  tar -xf "$tarball"
  mkdir -p "build-binutils-pass1"
  cd "build-binutils-pass1"

  # build system (para evitar detecção errada em ambientes estranhos)
  local build_triplet=""
  build_triplet="$("../binutils-2.45.1/config.guess")"

  # Importante: em pass1, queremos as tools isoladas:
  # - prefix em /mnt/adm/tools
  # - sysroot em /mnt/adm
  # - lib-path apontando para /mnt/adm/tools/lib (onde a toolchain temporária vive)
  # - disable-nls, disable-werror para build limpo
  # - disable-multilib em x86_64 para evitar libs 32-bit
  ../binutils-2.45.1/configure \
    --prefix="$ADM_TOOLS" \
    --with-sysroot="$ADM_MNT" \
    --target="$ADM_TGT" \
    --build="$build_triplet" \
    --disable-nls \
    --disable-werror \
    --disable-multilib \
    --with-lib-path="$ADM_TOOLS/lib" \
    --enable-gprofng=no

  make -j"$(nproc)"
}

install() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"
  : "${ADM_MNT:=/mnt/adm}"
  : "${ADM_TOOLS:=$ADM_MNT/tools}"
  : "${ADM_TGT:=x86_64-linux-gnu}"

  cd "$ADM_WORKDIR/build-binutils-pass1"

  # Instala no staging do adm. Como o prefix é /mnt/adm/tools,
  # a extração em / só vai tocar /mnt/adm/tools/...
  make DESTDIR="$DESTDIR" install

  # Pass1: enxuga lixo (opcional, mas alinhado ao fluxo de toolchain temporária)
  rm -rf "$DESTDIR$ADM_TOOLS"/{share,info,man,doc} 2>/dev/null || true

  # Opcional (LFS-like): se você quer facilitar chamadas genéricas ao linker dentro das tools
  # sem depender do nome tripletado, pode manter isso DESLIGADO por segurança.
  # Se quiser, descomente:
  # ln -sf "$ADM_TGT-ld" "$DESTDIR$ADM_TOOLS/bin/ld" 2>/dev/null || true
}
