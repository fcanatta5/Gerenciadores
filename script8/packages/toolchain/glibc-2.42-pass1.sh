#!/usr/bin/env bash
# Glibc 2.42 - Pass 1 (LFS Chapter 5 aligned)
# Sysroot: /mnt/adm
# Instala em: /mnt/adm/usr (via DESTDIR do adm)
#
# LFS recipe (development) referência:
# - symlinks (x86_64) em $LFS/lib64 apontando para ../lib/ld-linux-x86-64.so.2
# - patch FHS glibc-2.42-fhs-1.patch
# - build dir dedicado + configparms rootsbindir=/usr/sbin
# - configure: --prefix=/usr --host=$LFS_TGT --build=$(../scripts/config.guess)
#              --disable-nscd libc_cv_slibdir=/usr/lib --enable-kernel=5.4
# - make; make DESTDIR=$LFS install; sed em ldd

set -Eeuo pipefail
shopt -s nullglob

PKG_NAME="glibc"
PKG_VERSION="2.42-pass1"
PKG_CATEGORY="toolchain"

: "${ADM_MNT:=/mnt/adm}"
: "${ADM_TOOLS:=$ADM_MNT/tools}"
: "${ADM_TGT:=x86_64-linux-gnu}"

PKG_DEPENDS=(
  "linux@6.18.1-headers"
  "binutils@2.45.1-pass1"
  "gcc@15.2.0-pass1"
)

# Fonte GNU (glibc-2.42.tar.xz). O sha256 você pode preencher quando quiser travar.
PKG_SOURCES=(
  "https://ftp.gnu.org/gnu/glibc/glibc-2.42.tar.xz|sha256|TBD"
)

# Patch FHS do LFS (MD5 conforme lista de patches do LFS). 1
PKG_PATCHES=(
  "https://www.linuxfromscratch.org/patches/lfs/development/glibc-2.42-fhs-1.patch|md5|9a5997c3452909b1769918c759eff8a2|1|."
)

build() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"
  : "${ADM_MNT:?ADM_MNT não definido}"
  : "${ADM_TOOLS:?ADM_TOOLS não definido}"
  : "${ADM_TGT:?ADM_TGT não definido}"

  export PATH="$ADM_TOOLS/bin:$PATH"

  cd "$ADM_WORKDIR"

  local tarball="$ADM_WORKDIR/sources/glibc-2.42.tar.xz"
  [[ -f "$tarball" ]] || tarball="$(ls -1 "$ADM_WORKDIR/sources"/glibc-2.42.tar.* 2>/dev/null | head -n1 || true)"
  [[ -f "$tarball" ]] || { echo "ERRO: tarball glibc não encontrado em $ADM_WORKDIR/sources"; return 1; }

  rm -rf glibc-2.42
  tar -xf "$tarball"
  cd glibc-2.42

  # Aplica patches automaticamente (o adm pode aplicar fora; deixo aqui redundante-safe)
  # Se o seu adm já chama apply_patches() antes de build(), remova este bloco.
  if [[ -d "$ADM_WORKDIR/patches" ]]; then
    for p in "$ADM_WORKDIR/patches"/*.patch; do
      [[ -f "$p" ]] || continue
      patch -Np1 -i "$p"
    done
  fi

  # Build em diretório dedicado (LFS)
  rm -rf build
  mkdir -p build
  cd build

  # rootsbindir=/usr/sbin (LFS)
  echo "rootsbindir=/usr/sbin" > configparms

  local build_triplet
  build_triplet="$("../scripts/config.guess")"

  # Configuração alinhada ao LFS (development). 2
  ../configure \
    --prefix=/usr \
    --host="$ADM_TGT" \
    --build="$build_triplet" \
    --disable-nscd \
    libc_cv_slibdir=/usr/lib \
    --enable-kernel=5.4

  make -j"$(nproc)"
}

install() {
  : "${ADM_WORKDIR:?ADM_WORKDIR não definido pelo adm}"
  : "${DESTDIR:?DESTDIR não definido pelo adm}"
  : "${ADM_MNT:?ADM_MNT não definido}"
  : "${ADM_TOOLS:?ADM_TOOLS não definido}"
  : "${ADM_TGT:?ADM_TGT não definido}"

  export PATH="$ADM_TOOLS/bin:$PATH"

  # 1) Symlinks de loader (LSB/compat) NO SYSROOT (staging), como no LFS. 3
  # Para x86_64: criar $LFS/lib64 -> ../lib/ld-linux-x86-64.so.2 e ld-lsb-x86-64.so.3
  mkdir -p "$DESTDIR$ADM_MNT/lib64" "$DESTDIR$ADM_MNT/lib"
  if [[ "$(uname -m)" == "x86_64" ]]; then
    ln -sfv ../lib/ld-linux-x86-64.so.2 "$DESTDIR$ADM_MNT/lib64" || true
    ln -sfv ../lib/ld-linux-x86-64.so.2 "$DESTDIR$ADM_MNT/lib64/ld-lsb-x86-64.so.3" || true
  elif [[ "$(uname -m)" =~ ^i.86$ ]]; then
    ln -sfv ld-linux.so.2 "$DESTDIR$ADM_MNT/lib/ld-lsb.so.3" || true
  fi

  # 2) Instala no sysroot: DESTDIR=$LFS (aqui: DESTDIR="$DESTDIR$ADM_MNT") 4
  cd "$ADM_WORKDIR/glibc-2.42/build"
  make DESTDIR="$DESTDIR$ADM_MNT" install

  # 3) Fix do ldd (remove /usr hardcoded em RTLDLIST) 5
  if [[ -f "$DESTDIR$ADM_MNT/usr/bin/ldd" ]]; then
    sed '/RTLDLIST=/s@/usr@@g' -i "$DESTDIR$ADM_MNT/usr/bin/ldd"
  fi

  # Opcional: enxugar docs no sysroot temporário
  rm -rf "$DESTDIR$ADM_MNT/usr"/{share,info,man,doc} 2>/dev/null || true
}
