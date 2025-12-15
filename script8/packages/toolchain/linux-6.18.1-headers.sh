#!/usr/bin/env bash
# Linux 6.18.1 - Kernel API Headers (para sysroot)
# Instala em: /mnt/adm/usr/include (via DESTDIR do adm)
# Target: x86_64-linux-gnu  (headers usam ARCH=x86)
#
# Observação importante:
# - Estes são "Linux API Headers" (UAPI), necessários para glibc/musl e toolchain.
# - NÃO instala kernel nem módulos.
# - NÃO deve instalar em /mnt/adm/tools.

set -Eeuo pipefail
shopt -s nullglob

PKG_NAME="linux"
PKG_VERSION="6.18.1-headers"
PKG_CATEGORY="toolchain"

: "${ADM_MNT:=/mnt/adm}"
: "${ADM_TOOLS:=$ADM_MNT/tools}"
: "${ADM_TGT:=x86_64-linux-gnu}"

PKG_DEPENDS=(
  # normalmente nenhum para headers; mas exige make/gcc no host.
)

# Fonte oficial (kernel.org). 1
# NOTA: eu não consegui extrair o sha256 do sha256sums.asc via web tool (ele vem “colapsado” em 1 linha),
# então deixei o campo como "sha256|TBD". Você deve preencher com o sha256 real do tarball.
PKG_SOURCES=(
  "https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.18.1.tar.xz|sha256|TBD"
)

PKG_PATCHES=(
  # opcional
)

build() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"
  : "${ADM_MNT:?ADM_MNT não definido}"
  : "${ADM_TGT:?ADM_TGT não definido}"

  cd "$ADM_WORKDIR"

  local src_tar="$ADM_WORKDIR/sources/linux-6.18.1.tar.xz"
  [[ -f "$src_tar" ]] || { echo "ERRO: tarball não encontrado em $src_tar"; return 1; }

  rm -rf linux-6.18.1
  tar -xf "$src_tar"

  cd linux-6.18.1

  # Mantém a árvore "limpa" e determinística para headers_install
  make mrproper

  # Para x86_64, os UAPI headers usam ARCH=x86 (kernel convention)
  # "headers" é opcional hoje em dia, mas ajuda a garantir que os alvos UAPI existam.
  make ARCH=x86 headers
}

install() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"
  : "${ADM_MNT:?ADM_MNT não definido}"

  cd "$ADM_WORKDIR/linux-6.18.1"

  # Instala Linux API headers em /mnt/adm/usr/include (via staging do adm)
  # headers_install cria $INSTALL_HDR_PATH/include
  local hdr_root="$DESTDIR$ADM_MNT/usr"

  mkdir -p "$hdr_root"
  make ARCH=x86 headers_install INSTALL_HDR_PATH="$hdr_root"

  # Limpezas recomendadas (estilo LFS):
  # remove arquivos ocultos e Makefile residual em include
  find "$hdr_root/include" -name '.*' -delete || true
  rm -f "$hdr_root/include/Makefile" || true
}
