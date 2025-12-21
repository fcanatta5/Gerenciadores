#!/bin/sh
# bootstrap-cross.sh — bootstrap cross toolchain for x86_64-linux-musl
# POSIX sh, deterministic, resumable (stamps), with source verification (sha256),
# robust extraction, idempotent patching, and stronger sanity checks.
#
# Default target: x86_64-linux-musl (no multilib).
#
# Layout:
#   WORK/
#     dl/        downloaded tarballs
#     src/       extracted source trees (normalized)
#     bld/       build directories (per step)
#     tools/     cross tools prefix (host side)
#     sysroot/   target sysroot (DESTDIR-like)
#     state/     stamps + logs
#
# Usage:
#   ./bootstrap-cross.sh [command]
#
# Commands:
#   all (default)     Run full bootstrap
#   sources           Fetch+verify+extract sources
#   binutils          Build/install binutils
#   linux-headers     Install Linux UAPI headers into sysroot
#   gcc-stage1        Build/install GCC stage1 (no libc)
#   musl              Build/install musl into sysroot (with patches)
#   gcc-final         Build/install full GCC against musl
#   xz                Build/install xz (target) into sysroot
#   busybox           Build/install busybox (target) into sysroot
#   sanity            Compile/link smoke tests
#   clean             Remove build dirs (keeps downloads/sources/state)
#   distclean         Remove everything under WORK
#
# Environment overrides (sane defaults):
#   TARGET=x86_64-linux-musl
#   WORK=$PWD/work
#   DL=$WORK/dl
#   SRC=$WORK/src
#   BLD=$WORK/bld
#   TOOLS=$WORK/tools
#   SYSROOT=$WORK/sysroot
#   STATE=$WORK/state
#   MAKEJOBS= (auto: nproc or 4)
#   CLEAN_BUILD=1 (default) remove build dir per step; 0 keeps for debugging
#   STRICT_HEADERS_CHECK=0 (default) if 1, fail on linux headers_check
#   GCC_FETCH_DEPS=0 (default) if 1, runs contrib/download_prerequisites (still verified only if you add hashes)
#
# Security:
# - All primary tarballs are sha256-verified before extraction.
# - If you enable GCC_FETCH_DEPS=1, GCC contrib may fetch extra tarballs.
#   For strict supply-chain, keep it 0 and vendor deps yourself.

set -eu

# ---------- Configuration ----------
TARGET=${TARGET:-x86_64-linux-musl}

WORK=${WORK:-"$PWD/work"}
DL=${DL:-"$WORK/dl"}
SRC=${SRC:-"$WORK/src"}
BLD=${BLD:-"$WORK/bld"}
TOOLS=${TOOLS:-"$WORK/tools"}
SYSROOT=${SYSROOT:-"$WORK/sysroot"}
STATE=${STATE:-"$WORK/state"}

CLEAN_BUILD=${CLEAN_BUILD:-1}
STRICT_HEADERS_CHECK=${STRICT_HEADERS_CHECK:-0}
GCC_FETCH_DEPS=${GCC_FETCH_DEPS:-0}

# Versions (edit here)
BINUTILS_VER=${BINUTILS_VER:-2.45.1}
LINUX_VER=${LINUX_VER:-6.18.1}
MUSL_VER=${MUSL_VER:-1.2.5}
GCC_VER=${GCC_VER:-15.2.0}
XZ_VER=${XZ_VER:-5.6.2}
BUSYBOX_VER=${BUSYBOX_VER:-1.36.1}

# URLs
BINUTILS_URL=${BINUTILS_URL:-"https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_VER.tar.xz"}
GCC_URL=${GCC_URL:-"https://ftp.gnu.org/gnu/gcc/gcc-$GCC_VER/gcc-$GCC_VER.tar.xz"}
LINUX_URL=${LINUX_URL:-"https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$LINUX_VER.tar.xz"}
MUSL_URL=${MUSL_URL:-"https://musl.libc.org/releases/musl-$MUSL_VER.tar.gz"}
XZ_URL=${XZ_URL:-"https://tukaani.org/xz/xz-$XZ_VER.tar.xz"}
BUSYBOX_URL=${BUSYBOX_URL:-"https://busybox.net/downloads/busybox-$BUSYBOX_VER.tar.bz2"}

# ---------- SHA256 (YOU MUST KEEP THESE UPDATED) ----------
# If you do not know the hashes yet, you must fill them before running.
# You can temporarily set SKIP_VERIFY=1 to bypass, but that defeats the point.
SKIP_VERIFY=${SKIP_VERIFY:-0}

# Put exact sha256 sums here:
BINUTILS_SHA256=${BINUTILS_SHA256:-""}
GCC_SHA256=${GCC_SHA256:-""}
LINUX_SHA256=${LINUX_SHA256:-""}
MUSL_SHA256=${MUSL_SHA256:-""}
XZ_SHA256=${XZ_SHA256:-""}
BUSYBOX_SHA256=${BUSYBOX_SHA256:-""}

# ---------- Musl security patches (embedded examples) ----------
# Replace these with your real patches. Keep them minimal and audited.
# The script applies them idempotently with stamps.
MUSL_PATCH1_NAME="musl-security-0001.patch"
MUSL_PATCH2_NAME="musl-security-0002.patch"

MUSL_PATCH1_CONTENT='
*** a/README
--- b/README
***************
*** 1,3 ****
--- 1,4 ----
+ (placeholder patch 0001) Replace with real security patch.
  musl libc
'

MUSL_PATCH2_CONTENT='
*** a/README
--- b/README
***************
*** 1,3 ****
--- 1,4 ----
+ (placeholder patch 0002) Replace with real security patch.
  musl libc
'

# ---------- Utility ----------
msg()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_dir() { [ -d "$1" ] || die "missing directory: $1"; }
ensure_dir() { [ -d "$1" ] || mkdir -p "$1"; }

# best-effort jobs
detect_jobs() {
  if [ -n "${MAKEJOBS:-}" ]; then
    printf '%s\n' "$MAKEJOBS"
    return 0
  fi
  if command -v nproc >/dev/null 2>&1; then
    nproc
  else
    printf '%s\n' 4
  fi
}

MAKEJOBS=$(detect_jobs)

host_env() {
  # Prepend tools/bin for subsequent steps
  PATH="$TOOLS/bin:$PATH"
  export PATH
}

make_env() {
  # Many builds honor MAKEFLAGS; also pass -j explicitly where it matters.
  MAKEFLAGS=${MAKEFLAGS:-}
  MAKEFLAGS="-j$MAKEJOBS $MAKEFLAGS"
  export MAKEFLAGS
}

runlog() {
  step=$1; shift
  ensure_dir "$STATE/log"
  log="$STATE/log/$step.log"

  msg "==> $step"
  msg "    log: $log"
  ( "$@" ) >"$log" 2>&1 || {
    tail -n 80 "$log" >&2 || true
    die "step failed: $step (see log)"
  }
}

stamp_has() { [ -f "$STATE/$1.ok" ]; }
stamp_set() { ensure_dir "$STATE"; : >"$STATE/$1.ok"; }

clean_builddir() {
  [ "$CLEAN_BUILD" -eq 1 ] || return 0
  d=$1
  rm -rf "$d" 2>/dev/null || true
}

# ---------- Fetch / Verify / Extract ----------
fetch_one() {
  url=$1
  out=$2

  if [ -s "$out" ]; then
    return 0
  fi

  need_cmd sh
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 3 --connect-timeout 15 --max-time 1800 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    die "need curl or wget"
  fi
}

verify_sha256() {
  file=$1
  want=$2
  [ -s "$file" ] || die "missing file for sha256 verify: $file"

  if [ "$SKIP_VERIFY" -eq 1 ]; then
    warn "SKIP_VERIFY=1: skipping sha256 verification for $file"
    return 0
  fi

  [ -n "$want" ] || die "sha256 not set for $file (set *_SHA256 vars)"

  need_cmd sha256sum
  got=$(sha256sum "$file" | awk '{print $1}')
  [ "$got" = "$want" ] || die "sha256 mismatch for $file: got $got want $want"
}

tar_topdir() {
  # prints the top-level directory name inside a tarball, best-effort
  t=$1
  need_cmd tar
  # handle tar with any compression: rely on tar -tf (GNU tar/bsdtar)
  top=$(tar -tf "$t" 2>/dev/null | head -n 1 | awk -F/ '{print $1}')
  [ -n "$top" ] || die "could not determine topdir for: $t"
  printf '%s\n' "$top"
}

extract_tar() {
  tarball=$1
  outdir=$2
  expect=$3   # desired normalized directory name under $SRC

  need_cmd tar

  ensure_dir "$outdir"
  top=$(tar_topdir "$tarball")

  # If already extracted into expected name, nothing to do
  if [ -d "$outdir/$expect" ]; then
    return 0
  fi

  # Extract into SRC, then normalize to $expect
  # Use a temporary extract directory to avoid partial states on failure.
  tmp="$outdir/.extract.$$"
  rm -rf "$tmp" 2>/dev/null || true
  ensure_dir "$tmp"

  tar -xf "$tarball" -C "$tmp"

  if [ ! -d "$tmp/$top" ]; then
    rm -rf "$tmp" 2>/dev/null || true
    die "unexpected tar layout: $tarball (topdir $top missing after extract)"
  fi

  # Move into normalized name (atomic-ish)
  rm -rf "$outdir/$expect" 2>/dev/null || true
  mv "$tmp/$top" "$outdir/$expect"
  rm -rf "$tmp" 2>/dev/null || true
}

ensure_src() {
  name=$1
  ver=$2
  url=$3
  sha=$4
  ext=$5   # filename suffix (informational)
  tarball="$DL/$name-$ver.$ext"
  srcdir="$SRC/$name-$ver"

  ensure_dir "$DL"
  ensure_dir "$SRC"

  fetch_one "$url" "$tarball"
  verify_sha256 "$tarball" "$sha"
  extract_tar "$tarball" "$SRC" "$name-$ver"
  [ -d "$srcdir" ] || die "source dir missing after extract: $srcdir"
}

# ---------- Musl patches (idempotent) ----------
write_patch_file() {
  # $1 path, $2 content
  p=$1
  ensure_dir "$(dirname "$p")"
  : >"$p"
  # shellcheck disable=SC2001
  printf '%s\n' "$2" | sed '1{/^$/d;}' >>"$p"
}

apply_patch_idempotent() {
  srcdir=$1
  patchfile=$2
  stamp=$3

  if stamp_has "$stamp"; then
    return 0
  fi

  need_cmd patch
  # dry-run first for idempotency
  if (cd "$srcdir" && patch -p1 --dry-run <"$patchfile" >/dev/null 2>&1); then
    (cd "$srcdir" && patch -p1 <"$patchfile")
    stamp_set "$stamp"
    return 0
  fi

  # If it fails dry-run, check if it is already applied (reverse dry-run)
  if (cd "$srcdir" && patch -p1 -R --dry-run <"$patchfile" >/dev/null 2>&1); then
    # already applied
    stamp_set "$stamp"
    return 0
  fi

  die "patch failed (not applicable and not already applied): $patchfile"
}

apply_musl_security_patches() {
  musl_src=$1

  p1="$STATE/$MUSL_PATCH1_NAME"
  p2="$STATE/$MUSL_PATCH2_NAME"
  ensure_dir "$STATE"

  write_patch_file "$p1" "$MUSL_PATCH1_CONTENT"
  write_patch_file "$p2" "$MUSL_PATCH2_CONTENT"

  apply_patch_idempotent "$musl_src" "$p1" "musl.patch1"
  apply_patch_idempotent "$musl_src" "$p2" "musl.patch2"
}

# ---------- Steps ----------
step_sources() {
  ensure_dir "$WORK" "$DL" "$SRC" "$BLD" "$TOOLS" "$SYSROOT" "$STATE"

  ensure_src "binutils" "$BINUTILS_VER" "$BINUTILS_URL" "$BINUTILS_SHA256" "tar.xz"
  ensure_src "linux"    "$LINUX_VER"    "$LINUX_URL"    "$LINUX_SHA256"    "tar.xz"
  ensure_src "musl"     "$MUSL_VER"     "$MUSL_URL"     "$MUSL_SHA256"     "tar.gz"
  ensure_src "gcc"      "$GCC_VER"      "$GCC_URL"      "$GCC_SHA256"      "tar.xz"
  ensure_src "xz"       "$XZ_VER"       "$XZ_URL"       "$XZ_SHA256"       "tar.xz"
  ensure_src "busybox"  "$BUSYBOX_VER"  "$BUSYBOX_URL"  "$BUSYBOX_SHA256"  "tar.bz2"

  stamp_set "sources"
}

step_binutils() {
  host_env
  make_env

  s="$SRC/binutils-$BINUTILS_VER"
  b="$BLD/binutils-$BINUTILS_VER"
  clean_builddir "$b"
  ensure_dir "$b"

  (cd "$b" && \
    "$s/configure" \
      --target="$TARGET" \
      --prefix="$TOOLS" \
      --with-sysroot="$SYSROOT" \
      --disable-multilib \
      --disable-nls \
      --disable-werror)

  (cd "$b" && make -j"$MAKEJOBS")
  (cd "$b" && make install)

  stamp_set "binutils"
}

step_linux_headers() {
  make_env

  s="$SRC/linux-$LINUX_VER"
  b="$BLD/linux-headers-$LINUX_VER"
  clean_builddir "$b"
  ensure_dir "$b"

  # Linux headers are installed from source tree; use O= build dir
  # Ensure clean O= dir
  rm -rf "$b" 2>/dev/null || true
  ensure_dir "$b"

  # headers_check can be noisy/fail depending on kernel release; make it configurable
  if [ "$STRICT_HEADERS_CHECK" -eq 1 ]; then
    (cd "$s" && make O="$b" ARCH=x86 headers_check)
  else
    (cd "$s" && make O="$b" ARCH=x86 headers_check) || warn "linux headers_check failed (STRICT_HEADERS_CHECK=0)"
  fi

  (cd "$s" && make O="$b" ARCH=x86 \
      INSTALL_HDR_PATH="$SYSROOT/usr" headers_install)

  # Lint checks (policy)
  [ -f "$SYSROOT/usr/include/linux/version.h" ] || die "linux-headers: missing linux/version.h in sysroot"
  [ -f "$SYSROOT/usr/include/asm/unistd.h" ] || warn "linux-headers: missing asm/unistd.h (arch layout may vary)"
  [ -f "$SYSROOT/usr/include/linux/limits.h" ] || warn "linux-headers: missing linux/limits.h"

  stamp_set "linux-headers"
}

step_gcc_stage1() {
  host_env
  make_env

  s="$SRC/gcc-$GCC_VER"

  if [ "$GCC_FETCH_DEPS" -eq 1 ]; then
    # WARNING: this pulls extra tarballs; for strict supply-chain, keep 0.
    if [ -x "$s/contrib/download_prerequisites" ]; then
      (cd "$s" && ./contrib/download_prerequisites)
    else
      die "GCC_FETCH_DEPS=1 but contrib/download_prerequisites not found"
    fi
  fi

  b="$BLD/gcc-stage1-$GCC_VER"
  clean_builddir "$b"
  ensure_dir "$b"

  (cd "$b" && \
    "$s/configure" \
      --target="$TARGET" \
      --prefix="$TOOLS" \
      --with-sysroot="$SYSROOT" \
      --disable-multilib \
      --disable-nls \
      --disable-libsanitizer \
      --disable-libssp \
      --disable-libgomp \
      --disable-libquadmath \
      --disable-shared \
      --disable-threads \
      --enable-languages=c \
      --without-headers)

  (cd "$b" && make -j"$MAKEJOBS" all-gcc)
  (cd "$b" && make install-gcc)

  # Build & install libgcc (minimal) so musl can link later
  (cd "$b" && make -j"$MAKEJOBS" all-target-libgcc)
  (cd "$b" && make install-target-libgcc)

  stamp_set "gcc-stage1"
}

step_musl() {
  host_env
  make_env

  s="$SRC/musl-$MUSL_VER"
  apply_musl_security_patches "$s"

  b="$BLD/musl-$MUSL_VER"
  clean_builddir "$b"
  ensure_dir "$b"

  # musl builds in-tree; use a clean copy build dir by rsync/tar if needed.
  # For simplicity: build in separate dir via "cp -a" of source (portable enough).
  # Keep idempotent: rebuild clean each time.
  rm -rf "$b/src" 2>/dev/null || true
  ensure_dir "$b/src"
  (cd "$b" && tar -cf - -C "$s" . | tar -xf - -C "$b/src")

  ms="$b/src"

  # Use --host for clarity/compat.
  (cd "$ms" && \
    CC="$TARGET-gcc" \
    AR="$TARGET-ar" \
    RANLIB="$TARGET-ranlib" \
    ./configure \
      --host="$TARGET" \
      --prefix=/usr \
      --syslibdir=/lib)

  (cd "$ms" && make -j"$MAKEJOBS")
  (cd "$ms" && DESTDIR="$SYSROOT" make install)

  # Lint checks (policy)
  # loader
  if ls "$SYSROOT/lib/ld-musl-"*.so.1 >/dev/null 2>&1; then
    :
  else
    die "musl: missing ld-musl-*.so.1 in $SYSROOT/lib"
  fi
  # libc + crt objects
  [ -f "$SYSROOT/lib/libc.so" ] || [ -f "$SYSROOT/usr/lib/libc.so" ] || warn "musl: libc.so not found (may be non-symlinked layout)"
  [ -f "$SYSROOT/usr/lib/crt1.o" ] || die "musl: missing crt1.o"
  [ -f "$SYSROOT/usr/include/bits/alltypes.h" ] || die "musl: missing bits/alltypes.h"

  stamp_set "musl"
}

step_gcc_final() {
  host_env
  make_env

  s="$SRC/gcc-$GCC_VER"
  b="$BLD/gcc-final-$GCC_VER"
  clean_builddir "$b"
  ensure_dir "$b"

  # Ensure target tools resolve to our $TOOLS first
  export PATH="$TOOLS/bin:$PATH"

  # Favor deterministic target flags
  CFLAGS_FOR_TARGET=${CFLAGS_FOR_TARGET:-"-O2"}
  LDFLAGS_FOR_TARGET=${LDFLAGS_FOR_TARGET:-""}
  export CFLAGS_FOR_TARGET LDFLAGS_FOR_TARGET

  (cd "$b" && \
    "$s/configure" \
      --target="$TARGET" \
      --prefix="$TOOLS" \
      --with-sysroot="$SYSROOT" \
      --disable-multilib \
      --disable-nls \
      --disable-libsanitizer \
      --enable-languages=c,c++)

  (cd "$b" && make -j"$MAKEJOBS")
  (cd "$b" && make install)

  stamp_set "gcc-final"
}

step_xz_target() {
  host_env
  make_env

  s="$SRC/xz-$XZ_VER"
  b="$BLD/xz-$XZ_VER"
  clean_builddir "$b"
  ensure_dir "$b"

  (cd "$b" && \
    CC="$TARGET-gcc --sysroot=$SYSROOT" \
    AR="$TARGET-ar" RANLIB="$TARGET-ranlib" \
    "$s/configure" \
      --host="$TARGET" \
      --prefix=/usr \
      --disable-shared \
      --enable-static)

  (cd "$b" && make -j"$MAKEJOBS")
  (cd "$b" && DESTDIR="$SYSROOT" make install)

  # strict presence check
  [ -x "$SYSROOT/usr/bin/xz" ] || [ -x "$SYSROOT/bin/xz" ] || die "xz: missing xz binary in sysroot"

  stamp_set "xz"
}

step_busybox() {
  host_env
  make_env

  s="$SRC/busybox-$BUSYBOX_VER"
  b="$BLD/busybox-$BUSYBOX_VER"
  clean_builddir "$b"
  ensure_dir "$b"

  # BusyBox builds in-tree; use a clean copy to keep source pristine and repeatable
  rm -rf "$b/src" 2>/dev/null || true
  ensure_dir "$b/src"
  (cd "$b" && tar -cf - -C "$s" . | tar -xf - -C "$b/src")
  bs="$b/src"

  # Clean any prior config/build artifacts
  (cd "$bs" && make distclean >/dev/null 2>&1 || true)

  # Write deterministic "base system" config (for /bin,/sbin chroot usability)
  cat >"$bs/.config" <<'EOF'
# BusyBox Configuration
# Base for minimal system: /bin,/sbin, static, init+shell+mount+dev+network.

CONFIG_HAVE_DOT_CONFIG=y
CONFIG_DESKTOP=y
CONFIG_EXTRA_COMPAT=y
CONFIG_LONG_OPTS=y
CONFIG_SHOW_USAGE=y
CONFIG_FEATURE_VERBOSE_USAGE=y
CONFIG_FEATURE_COMPRESS_USAGE=y
CONFIG_FEATURE_EDITING=y
CONFIG_FEATURE_EDITING_VI=y
CONFIG_FEATURE_EDITING_HISTORY=256
CONFIG_FEATURE_TAB_COMPLETION=y
CONFIG_FEATURE_USERNAME_COMPLETION=y

CONFIG_STATIC=y
CONFIG_PIE=n
CONFIG_NOMMU=n

CONFIG_PREFIX="./_install"

CONFIG_FEATURE_SYSLOG=y
CONFIG_FEATURE_SYSLOG_INFO=y
CONFIG_SYSLOGD=y
CONFIG_FEATURE_ROTATE_LOGFILE=y
CONFIG_LOGREAD=y
CONFIG_KLOGD=y

CONFIG_INIT=y
CONFIG_FEATURE_USE_INITTAB=y
CONFIG_FEATURE_INIT_SCTTY=y
CONFIG_FEATURE_INIT_SYSLOG=y
CONFIG_HALT=y
CONFIG_POWEROFF=y
CONFIG_REBOOT=y

CONFIG_ASH=y
CONFIG_ASH_OPTIMIZE_FOR_SIZE=y
CONFIG_ASH_INTERNAL_GLOB=y
CONFIG_ASH_BASH_COMPAT=y
CONFIG_ASH_JOB_CONTROL=y
CONFIG_ASH_ALIAS=y
CONFIG_ASH_GETOPTS=y
CONFIG_ASH_PRINTF=y
CONFIG_ASH_TEST=y
CONFIG_ASH_CMDCMD=y
CONFIG_ASH_EXPAND_PRMT=y
CONFIG_SH_IS_ASH=y

CONFIG_CAT=y
CONFIG_CHGRP=y
CONFIG_CHMOD=y
CONFIG_CHOWN=y
CONFIG_CP=y
CONFIG_MV=y
CONFIG_RM=y
CONFIG_LN=y
CONFIG_MKDIR=y
CONFIG_RMDIR=y
CONFIG_TOUCH=y
CONFIG_SYNC=y
CONFIG_DD=y
CONFIG_FEATURE_DD_SIGNAL_HANDLING=y
CONFIG_FEATURE_DD_IBS_OBS=y

CONFIG_ECHO=y
CONFIG_PRINTF=y
CONFIG_PWD=y
CONFIG_BASENAME=y
CONFIG_DIRNAME=y
CONFIG_TRUE=y
CONFIG_FALSE=y
CONFIG_UNAME=y
CONFIG_DATE=y
CONFIG_SLEEP=y
CONFIG_USLEEP=y
CONFIG_TIME=y

CONFIG_LS=y
CONFIG_FEATURE_LS_FILETYPES=y
CONFIG_FEATURE_LS_FOLLOWLINKS=y
CONFIG_FEATURE_LS_RECURSIVE=y
CONFIG_FEATURE_LS_WIDTH=y
CONFIG_FEATURE_LS_SORTFILES=y
CONFIG_FEATURE_LS_TIMESTAMPS=y

CONFIG_HEAD=y
CONFIG_TAIL=y
CONFIG_FEATURE_FANCY_HEAD=y
CONFIG_FEATURE_FANCY_TAIL=y
CONFIG_CUT=y
CONFIG_PASTE=y
CONFIG_SORT=y
CONFIG_UNIQ=y
CONFIG_TR=y
CONFIG_WC=y
CONFIG_OD=y
CONFIG_HEXDUMP=y
CONFIG_STRINGS=y

CONFIG_TEE=y
CONFIG_XARGS=y
CONFIG_FIND=y
CONFIG_FEATURE_FIND_PRINT0=y
CONFIG_GREP=y
CONFIG_EGREP=y
CONFIG_FGREP=y
CONFIG_FEATURE_GREP_EGREP_ALIAS=y
CONFIG_SED=y
CONFIG_AWK=y

CONFIG_MOUNT=y
CONFIG_UMOUNT=y
CONFIG_SWAPON=y
CONFIG_SWAPOFF=y
CONFIG_MKFS_EXT2=y
CONFIG_FSCK=y
CONFIG_FEATURE_MOUNT_LOOP=y
CONFIG_FEATURE_MOUNT_LABEL=y
CONFIG_FEATURE_MOUNT_FSTAB=y
CONFIG_FEATURE_MOUNT_OTHERTAB=y

CONFIG_MDEV=y
CONFIG_FEATURE_MDEV_CONF=y
CONFIG_FEATURE_MDEV_RENAME=y
CONFIG_FEATURE_MDEV_EXEC=y
CONFIG_FEATURE_MDEV_LOAD_FIRMWARE=y

CONFIG_LSMOD=y
CONFIG_INSMOD=y
CONFIG_RMMOD=y
CONFIG_MODPROBE=y
CONFIG_FEATURE_MODPROBE_BLACKLIST=y
CONFIG_FEATURE_MODUTILS_ALIAS=y

CONFIG_SYSCTL=y
CONFIG_DMESG=y

CONFIG_PS=y
CONFIG_TOP=y
CONFIG_FREE=y
CONFIG_UPTIME=y
CONFIG_KILL=y
CONFIG_KILLALL=y
CONFIG_PKILL=y
CONFIG_PGREP=y
CONFIG_RENICE=y
CONFIG_NICE=y
CONFIG_NOHUP=y

CONFIG_WATCH=y
CONFIG_TIMEOUT=y

CONFIG_ID=y
CONFIG_WHOAMI=y
CONFIG_WHO=y
CONFIG_GROUPS=y
CONFIG_ADDUSER=y
CONFIG_ADDGROUP=y
CONFIG_DELUSER=y
CONFIG_DELGROUP=y
CONFIG_PASSWD=y
CONFIG_SU=y
CONFIG_LOGIN=y
CONFIG_GETTY=y

CONFIG_IFCONFIG=y
CONFIG_ROUTE=y
CONFIG_IP=y
CONFIG_FEATURE_IP_ADDRESS=y
CONFIG_FEATURE_IP_LINK=y
CONFIG_FEATURE_IP_ROUTE=y
CONFIG_FEATURE_IP_NEIGH=y

CONFIG_PING=y
CONFIG_PING6=y
CONFIG_TRACEROUTE=y
CONFIG_TRACEROUTE6=y
CONFIG_NETSTAT=y
CONFIG_SS=y
CONFIG_NSLOOKUP=y
CONFIG_WGET=y
CONFIG_FEATURE_WGET_LONG_OPTIONS=y
CONFIG_FEATURE_WGET_STATUSBAR=y
CONFIG_FEATURE_WGET_TIMEOUT=y

CONFIG_TELNET=y
CONFIG_TELNETD=y
CONFIG_FTPGET=y
CONFIG_FTPPUT=y

CONFIG_UDHCPC=y
CONFIG_FEATURE_UDHCPC_ARPING=y
CONFIG_FEATURE_UDHCPC_SANITIZEOPT=y

CONFIG_TAR=y
CONFIG_FEATURE_TAR_LONG_OPTIONS=y
CONFIG_FEATURE_TAR_CREATE=y
CONFIG_FEATURE_TAR_GZIP=y
CONFIG_FEATURE_TAR_BZIP2=y
CONFIG_FEATURE_TAR_XZ=y
CONFIG_GUNZIP=y
CONFIG_GZIP=y
CONFIG_BUNZIP2=y
CONFIG_UNXZ=y
CONFIG_XZCAT=y

CONFIG_VI=y
CONFIG_FEATURE_VI_MAX_LEN=4096
CONFIG_NANO=y

CONFIG_TEST=y
CONFIG_FEATURE_TEST_64=y
CONFIG_EXPR=y
CONFIG_DC=y
CONFIG_HOSTNAME=y
CONFIG_CLEAR=y
CONFIG_RESET=y

CONFIG_FEATURE_SH_STANDALONE=y
EOF

  # Normalize config for this BusyBox version (auto-accept defaults for new symbols)
  (cd "$bs" && yes "" | make oldconfig >/dev/null)

  # Build (static) with cross compiler against sysroot
  (cd "$bs" && \
    make -j"$MAKEJOBS" \
      CROSS_COMPILE="$TARGET-" \
      CC="$TARGET-gcc --sysroot=$SYSROOT" \
      ARCH=x86_64)

  # Install into sysroot. BusyBox uses CONFIG_PREFIX; do NOT mix DESTDIR.
  (cd "$bs" && make CONFIG_PREFIX="$SYSROOT" install)

  # --- Minimal policy checks for chroot usability (/bin,/sbin) ---
  [ -x "$SYSROOT/bin/busybox" ] || die "busybox: missing $SYSROOT/bin/busybox"

  # Ensure /bin/sh exists (symlink created by install if the applet is enabled)
  if [ ! -e "$SYSROOT/bin/sh" ]; then
    die "busybox: missing /bin/sh in sysroot (expected symlink to busybox)"
  fi

  # Ensure applet links exist in /bin and /sbin (at least some)
  if ! find "$SYSROOT/bin" "$SYSROOT/sbin" -maxdepth 1 -type l 2>/dev/null | grep -q .; then
    die "busybox: no applet symlinks found in /bin or /sbin"
  fi

  # Ensure the busybox binary actually contains 'sh' applet
  if [ -x "$SYSROOT/bin/busybox" ]; then
    if ! "$SYSROOT/bin/busybox" --list 2>/dev/null | awk '$0=="sh"{found=1} END{exit found?0:1}'; then
      die "busybox: 'sh' applet not present (check config)"
    fi
  fi

  stamp_set "busybox"
}

step_sanity() {
  host_env

  # Ensure toolchain is there
  need_cmd "$TARGET-gcc"
  need_cmd "$TARGET-ld" || true

  tdir="$BLD/sanity"
  rm -rf "$tdir" 2>/dev/null || true
  ensure_dir "$tdir"

  cat >"$tdir/t.c" <<'EOF'
#include <stdio.h>
int main(void){ puts("ok"); return 0; }
EOF

  out="$tdir/t"
  "$TARGET-gcc" --sysroot="$SYSROOT" -static -O2 "$tdir/t.c" -o "$out"

  [ -x "$out" ] || die "sanity: output binary missing"
  if command -v file >/dev/null 2>&1; then
    file "$out" | grep -qi 'statically linked' || warn "sanity: binary may not be static (file(1) did not report statically linked)"
  fi
  if command -v readelf >/dev/null 2>&1; then
    # should have no INTERP when static
    if readelf -l "$out" 2>/dev/null | grep -q 'INTERP'; then
      warn "sanity: INTERP present; binary may not be fully static"
    fi
    # NEEDED should be empty for truly static (often)
    if readelf -d "$out" 2>/dev/null | grep -q '(NEEDED)'; then
      warn "sanity: NEEDED entries present; binary may not be fully static"
    fi
  fi

  stamp_set "sanity"
}

# ---------- Orchestration ----------
step_all() {
  stamp_has "sources"        || runlog sources        step_sources
  stamp_has "binutils"       || runlog binutils       step_binutils
  stamp_has "linux-headers"  || runlog linux-headers  step_linux_headers
  stamp_has "gcc-stage1"     || runlog gcc-stage1     step_gcc_stage1
  stamp_has "musl"           || runlog musl           step_musl
  stamp_has "gcc-final"      || runlog gcc-final      step_gcc_final
  stamp_has "xz"             || runlog xz             step_xz_target
  stamp_has "busybox"        || runlog busybox        step_busybox
  stamp_has "sanity"         || runlog sanity         step_sanity

  msg "==> done"
  msg "TOOLS   = $TOOLS"
  msg "SYSROOT = $SYSROOT"
}

step_clean() {
  rm -rf "$BLD" 2>/dev/null || true
  ensure_dir "$BLD"
  msg "cleaned build dirs: $BLD"
}

step_distclean() {
  rm -rf "$WORK" 2>/dev/null || true
  msg "removed: $WORK"
}

# ---------- Preconditions ----------
preflight() {
  ensure_dir "$WORK" "$DL" "$SRC" "$BLD" "$TOOLS" "$SYSROOT" "$STATE"
  need_cmd tar
  need_cmd awk
  need_cmd sed
  need_cmd make
  need_cmd sha256sum
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "need curl or wget"
  fi
}

# ---------- Main ----------
cmd=${1:-all}

case "$cmd" in
  all)            preflight; step_all ;;
  sources)        preflight; runlog sources step_sources ;;
  binutils)       preflight; runlog binutils step_binutils ;;
  linux-headers)  preflight; runlog linux-headers step_linux_headers ;;
  gcc-stage1)     preflight; runlog gcc-stage1 step_gcc_stage1 ;;
  musl)           preflight; runlog musl step_musl ;;
  gcc-final)      preflight; runlog gcc-final step_gcc_final ;;
  xz)             preflight; runlog xz step_xz_target ;;
  busybox)        preflight; runlog busybox step_busybox ;;
  sanity)         preflight; runlog sanity step_sanity ;;
  clean)          step_clean ;;
  distclean)      step_distclean ;;
  -h|--help|help)
    cat <<EOF
bootstrap-cross.sh — bootstrap cross toolchain for $TARGET

Before first run: set SHA256 variables (e.g. BINUTILS_SHA256=...).

Commands:
  all (default), sources, binutils, linux-headers, gcc-stage1, musl, gcc-final, xz, busybox, sanity
  clean, distclean

Key env:
  TARGET, WORK, MAKEJOBS, CLEAN_BUILD, STRICT_HEADERS_CHECK, GCC_FETCH_DEPS
  *_VER, *_URL, *_SHA256, SKIP_VERIFY
EOF
    ;;
  *)
    die "unknown command: $cmd"
    ;;
esac
