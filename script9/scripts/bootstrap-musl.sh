#!/bin/sh
set -eu

# ------------------------------------------------------------
# Bootstrap MUSL system (one-shot) to chroot + handoff to adm
# Target: x86_64-linux-musl
# Sysroot: /mnt/adm
# Cross prefix: /opt/adm-cross
# ------------------------------------------------------------

SYSROOT="${SYSROOT:-/mnt/adm}"
CROSS_PREFIX="${CROSS_PREFIX:-/opt/adm-cross}"
TARGET="${TARGET:-x86_64-linux-musl}"

# Versions (pinned for repeatability)
BINUTILS_VER="${BINUTILS_VER:-2.45.1}"
GCC_VER="${GCC_VER:-15.2.0}"

MUSL_VER="${MUSL_VER:-1.2.5}"

# GCC integrated prereqs
GMP_VER="${GMP_VER:-6.3.0}"
MPFR_VER="${MPFR_VER:-4.2.1}"
MPC_VER="${MPC_VER:-1.3.1}"
ISL_VER="${ISL_VER:-0.27}"

BUSYBOX_VER="${BUSYBOX_VER:-1.36.1}"

# Work directories
WORK="${WORK:-/var/tmp/adm-bootstrap}"
SRC="$WORK/src"
BLD="$WORK/build"
LOG="$WORK/log"

# URLs
U_BINUTILS="https://sourceware.org/pub/binutils/releases/binutils-${BINUTILS_VER}.tar.xz"
U_GCC="https://gcc.gnu.org/pub/gcc/releases/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz"
U_MUSL="https://musl.libc.org/releases/musl-${MUSL_VER}.tar.gz"
U_GMP="https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz"
U_MPFR="https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VER}.tar.xz"
U_MPC="https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.gz"
U_ISL="https://libisl.sourceforge.io/isl-${ISL_VER}.tar.xz"
U_BUSYBOX="https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2"

PATH="$CROSS_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

msg(){ printf '%s\n' "bootstrap: $*" >&2; }
die(){ printf '%s\n' "bootstrap: erro: $*" >&2; exit 1; }

need_root(){ [ "$(id -u)" -eq 0 ] || die "execute como root"; }

have(){ command -v "$1" >/dev/null 2>&1; }
need(){
  for c in "$@"; do have "$c" || die "comando ausente: $c"; done
}

nproc_(){
  getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}
JOBS="${JOBS:-$(nproc_)}"

fetch() {
  url="$1"
  out="$SRC/$(basename "$url")"
  [ -f "$out" ] && return 0
  msg "download: $url"
  if have curl; then
    curl -L --fail --retry 3 -o "$out" "$url"
  elif have wget; then
    wget -O "$out" "$url"
  else
    die "precisa de curl ou wget"
  fi
}

extract() {
  f="$1"
  d="$2"
  mkdir -p "$d"
  case "$f" in
    *.tar.xz)  tar -xJf "$f" -C "$d" ;;
    *.tar.gz)  tar -xzf "$f" -C "$d" ;;
    *.tar.bz2) tar -xjf "$f" -C "$d" ;;
    *.tgz)     tar -xzf "$f" -C "$d" ;;
    *) die "formato desconhecido: $f" ;;
  esac
}

clean_dir() {
  p="$1"
  [ -n "$p" ] || die "clean_dir vazio"
  rm -rf -- "$p"
  mkdir -p "$p"
}

ensure_sysroot_layout() {
  msg "preparando sysroot: $SYSROOT"
  mkdir -p "$SYSROOT"
  mkdir -p "$SYSROOT"/{bin,sbin,lib,lib64,etc,proc,sys,dev,run,tmp,home,root,var,usr}
  mkdir -p "$SYSROOT/usr"/{bin,sbin,lib,lib64,include,share}
  mkdir -p "$SYSROOT/var"/{db,cache,log}
  chmod 1777 "$SYSROOT/tmp" || true
}

copy_kernel_headers_from_host() {
  # musl precisa de headers de kernel; a forma mais prática sem LFS é copiar do host.
  # Isso é suficiente para bootstrap (assumindo host tem headers instalados).
  for d in linux asm asm-generic; do
    [ -d "/usr/include/$d" ] || die "headers do kernel ausentes no host: /usr/include/$d"
  done
  msg "copiando headers do kernel do host para sysroot"
  mkdir -p "$SYSROOT/usr/include"
  cp -a /usr/include/linux "$SYSROOT/usr/include/"
  cp -a /usr/include/asm "$SYSROOT/usr/include/"
  cp -a /usr/include/asm-generic "$SYSROOT/usr/include/"
}

apply_musl_security_patches() {
  # CVE-2025-26519 fixes (dois patches mínimos)
  # Patch 1
  patch -Np1 <<'PATCH'
diff --git a/src/locale/iconv.c b/src/locale/iconv.c
index 9605c8e9..008c93f0 100644
--- a/src/locale/iconv.c
+++ b/src/locale/iconv.c
@@ -502,7 +502,7 @@ size_t iconv(iconv_t cd, char **restrict in, size_t *restrict inb, char **restri
 	if (c >= 93 || d >= 94) {
 		c += (0xa1-0x81);
 		d += 0xa1;
-		if (c >= 93 || c>=0xc6-0x81 && d>0x52)
+		if (c > 0xc6-0x81 || c==0xc6-0x81 && d>0x52)
 			goto ilseq;
 		if (d-'A'<26) d = d-'A';
PATCH

  # Patch 2
  patch -Np1 <<'PATCH'
diff --git a/src/locale/iconv.c b/src/locale/iconv.c
index 008c93f0..52178950 100644
--- a/src/locale/iconv.c
+++ b/src/locale/iconv.c
@@ -545,6 +545,10 @@ size_t iconv(iconv_t cd, char **restrict in, size_t *restrict inb, char **restri
 			if (*outb < k) goto toobig;
 			memcpy(*out, tmp, k);
 		} else k = wctomb_utf8(*out, c);
+		/* This failure condition should be unreachable, but
+		 * is included to prevent decoder bugs from translating
+		 * into advancement outside the output buffer range. */
+		if (k>4) goto ilseq;
 		*out += k;
 		*outb -= k;
 		break;
PATCH
}

build_binutils() {
  msg "=== binutils ${BINUTILS_VER} (cross) ==="
  clean_dir "$BLD/binutils"
  clean_dir "$WORK/tree-binutils"

  fetch "$U_BINUTILS"
  extract "$SRC/binutils-${BINUTILS_VER}.tar.xz" "$WORK/tree-binutils"
  cd "$BLD/binutils"

  "$WORK/tree-binutils/binutils-${BINUTILS_VER}/configure" \
    --prefix="$CROSS_PREFIX" \
    --target="$TARGET" \
    --with-sysroot="$SYSROOT" \
    --disable-nls \
    --disable-werror \
    --enable-plugins

  make -j"$JOBS"
  make install
}

build_gcc_stage1() {
  msg "=== gcc ${GCC_VER} stage1 (C only, no libc) ==="
  clean_dir "$BLD/gcc-stage1"
  clean_dir "$WORK/tree-gcc"

  fetch "$U_GCC"
  fetch "$U_GMP"
  fetch "$U_MPFR"
  fetch "$U_MPC"
  fetch "$U_ISL"

  extract "$SRC/gcc-${GCC_VER}.tar.xz" "$WORK/tree-gcc"
  cd "$WORK/tree-gcc/gcc-${GCC_VER}"

  # embed prereqs into GCC tree (supported practice)
  rm -rf gmp mpfr mpc isl
  extract "$SRC/gmp-${GMP_VER}.tar.xz" "$WORK/tree-gcc/gcc-${GCC_VER}"
  extract "$SRC/mpfr-${MPFR_VER}.tar.xz" "$WORK/tree-gcc/gcc-${GCC_VER}"
  extract "$SRC/mpc-${MPC_VER}.tar.gz" "$WORK/tree-gcc/gcc-${GCC_VER}"
  extract "$SRC/isl-${ISL_VER}.tar.xz" "$WORK/tree-gcc/gcc-${GCC_VER}"
  mv "gmp-${GMP_VER}" gmp
  mv "mpfr-${MPFR_VER}" mpfr
  mv "mpc-${MPC_VER}" mpc
  mv "isl-${ISL_VER}" isl

  cd "$BLD/gcc-stage1"
  "$WORK/tree-gcc/gcc-${GCC_VER}/configure" \
    --prefix="$CROSS_PREFIX" \
    --target="$TARGET" \
    --with-sysroot="$SYSROOT" \
    --disable-nls \
    --disable-multilib \
    --enable-languages=c \
    --without-headers \
    --with-newlib \
    --disable-shared \
    --disable-threads \
    --disable-libsanitizer \
    --disable-libquadmath \
    --disable-libgomp \
    --disable-libstdcxx-v3 \
    --disable-werror

  make -j"$JOBS" all-gcc
  make install-gcc
}

build_musl() {
  msg "=== musl ${MUSL_VER} (install into sysroot) ==="
  clean_dir "$BLD/musl"
  clean_dir "$WORK/tree-musl"

  fetch "$U_MUSL"
  extract "$SRC/musl-${MUSL_VER}.tar.gz" "$WORK/tree-musl"

  cd "$WORK/tree-musl/musl-${MUSL_VER}"
  apply_musl_security_patches

  # Configure/build with cross compiler
  CC="$TARGET-gcc" \
  ./configure --prefix=/usr --syslibdir=/lib

  make -j"$JOBS"
  make DESTDIR="$SYSROOT" install
}

build_gcc_stage2() {
  msg "=== gcc ${GCC_VER} stage2 (C,C++ with musl) ==="
  clean_dir "$BLD/gcc-stage2"
  cd "$BLD/gcc-stage2"

  "$WORK/tree-gcc/gcc-${GCC_VER}/configure" \
    --prefix="$CROSS_PREFIX" \
    --target="$TARGET" \
    --with-sysroot="$SYSROOT" \
    --disable-nls \
    --disable-multilib \
    --enable-languages=c,c++ \
    --enable-shared \
    --enable-threads=posix \
    --enable-__cxa_atexit \
    --enable-lto \
    --enable-plugin \
    --disable-werror

  make -j"$JOBS"
  make install
}

install_busybox_static() {
  msg "=== busybox ${BUSYBOX_VER} (static, for chroot usability) ==="
  clean_dir "$BLD/busybox"
  clean_dir "$WORK/tree-busybox"

  fetch "$U_BUSYBOX"
  extract "$SRC/busybox-${BUSYBOX_VER}.tar.bz2" "$WORK/tree-busybox"
  cd "$WORK/tree-busybox/busybox-${BUSYBOX_VER}"

  make distclean >/dev/null 2>&1 || true
  make defconfig

  # force static + use cross compiler
  sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config || true
  # disable stuff that often needs extra libs (keep minimal)
  sed -i 's/^CONFIG_FEATURE_WGET_LONG_OPTIONS=y/# CONFIG_FEATURE_WGET_LONG_OPTIONS is not set/' .config || true

  make -j"$JOBS" CROSS_COMPILE="$TARGET-"
  make CROSS_COMPILE="$TARGET-" CONFIG_PREFIX="$SYSROOT" install

  # Ensure /bin/sh exists
  [ -x "$SYSROOT/bin/busybox" ] || die "busybox não instalado corretamente"
  ln -sf busybox "$SYSROOT/bin/sh"

  # Minimal /etc files
  mkdir -p "$SYSROOT/etc"
  [ -f "$SYSROOT/etc/passwd" ] || cat >"$SYSROOT/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
  [ -f "$SYSROOT/etc/group" ] || cat >"$SYSROOT/etc/group" <<'EOF'
root:x:0:
EOF
}

install_toolchain_into_sysroot() {
  msg "=== instalando toolchain cross dentro do sysroot (para uso no chroot) ==="
  mkdir -p "$SYSROOT/opt"
  rm -rf "$SYSROOT/opt/adm-cross" 2>/dev/null || true
  cp -a "$CROSS_PREFIX" "$SYSROOT/opt/adm-cross"

  # perfil simples pra ativar toolchain no chroot
  mkdir -p "$SYSROOT/etc/profile.d"
  cat >"$SYSROOT/etc/profile.d/adm-cross.sh" <<EOF
export PATH=/opt/adm-cross/bin:/usr/bin:/bin
export CC=${TARGET}-gcc
export CXX=${TARGET}-g++
export AR=${TARGET}-ar
export RANLIB=${TARGET}-ranlib
export LD=${TARGET}-ld
EOF
}

handoff_to_adm() {
  msg "=== preparando sysroot para o adm assumir ==="
  mkdir -p "$SYSROOT/usr/local/ports"
  mkdir -p "$SYSROOT/usr/share/adm"
  mkdir -p "$SYSROOT/var/db/adm" "$SYSROOT/var/cache/adm" "$SYSROOT/var/log/adm"

  msg "copiando adm do host para o sysroot (ajuste se seus caminhos forem diferentes)"
  [ -x /usr/sbin/adm ] || msg "AVISO: /usr/sbin/adm não existe no host; copie manualmente depois."
  [ -f /usr/share/adm/helpers.sh ] || msg "AVISO: /usr/share/adm/helpers.sh não existe no host; copie manualmente depois."

  if [ -x /usr/sbin/adm ]; then
    install -Dm755 /usr/sbin/adm "$SYSROOT/usr/sbin/adm"
  fi
  if [ -f /usr/share/adm/helpers.sh ]; then
    install -Dm644 /usr/share/adm/helpers.sh "$SYSROOT/usr/share/adm/helpers.sh"
  fi

  # symlink convenientes
  mkdir -p "$SYSROOT/usr/bin"
  ln -sf ../sbin/adm "$SYSROOT/usr/bin/adm" || true
}

final_instructions() {
  cat >&2 <<EOF

========================================
BOOTSTRAP CONCLUÍDO
Sysroot:      $SYSROOT
Cross prefix: $CROSS_PREFIX
Target:       $TARGET
========================================

1) Monte pseudo-fs e entre no chroot:

  mount --bind /dev  $SYSROOT/dev
  mount --bind /proc $SYSROOT/proc
  mount --bind /sys  $SYSROOT/sys

  chroot $SYSROOT /bin/sh -l

2) Dentro do chroot, ative toolchain (se seu shell não carrega profile.d automaticamente):
  . /etc/profile.d/adm-cross.sh

3) Teste:
  $TARGET-gcc --version
  /bin/sh --version  (ou busybox)
  /opt/adm-cross/bin/$TARGET-gcc -v

4) Agora use o adm normalmente (ports nativos dentro do chroot):
  adm sync
  adm install core/make core/pkgconf core/zlib core/xz core/zstd core/bzip2 core/ncurses
  ...e assim por diante.

Quando seu sistema estiver nativo completo, você pode decidir remover /opt/adm-cross.
EOF
}

main() {
  need_root
  need sh tar make patch sed awk grep gcc g++ ar ranlib ld
  need curl || need wget

  mkdir -p "$WORK" "$SRC" "$BLD" "$LOG"

  ensure_sysroot_layout
  copy_kernel_headers_from_host

  build_binutils
  build_gcc_stage1
  build_musl
  build_gcc_stage2

  install_busybox_static
  install_toolchain_into_sysroot
  handoff_to_adm

  final_instructions
}

main "$@"
