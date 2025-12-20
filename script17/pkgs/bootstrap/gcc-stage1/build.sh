#!/bin/sh
set -eu

# GCC 15.2.0 (stage1)
# Diretório do release possui sha512.sum (oficial) 2
GCC_VER="${PKGVER}"
GCC_BASE="https://gcc.gnu.org/pub/gcc/releases/gcc-${GCC_VER}"
GCC_URL="${GCC_BASE}/gcc-${GCC_VER}.tar.xz"
GCC_TARBALL="${WORKDIR}/gcc-${GCC_VER}.tar.xz"
GCC_SHA512_SUM="${WORKDIR}/gcc-${GCC_VER}.sha512.sum"

# Prereqs embutidos in-tree (SHA256)
# GMP 6.3.0 sha256 3
GMP_VER="6.3.0"
GMP_URL="https://gmplib.org/download/gmp/gmp-${GMP_VER}.tar.xz"
GMP_TARBALL="${WORKDIR}/gmp-${GMP_VER}.tar.xz"
GMP_SHA256="a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"

# MPFR 4.2.2 sha256 4
MPFR_VER="4.2.2"
MPFR_URL="https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VER}.tar.xz"
MPFR_TARBALL="${WORKDIR}/mpfr-${MPFR_VER}.tar.xz"
MPFR_SHA256="b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01"

# MPC 1.3.1 sha256 5
MPC_VER="1.3.1"
MPC_URL="https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.gz"
MPC_TARBALL="${WORKDIR}/mpc-${MPC_VER}.tar.gz"
MPC_SHA256="ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8"

# ISL 0.27 sha256 6
ISL_VER="0.27"
ISL_URL="https://libisl.sourceforge.io/isl-${ISL_VER}.tar.xz"
ISL_TARBALL="${WORKDIR}/isl-${ISL_VER}.tar.xz"
ISL_SHA256="6d8babb59e7b672e8cb7870e874f3f7b813b6e00e6af3f8b04f7579965643d5c"

# Variáveis vindas do pm-bootstrap.sh
: "${TARGET:=x86_64-linux-musl}"
: "${TC_SYSROOT:=}"
: "${BOOTSTRAP:=0}"

have() { command -v "$1" >/dev/null 2>&1; }

fetch_file() {
  url=$1 out=$2
  if have wget; then
    wget -O "$out.tmp" "$url"
  elif have curl; then
    curl -L -o "$out.tmp" "$url"
  else
    echo "ERRO: precisa de wget ou curl para baixar fontes." >&2
    exit 1
  fi
  mv -f "$out.tmp" "$out"
}

sha256_check() {
  file=$1 expected=$2
  got=$(sha256sum "$file" | awk '{print $1}')
  if [ "$got" != "$expected" ]; then
    echo "ERRO: SHA256 inválido para $(basename "$file")" >&2
    echo "Esperado: $expected" >&2
    echo "Obtido:   $got" >&2
    exit 1
  fi
}

# Verificação do GCC via sha512.sum do diretório oficial do release (melhor que hardcode de hash)
sha512_check_gcc() {
  tarball=$1
  sumfile=$2

  have sha512sum || {
    echo "ERRO: sha512sum não encontrado. Instale sha512sum (BusyBox geralmente inclui) para verificar gcc." >&2
    exit 1
  }

  # pega a linha correspondente ao tarball e verifica
  base=$(basename "$tarball")
  line=$(awk -v F="$base" '$2==F{print; found=1} END{if(!found)exit 2}' "$sumfile") || {
    echo "ERRO: não encontrei $base dentro de $(basename "$sumfile")" >&2
    exit 1
  }

  # formato típico: "<sha512>  <filename>"
  printf "%s\n" "$line" | (cd "$(dirname "$tarball")" && sha512sum -c -) >/dev/null 2>&1 || {
    echo "ERRO: SHA512 inválido para $base" >&2
    exit 1
  }
}

hook_pre_install() { :; }
hook_post_install() { :; }
hook_pre_remove() { :; }
hook_post_remove() { :; }

pkg_fetch() {
  mkdir -p "$WORKDIR"

  # GCC + sha512.sum
  if [ ! -f "$GCC_SHA512_SUM" ]; then
    fetch_file "${GCC_BASE}/sha512.sum" "$GCC_SHA512_SUM"
  fi

  if [ -f "$GCC_TARBALL" ]; then
    sha512_check_gcc "$GCC_TARBALL" "$GCC_SHA512_SUM"
  else
    fetch_file "$GCC_URL" "$GCC_TARBALL"
    sha512_check_gcc "$GCC_TARBALL" "$GCC_SHA512_SUM"
  fi

  # prereqs (sha256)
  if [ -f "$GMP_TARBALL" ]; then sha256_check "$GMP_TARBALL" "$GMP_SHA256"; else fetch_file "$GMP_URL" "$GMP_TARBALL"; sha256_check "$GMP_TARBALL" "$GMP_SHA256"; fi
  if [ -f "$MPFR_TARBALL" ]; then sha256_check "$MPFR_TARBALL" "$MPFR_SHA256"; else fetch_file "$MPFR_URL" "$MPFR_TARBALL"; sha256_check "$MPFR_TARBALL" "$MPFR_SHA256"; fi
  if [ -f "$MPC_TARBALL" ]; then sha256_check "$MPC_TARBALL" "$MPC_SHA256"; else fetch_file "$MPC_URL" "$MPC_TARBALL"; sha256_check "$MPC_TARBALL" "$MPC_SHA256"; fi
  if [ -f "$ISL_TARBALL" ]; then sha256_check "$ISL_TARBALL" "$ISL_SHA256"; else fetch_file "$ISL_URL" "$ISL_TARBALL"; sha256_check "$ISL_TARBALL" "$ISL_SHA256"; fi
}

pkg_unpack() {
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"

  tar -C "$SRCDIR" --strip-components=1 -xJf "$GCC_TARBALL"

  # Embute prereqs dentro do source do gcc (modo suportado pelo gcc build)
  rm -rf "$SRCDIR/gmp" "$SRCDIR/mpfr" "$SRCDIR/mpc" "$SRCDIR/isl"
  mkdir -p "$SRCDIR/gmp" "$SRCDIR/mpfr" "$SRCDIR/mpc" "$SRCDIR/isl"

  tar -C "$SRCDIR/gmp"  --strip-components=1 -xJf "$GMP_TARBALL"
  tar -C "$SRCDIR/mpfr" --strip-components=1 -xJf "$MPFR_TARBALL"
  tar -C "$SRCDIR/isl"  --strip-components=1 -xJf "$ISL_TARBALL"
  tar -C "$SRCDIR/mpc"  --strip-components=1 -xzf "$MPC_TARBALL"
}

pkg_build() {
  [ -n "${TC_SYSROOT:-}" ] || { echo "ERRO: TC_SYSROOT vazio (bootstrap)"; exit 1; }
  case "$TC_SYSROOT" in
    /*) : ;;
    *) echo "ERRO: TC_SYSROOT deve ser path absoluto: '$TC_SYSROOT'" >&2; exit 1 ;;
  esac

  # Binutils do stage anterior devem estar em $PM_PREFIX/bin no root real.
  # Para garantir que configure encontre ${TARGET}-as/ld/ar/etc:
  export PATH="$PM_PREFIX/bin:$PATH"

  cd "$SRCDIR"
  rm -rf build
  mkdir -p build
  cd build

  # Stage1: compilador C + libgcc sem libc (sem headers)
  # - --without-headers: evita depender de libc pronta
  # - --with-newlib: padrão para toolchains sem libc no stage1
  # - desliga tudo “caro”/desnecessário nessa fase
  #
  ../configure \
    --prefix="$PM_PREFIX" \
    --target="$TARGET" \
    --with-sysroot="$TC_SYSROOT" \
    --enable-languages=c \
    --disable-multilib \
    --disable-nls \
    --disable-shared \
    --disable-threads \
    --disable-libatomic \
    --disable-libgomp \
    --disable-libquadmath \
    --disable-libsanitizer \
    --disable-libssp \
    --disable-libstdcxx \
    --disable-libvtv \
    --disable-bootstrap \
    --without-headers \
    --with-newlib

  # build mínimo recomendado para stage1
  make -j"$PM_JOBS" all-gcc
  make -j"$PM_JOBS" all-target-libgcc
}

pkg_install() {
  cd "$SRCDIR/build"

  # Instala em DESTDIR
  make DESTDIR="$DESTDIR" install-gcc
  make DESTDIR="$DESTDIR" install-target-libgcc

  # Remove .la se aparecer (evita lixo)
  find "$DESTDIR" -type f -name "*.la" -delete 2>/dev/null || true

  # Sanidade básica
  if [ ! -x "$DESTDIR$PM_PREFIX/bin/${TARGET}-gcc" ]; then
    echo "ERRO: ${TARGET}-gcc não foi instalado em $DESTDIR$PM_PREFIX/bin" >&2
    exit 1
  fi
}
