#!/usr/bin/env bash
# musl 1.2.5 (base system) + patches de segurança (CVE-2025-26519)
# Instala no sysroot /mnt/adm (via DESTDIR do adm)
#
# Segurança:
# - musl até 1.2.5 é afetada por CVE-2025-26519; estes patches corrigem/harden o caminho iconv EUC-KR->UTF-8.
#   Referências: advisory oficial do musl + NVD. 1

set -Eeuo pipefail
shopt -s nullglob

PKG_NAME="musl"
PKG_VERSION="1.2.5"
PKG_CATEGORY="base"

: "${ADM_MNT:=/mnt/adm}"
: "${ADM_TOOLS:=$ADM_MNT/tools}"
: "${ADM_TGT:=x86_64-linux-gnu}"

PKG_DEPENDS=(
  # Se você está no "base" real (Chapter 8/9), normalmente já tem gcc/make no ambiente.
  # Não force deps aqui para não amarrar seu bootstrap.
)

# Tarball oficial do musl 1.2.5. SHA256 conhecido. 2
PKG_SOURCES=(
  "https://musl.libc.org/releases/musl-1.2.5.tar.gz|sha256|a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"
)

# Patches de segurança (CVE-2025-26519) obtidos de um bundle de patches amplamente consumido
# (Bootlin toolchains), correspondentes aos commits de correção/hardening no iconv. 3
PKG_PATCHES=(
  "https://toolchains.bootlin.com/downloads/releases/sources/musl-1.2.5/0004-iconv-fix-erroneous-input-validation-in-EUC-KR-decod.patch|sha256|66da72fd06711ddd7e7ea9c34c5097d6a22a7c8e1acfd51638ab8513ecc6ff58|1|."
  "https://toolchains.bootlin.com/downloads/releases/sources/musl-1.2.5/0005-iconv-harden-UTF-8-output-code-path-against-input-de.patch|sha256|af6b3b681ec2c99da7f82ad218e6c4fbeb8fe00297323ab2b0c0c148a2b79440|1|."
)

build() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"

  # Se existir toolchain temporária, prioriza; se não, segue PATH normal.
  if [[ -d "$ADM_TOOLS/bin" ]]; then
    export PATH="$ADM_TOOLS/bin:$PATH"
  fi

  cd "$ADM_WORKDIR"

  local tarball="$ADM_WORKDIR/sources/musl-1.2.5.tar.gz"
  [[ -f "$tarball" ]] || tarball="$(ls -1 "$ADM_WORKDIR/sources"/musl-1.2.5.tar.* 2>/dev/null | head -n1 || true)"
  [[ -f "$tarball" ]] || { echo "ERRO: tarball do musl não encontrado em $ADM_WORKDIR/sources"; return 1; }

  rm -rf musl-1.2.5 build-musl
  tar -xf "$tarball"

  mkdir -p build-musl
  cd build-musl

  # Preferir cross-tools se disponíveis; caso contrário usa cc/gcc do ambiente.
  if command -v "${ADM_TGT}-gcc" >/dev/null 2>&1; then
    export CC="${ADM_TGT}-gcc"
    export AR="${ADM_TGT}-ar"
    export RANLIB="${ADM_TGT}-ranlib"
  fi

  # musl usa um configure simples (não autoconf clássico).
  # Para layout FHS-like: prefix=/usr e syslibdir=/lib (loader/libc em /lib).
  ../musl-1.2.5/configure \
    --prefix=/usr \
    --syslibdir=/lib

  make -j"$(nproc)"
}

install() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"
  : "${ADM_MNT:=/mnt/adm}"

  cd "$ADM_WORKDIR/build-musl"

  # Instala no sysroot (/mnt/adm) via staging do adm
  make DESTDIR="$DESTDIR$ADM_MNT" install

  # musl normalmente instala o loader em /lib (ex.: /lib/ld-musl-x86_64.so.1).
  # Garantir diretórios padrão (defensivo):
  mkdir -p "$DESTDIR$ADM_MNT"/{lib,usr/lib,usr/include} 2>/dev/null || true

  # (Opcional) limpar docs, se houver
  rm -rf "$DESTDIR$ADM_MNT/usr"/{share,info,man,doc} 2>/dev/null || true
}
