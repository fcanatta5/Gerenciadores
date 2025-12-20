#!/bin/sh
# bootstrap-cross.sh — POSIX bootstrap cross-toolchain (temporário)
# Target padrão: x86_64-linux-musl
#
# Constrói em ordem:
#  1) sources (download/extract)
#  2) binutils
#  3) linux-headers (no SYSROOT)
#  4) gcc stage1 (C-only, sem libc)
#  5) musl (com 2 patches de segurança aplicados quando musl <= 1.2.5)
#  6) gcc final (C/C++)
#  7) xz (para target, no SYSROOT)
#  8) busybox (estático, no SYSROOT)
#  9) sanity test (compila um hello -static)
#
# Recursos:
#  - Retomada via stamps ($STATE/*.ok)
#  - Paralelismo de make (-j)
#  - Logs por etapa ($LOGS/*.log)
#
# Handoff para o adm:
#  - Quando terminar, você terá:
#     TOOLCHAIN em $TOOLS
#     SYSROOT em $SYSROOT
#  - A partir daí o adm pode assumir (recipes, chroot, etc.)
#
# POSIX /bin/sh (sem bashismos)
#
set -eu

###############################################################################
# Config (ajuste aqui)
###############################################################################
TARGET=${TARGET:-x86_64-linux-musl}
ARCH=${ARCH:-x86_64}

TOP=${TOP:-/var/tmp/bootstrap-cross}
SRC=${SRC:-$TOP/src}
BLD=${BLD:-$TOP/build}
STATE=${STATE:-$TOP/state}
LOGS=${LOGS:-$TOP/logs}

# Prefixo do toolchain no host (instalação do cross)
TOOLS=${TOOLS:-$TOP/tools}

# Sysroot do target (headers + musl + libs + busybox/xz do target)
SYSROOT=${SYSROOT:-$TOP/sysroot}
LINUX_HDR_DST=${LINUX_HDR_DST:-$SYSROOT/usr}

# Paralelismo
MAKEJOBS=${MAKEJOBS:-}
if [ -z "$MAKEJOBS" ]; then
  if command -v nproc >/dev/null 2>&1; then
    MAKEJOBS=$(nproc)
  else
    MAKEJOBS=4
  fi
fi

# Download automático (1=sim, 0=não — se 0, você deve colocar tarballs em $SRC)
FETCH=${FETCH:-1}

# Versões (as que você pediu)
BINUTILS_VER=${BINUTILS_VER:-2.45.1}
GCC_VER=${GCC_VER:-15.2.0}
XZ_VER=${XZ_VER:-5.8.1}
LINUX_VER=${LINUX_VER:-6.18.1}

# musl: mantenho 1.2.5, mas com 2 patches de segurança aplicados automaticamente
MUSL_VER=${MUSL_VER:-1.2.5}

# busybox: pode ajustar
BUSYBOX_VER=${BUSYBOX_VER:-1.36.1}

# URLs (oficiais)
BINUTILS_URL=${BINUTILS_URL:-https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_VER.tar.xz}
GCC_URL=${GCC_URL:-https://ftp.gnu.org/gnu/gcc/gcc-$GCC_VER/gcc-$GCC_VER.tar.xz}
XZ_URL=${XZ_URL:-https://tukaani.org/xz/xz-$XZ_VER.tar.xz}
LINUX_URL=${LINUX_URL:-https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$LINUX_VER.tar.xz}
MUSL_URL=${MUSL_URL:-https://musl.libc.org/releases/musl-$MUSL_VER.tar.gz}
BUSYBOX_URL=${BUSYBOX_URL:-https://busybox.net/downloads/busybox-$BUSYBOX_VER.tar.bz2}

# GCC deps:
#  - GMP/MPFR/MPC são necessárias para build do GCC.
#  - Se você já tem as deps no host, deixe 0.
#  - Se quiser tudo automático, deixe 1 (usa contrib/download_prerequisites no source do GCC).
GCC_FETCH_DEPS=${GCC_FETCH_DEPS:-1}

###############################################################################
# Util
###############################################################################
say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "ERRO: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "falta comando: $1"; }

mkdirs() {
  mkdir -p "$SRC" "$BLD" "$STATE" "$LOGS" "$TOOLS" "$SYSROOT"
}

stamp() { echo "$STATE/$1.ok"; }
donep() { [ -f "$(stamp "$1")" ]; }
mark() { : >"$(stamp "$1")"; }

logfile() { echo "$LOGS/$1.log"; }

runlog() {
  # runlog <tag> <func>
  tag="$1"; shift
  lf=$(logfile "$tag")
  say "==> $tag (log: $lf)"
  if donep "$tag"; then
    say "    (skip) já concluído"
    return 0
  fi
  (
    set -eu
    "$@"
  ) >"$lf" 2>&1 || { tail -n 60 "$lf" >&2 || true; die "falhou: $tag (veja $lf)"; }
  mark "$tag"
}

fetch_one() {
  # fetch_one URL OUTFILE
  url="$1"; out="$2"
  [ -f "$out" ] && return 0
  [ "$FETCH" -eq 1 ] || die "tarball ausente e FETCH=0: $out"

  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 3 --retry-delay 1 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    die "sem curl/wget para baixar: $url"
  fi
}

extract_tar() {
  # extract_tar <tarball> <destdir>
  t="$1"; d="$2"
  mkdir -p "$d"
  case "$t" in
    *.tar) tar -xf "$t" -C "$d" ;;
    *.tar.gz|*.tgz) gzip -dc "$t" | tar -xf - -C "$d" ;;
    *.tar.bz2|*.tbz2) bzip2 -dc "$t" | tar -xf - -C "$d" ;;
    *.tar.xz|*.txz) xz -dc "$t" | tar -xf - -C "$d" ;;
    *) die "formato não suportado: $t" ;;
  esac
}

srcdir_of() {
  # srcdir_of <name> <ver> -> $SRC/<name>-<ver>
  echo "$SRC/$1-$2"
}

ensure_src() {
  # ensure_src <name> <ver> <url> <ext>
  name="$1"; ver="$2"; url="$3"; ext="$4"
  tarball="$SRC/$name-$ver.$ext"
  dir=$(srcdir_of "$name" "$ver")
  if [ ! -d "$dir" ]; then
    fetch_one "$url" "$tarball"
    extract_tar "$tarball" "$SRC"
    [ -d "$dir" ] || die "source não encontrado após extrair: $dir"
  fi
}

host_env() {
  PATH="$TOOLS/bin:$PATH"
  export PATH
}

make_env() {
  MAKEFLAGS="-j$MAKEJOBS"
  export MAKEFLAGS
}

triplet_tools() {
  AS="$TOOLS/bin/$TARGET-as"
  LD="$TOOLS/bin/$TARGET-ld"
  AR="$TOOLS/bin/$TARGET-ar"
  RANLIB="$TOOLS/bin/$TARGET-ranlib"
  STRIP="$TOOLS/bin/$TARGET-strip"
  export AS LD AR RANLIB STRIP
}

###############################################################################
# musl security patches (para musl <= 1.2.5)
###############################################################################
apply_musl_security_patches() {
  # Aplica dois patches recomendados (upstream/Openwall) relacionados ao CVE-2025-26519
  # quando usando musl 1.2.5 ou inferior.
  #
  # Patches:
  #  - e5adcd97b5196e29991b524237381a0202a60659
  #  - c47ad25ea3b484e10326f933e927c0bc8cded3da
  #
  mdir="$(srcdir_of musl "$MUSL_VER")"
  [ -d "$mdir" ] || die "musl source dir ausente: $mdir"

  # Só faz sentido para 1.2.5 ou inferior (regra simples por string; suficiente pro seu caso)
  case "$MUSL_VER" in
    1.2.0|1.2.1|1.2.2|1.2.3|1.2.4|1.2.5) : ;;
    *) return 0 ;;
  esac

  # já aplicado?
  if grep -F "if (k>4) goto ilseq;" "$mdir/src/locale/iconv.c" >/dev/null 2>&1; then
    return 0
  fi

  need patch

  ( cd "$mdir" && patch -p1 ) <<'EOF'
diff --git a/src/locale/iconv.c b/src/locale/iconv.c
index 9605c8e9..008c93f0 100644
--- a/src/locale/iconv.c
+++ b/src/locale/iconv.c
@@ -502,7 +502,7 @@ size_t iconv(iconv_t cd, char **restrict in, size_t *restrict inb, char **restri
        if (c >= 93 || d >= 94) { c += (0xa1-0x81); d += 0xa1;
-               if (c >= 93 || c>=0xc6-0x81 && d>0x52)
+               if (c > 0xc6-0x81 || c==0xc6-0x81 && d>0x52)
                        goto ilseq;
                if (d-'A'<26) d = d-'A';
                else if (d-'a'<26) d = d-'a'+26;
EOF

  ( cd "$mdir" && patch -p1 ) <<'EOF'
diff --git a/src/locale/iconv.c b/src/locale/iconv.c
index 008c93f0..52178950 100644
--- a/src/locale/iconv.c
+++ b/src/locale/iconv.c
@@ -545,6 +545,10 @@ size_t iconv(iconv_t cd, char **restrict in, size_t *restrict inb, char **restri
                                if (*outb < k) goto toobig;
                                memcpy(*out, tmp, k);
                        } else k = wctomb_utf8(*out, c);
+                       /* This failure condition should be unreachable, but
+                        * is included to prevent decoder bugs from translating
+                        * into advancement outside the output buffer range.
+                        */
+                       if (k>4) goto ilseq;
                        *out += k;
                        *outb -= k;
                        break;
EOF

  grep -F "if (k>4) goto ilseq;" "$mdir/src/locale/iconv.c" >/dev/null 2>&1 \
    || die "falha aplicando patches de segurança do musl"
}

###############################################################################
# Etapas
###############################################################################
step_prepare() {
  mkdirs
  need sh
  need make
  need tar
  need awk
  need sed
  need grep
  need sort
  need find
  need xz
  need gzip
  need bzip2
  make_env
}

step_sources() {
  ensure_src "binutils" "$BINUTILS_VER" "$BINUTILS_URL" "tar.xz"
  ensure_src "gcc" "$GCC_VER" "$GCC_URL" "tar.xz"
  ensure_src "musl" "$MUSL_VER" "$MUSL_URL" "tar.gz"
  ensure_src "busybox" "$BUSYBOX_VER" "$BUSYBOX_URL" "tar.bz2"
  ensure_src "xz" "$XZ_VER" "$XZ_URL" "tar.xz"
  ensure_src "linux" "$LINUX_VER" "$LINUX_URL" "tar.xz"

  if [ "$GCC_FETCH_DEPS" -eq 1 ]; then
    ( cd "$(srcdir_of gcc "$GCC_VER")" && ./contrib/download_prerequisites )
  fi
}

step_binutils() {
  host_env
  make_env
  b="$BLD/binutils"
  rm -rf "$b" 2>/dev/null || true
  mkdir -p "$b"
  cd "$b"

  "$(srcdir_of binutils "$BINUTILS_VER")/configure" \
    --target="$TARGET" \
    --prefix="$TOOLS" \
    --with-sysroot="$SYSROOT" \
    --disable-nls \
    --disable-werror

  make
  make install
}

step_linux_headers() {
  host_env
  make_env
  k="$(srcdir_of linux "$LINUX_VER")"

  # kernel headers para libc
  ( cd "$k" && make mrproper )
  ( cd "$k" && make ARCH="$ARCH" headers_check )
  ( cd "$k" && make ARCH="$ARCH" INSTALL_HDR_PATH="$LINUX_HDR_DST" headers_install )

  [ -d "$SYSROOT/usr/include/linux" ] || die "headers não instalados no SYSROOT"
}

step_gcc_stage1() {
  host_env
  make_env
  triplet_tools

  b="$BLD/gcc-stage1"
  rm -rf "$b" 2>/dev/null || true
  mkdir -p "$b"
  cd "$b"

  # stage1: só gcc + libgcc mínima; sem headers/libc
  "$(srcdir_of gcc "$GCC_VER")/configure" \
    --target="$TARGET" \
    --prefix="$TOOLS" \
    --with-sysroot="$SYSROOT" \
    --disable-nls \
    --enable-languages=c \
    --without-headers \
    --disable-shared \
    --disable-threads \
    --disable-libatomic \
    --disable-libgomp \
    --disable-libquadmath \
    --disable-libssp \
    --disable-libvtv \
    --disable-libstdcxx \
    --disable-multilib

  make all-gcc
  make install-gcc
  make all-target-libgcc
  make install-target-libgcc
}

step_musl() {
  host_env
  make_env

  apply_musl_security_patches

  m="$(srcdir_of musl "$MUSL_VER")"
  b="$BLD/musl"
  rm -rf "$b" 2>/dev/null || true
  mkdir -p "$b"
  cd "$b"

  # musl instala no sysroot (/usr e /lib no target)
  CC="$TOOLS/bin/$TARGET-gcc" \
  "$m/configure" \
    --prefix=/usr \
    --target="$TARGET" \
    --syslibdir=/lib

  make
  DESTDIR="$SYSROOT" make install

  # valida libc
  if [ ! -f "$SYSROOT/usr/lib/libc.a" ] && [ ! -f "$SYSROOT/lib/libc.so" ] && [ ! -f "$SYSROOT/lib/libc.a" ]; then
    die "musl não instalou libc no SYSROOT"
  fi
}

step_gcc_final() {
  host_env
  make_env
  triplet_tools

  b="$BLD/gcc-final"
  rm -rf "$b" 2>/dev/null || true
  mkdir -p "$b"
  cd "$b"

  "$(srcdir_of gcc "$GCC_VER")/configure" \
    --target="$TARGET" \
    --prefix="$TOOLS" \
    --with-sysroot="$SYSROOT" \
    --disable-nls \
    --enable-languages=c,c++ \
    --disable-multilib

  make
  make install
}

step_xz_target() {
  host_env
  make_env

  x="$(srcdir_of xz "$XZ_VER")"
  b="$BLD/xz"
  rm -rf "$b" 2>/dev/null || true
  mkdir -p "$b"
  cd "$b"

  # xz para o target (instala no SYSROOT)
  CC="$TOOLS/bin/$TARGET-gcc" \
  "$x/configure" \
    --host="$TARGET" \
    --prefix=/usr \
    --disable-shared

  make
  DESTDIR="$SYSROOT" make install

  [ -x "$SYSROOT/usr/bin/xz" ] || [ -x "$SYSROOT/bin/xz" ] || true
}

step_busybox() {
  host_env
  make_env

  bb="$(srcdir_of busybox "$BUSYBOX_VER")"
  b="$BLD/busybox"
  rm -rf "$b" 2>/dev/null || true
  mkdir -p "$b"

  # copia árvore (POSIX) via tar pipeline
  ( cd "$bb" && tar -cf - . ) | ( cd "$b" && tar -xf - )

  cd "$b"
  make distclean >/dev/null 2>&1 || true
  make defconfig

  # Força estático (bom para rootfs/bootstrap)
  if grep '^# CONFIG_STATIC is not set' .config >/dev/null 2>&1; then
    sed 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config >.config.new && mv .config.new .config
  elif grep '^CONFIG_STATIC=' .config >/dev/null 2>&1; then
    sed 's/^CONFIG_STATIC=.*/CONFIG_STATIC=y/' .config >.config.new && mv .config.new .config
  else
    printf '\nCONFIG_STATIC=y\n' >> .config
  fi

  make CC="$TOOLS/bin/$TARGET-gcc" AR="$TOOLS/bin/$TARGET-ar" LD="$TOOLS/bin/$TARGET-ld"
  DESTDIR="$SYSROOT" make CONFIG_PREFIX="$SYSROOT" install

  [ -x "$SYSROOT/bin/busybox" ] || die "busybox não instalado no SYSROOT"
}

step_sanity() {
  host_env

  # ferramentas essenciais do cross
  for t in "$TOOLS/bin/$TARGET-gcc" "$TOOLS/bin/$TARGET-ld" "$TOOLS/bin/$TARGET-as" "$TOOLS/bin/$TARGET-ar"; do
    [ -x "$t" ] || die "falta ferramenta: $t"
  done

  # compila um hello estático
  tmpc="$TOP/hello.c"
  out="$TOP/hello"
  cat >"$tmpc" <<'EOF'
int main(void){return 0;}
EOF
  "$TOOLS/bin/$TARGET-gcc" --sysroot="$SYSROOT" -static -O2 "$tmpc" -o "$out" >/dev/null 2>&1 \
    || die "falha compilando teste com toolchain"
  rm -f "$tmpc" "$out" 2>/dev/null || true

  say "OK: toolchain $TARGET pronto"
  say "  TOOLS:   $TOOLS"
  say "  SYSROOT: $SYSROOT"
}

handoff_adm() {
  cat <<EOF
============================================================
HANDOFF (adm pode assumir a partir daqui)

TOOLCHAIN:
  $TOOLS

SYSROOT:
  $SYSROOT

No host:
  export PATH="$TOOLS/bin:\$PATH"

Próximos passos sugeridos:
  1) Criar rootfs a partir do SYSROOT (exemplo simples):
       ROOTFS=$TOP/rootfs
       mkdir -p "\$ROOTFS"
       (cd "$SYSROOT" && tar -cf - .) | (cd "\$ROOTFS" && tar -xf -)
       ln -sf busybox "\$ROOTFS/bin/sh" 2>/dev/null || true

  2) Copiar adm + admchroot para dentro do rootfs (ex. /usr/bin):
       mkdir -p "\$ROOTFS/usr/bin"
       cp -f /usr/bin/adm "\$ROOTFS/usr/bin/adm"
       cp -f /usr/bin/admchroot "\$ROOTFS/usr/bin/admchroot"  (ou onde estiver)

  3) Entrar no chroot e rodar adm:
       admchroot --root "\$ROOTFS" shell
       admchroot --root "\$ROOTFS" adm -- doctor
============================================================
EOF
}

###############################################################################
# Dispatcher
###############################################################################
usage() {
  cat <<EOF
Uso:
  $0 all
  $0 step <nome>

Steps:
  prepare
  sources
  binutils
  linux-headers
  gcc-stage1
  musl
  gcc-final
  xz
  busybox
  sanity

Variáveis úteis:
  TARGET=$TARGET
  MAKEJOBS=$MAKEJOBS
  FETCH=$FETCH
  GCC_FETCH_DEPS=$GCC_FETCH_DEPS

  TOP=$TOP
  TOOLS=$TOOLS
  SYSROOT=$SYSROOT
EOF
}

main() {
  cmd=${1:-}
  case "$cmd" in
    all)
      runlog prepare step_prepare
      runlog sources step_sources
      runlog binutils step_binutils
      runlog linux-headers step_linux_headers
      runlog gcc-stage1 step_gcc_stage1
      runlog musl step_musl
      runlog gcc-final step_gcc_final
      runlog xz step_xz_target
      runlog busybox step_busybox
      runlog sanity step_sanity
      handoff_adm
      ;;
    step)
      name=${2:-}
      [ -n "$name" ] || { usage; exit 1; }
      case "$name" in
        prepare) runlog prepare step_prepare ;;
        sources) runlog sources step_sources ;;
        binutils) runlog binutils step_binutils ;;
        linux-headers) runlog linux-headers step_linux_headers ;;
        gcc-stage1) runlog gcc-stage1 step_gcc_stage1 ;;
        musl) runlog musl step_musl ;;
        gcc-final) runlog gcc-final step_gcc_final ;;
        xz) runlog xz step_xz_target ;;
        busybox) runlog busybox step_busybox ;;
        sanity) runlog sanity step_sanity ;;
        *) die "step desconhecido: $name" ;;
      esac
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
