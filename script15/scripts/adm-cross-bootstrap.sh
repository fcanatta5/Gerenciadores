#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Configuração
# =========================
ROOT="${ROOT:-/mnt/adm/rootfs}"
TOOLS="${TOOLS:-$ROOT/cross-tools}"
SYSROOT="${SYSROOT:-$ROOT}"          # sysroot é o próprio rootfs
CACHE="${CACHE:-/var/cache/adm-bootstrap}"
WORK="${WORK:-/var/tmp/adm-bootstrap}"
LOGDIR="${LOGDIR:-/var/log/adm-bootstrap}"
STATEDIR="$ROOT/.adm-bootstrap"
STAMPS="$STATEDIR/stamps"
MANIFEST="${MANIFEST:-./sources.txt}"

ARCH="${ARCH:-x86_64}"
TRIPLET="${TRIPLET:-x86_64-linux-musl}"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 1)}"
INSECURE=0

# Versões (devem bater com seu manifest)
VMLINUX_VER="${VMLINUX_VER:-6.18.1}"
BINUTILS_VER="${BINUTILS_VER:-2.45.1}"
GCC_VER="${GCC_VER:-15.2.0}"
MUSL_VER="${MUSL_VER:-1.2.5}"
BUSYBOX_VER="${BUSYBOX_VER:-1.36.1}"

# =========================
# UI / Logs
# =========================
if [[ -t 2 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; M=$'\033[35m'; C=$'\033[36m'; D=$'\033[2m'; Z=$'\033[0m'
else
  R="";G="";Y="";B="";M="";C="";D="";Z=""
fi

hr(){ printf '%s\n' "${D}────────────────────────────────────────────────────────${Z}"; }
step(){ hr; printf '%b\n' "${B}▶${Z} ${M}$*${Z}"; hr; }
ok(){  printf '%b\n' "${G}[OK]${Z} $*"; }
warn(){printf '%b\n' "${Y}[WARN]${Z} $*"; }
die(){ printf '%b\n' "${R}[FAIL]${Z} $*"; exit 1; }

need(){ command -v "$1" >/dev/null 2>&1 || die "Comando ausente: $1"; }

onerr(){
  local ec=$? ln=${BASH_LINENO[0]:-?} cmd=${BASH_COMMAND:-?}
  printf '%b\n' "${R}ERRO${Z} exit=$ec linha=$ln cmd=$cmd"
  printf '%b\n' "Log: ${LOG:-"(sem log)"}"
  exit "$ec"
}
trap onerr ERR

init(){
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Execute como root."
  for c in awk sed grep cut tr xargs sort head tail sha256sum tar make patch gzip bzip2 xz; do need "$c"; done
  need curl
  need gcc
  need g++
  need ld
  need ar
  need ranlib
  need make
  need perl
  need bison
  need flex

  mkdir -p "$CACHE" "$WORK" "$LOGDIR" "$ROOT" "$TOOLS" "$STAMPS"
  LOG="$LOGDIR/bootstrap-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2)
  ok "Log: $LOG"
}

stamp_has(){ [[ -f "$STAMPS/$1" ]]; }
stamp_set(){ date -Is >"$STAMPS/$1"; }

# =========================
# Manifesto de fontes
# =========================
mf_get(){
  # mf_get name field -> url/sha256
  local name="$1" field="$2"
  [[ -f "$MANIFEST" ]] || die "Manifesto não encontrado: $MANIFEST"
  awk -F'|' -v n="$name" -v f="$field" '
    $0 ~ /^[[:space:]]*#/ {next}
    NF>=3 && $1==n {
      if (f=="url") print $2;
      if (f=="sha256") print $3;
      exit
    }' "$MANIFEST"
}

fetch(){
  local name="$1"
  local url sha base out
  url="$(mf_get "$name" url)"
  sha="$(mf_get "$name" sha256)"
  [[ -n "$url" ]] || die "Sem URL para $name no manifesto."
  base="$(basename "${url%%\?*}")"
  out="$CACHE/$base"

  if [[ -f "$out" ]]; then
    if [[ -n "$sha" ]]; then
      echo "$sha  $out" | sha256sum -c - >/dev/null 2>&1 && { ok "cache ok: $base"; echo "$out"; return; }
      warn "checksum falhou no cache ($base), baixando novamente"
      rm -f "$out"
    else
      [[ "$INSECURE" == "1" ]] || die "$name: SHA256 ausente no manifesto (modo seguro exige)."
      warn "$name: sem SHA256 (INSECURE=1) usando cache existente: $base"
      echo "$out"; return
    fi
  fi

  step "Download: $name -> $base"
  curl -fL --retry 3 --retry-delay 2 -o "$out.part" "$url"
  mv -f "$out.part" "$out"

  if [[ -n "$sha" ]]; then
    echo "$sha  $out" | sha256sum -c - >/dev/null 2>&1 || { rm -f "$out"; die "$name: SHA256 inválido, arquivo removido."; }
    ok "checksum ok: $base"
  else
    [[ "$INSECURE" == "1" ]] || { rm -f "$out"; die "$name: SHA256 ausente (modo seguro)."; }
    warn "$name: sem SHA256 (INSECURE=1) sem verificação"
  fi

  echo "$out"
}

extract(){
  local tarball="$1" outdir="$2"
  rm -rf "$outdir"
  mkdir -p "$outdir"
  tar -xf "$tarball" -C "$outdir"
  # retorna o primeiro diretório top-level
  local top
  top="$(tar -tf "$tarball" | head -n1 | cut -d/ -f1)"
  [[ -d "$outdir/$top" ]] || die "Falha ao extrair: $tarball"
  echo "$outdir/$top"
}

# =========================
# Rootfs mínimo (dirs)
# =========================
mkroot_layout(){
  step "Criando layout mínimo do rootfs"
  mkdir -p "$ROOT"/{dev,proc,sys,run,tmp,etc,root,home,var}
  mkdir -p "$ROOT"/{bin,sbin,lib,usr/{bin,sbin,lib,include,share}}
  chmod 1777 "$ROOT/tmp"
  ok "layout OK"
}

# =========================
# Ambiente do toolchain
# =========================
export_toolenv(){
  export PATH="$TOOLS/bin:$PATH"
  export LC_ALL=C LANG=C
  export MAKEFLAGS="-j$JOBS"
}

# =========================
# PASSO T1: Linux headers -> SYSROOT/usr/include
# =========================
build_linux_headers(){
  stamp_has "T1-linux-headers" && { ok "T1 linux-headers: já feito"; return; }
  export_toolenv
  mkroot_layout

  local tb src
  tb="$(fetch linux)"
  src="$(extract "$tb" "$WORK/linux")"

  step "T1: linux headers_install (ARCH=$ARCH) -> $SYSROOT/usr/include"
  ( cd "$src"
    make mrproper
    make headers_install ARCH="$ARCH" INSTALL_HDR_PATH="$SYSROOT/usr"
  )

  # sanity: deve existir asm/ bits/ linux/ em include
  [[ -d "$SYSROOT/usr/include/linux" ]] || die "linux-headers: faltou $SYSROOT/usr/include/linux"
  [[ -d "$SYSROOT/usr/include/asm" || -d "$SYSROOT/usr/include/asm-generic" ]] || warn "linux-headers: asm/ não encontrado (pode ser normal dependendo do kernel/arch)"

  stamp_set "T1-linux-headers"
  ok "T1 concluído"
}

# =========================
# PASSO T2: binutils pass1 (cross) -> TOOLS
# =========================
build_binutils_pass1(){
  stamp_has "T2-binutils-pass1" && { ok "T2 binutils pass1: já feito"; return; }
  export_toolenv
  local tb src bld
  tb="$(fetch binutils)"
  src="$(extract "$tb" "$WORK/binutils")"
  bld="$WORK/binutils-build"
  rm -rf "$bld"; mkdir -p "$bld"

  step "T2: binutils pass1 (target=$TRIPLET, sysroot=$SYSROOT) -> $TOOLS"
  ( cd "$bld"
    "$src/configure" \
      --prefix="$TOOLS" \
      --target="$TRIPLET" \
      --with-sysroot="$SYSROOT" \
      --disable-nls \
      --disable-werror
    make
    make install
  )

  need "$TRIPLET-ld"
  stamp_set "T2-binutils-pass1"
  ok "T2 concluído"
}

# =========================
# PASSO T3: gcc pass1 (somente C, sem headers) -> TOOLS
# =========================
build_gcc_pass1(){
  stamp_has "T3-gcc-pass1" && { ok "T3 gcc pass1: já feito"; return; }
  export_toolenv

  local tb src bld
  tb="$(fetch gcc)"
  src="$(extract "$tb" "$WORK/gcc")"
  bld="$WORK/gcc-pass1-build"
  rm -rf "$bld"; mkdir -p "$bld"

  step "T3: gcc pass1 (C only, without-headers) -> $TOOLS"
  ( cd "$bld"
    "$src/configure" \
      --prefix="$TOOLS" \
      --target="$TRIPLET" \
      --with-sysroot="$SYSROOT" \
      --disable-nls \
      --disable-multilib \
      --disable-bootstrap \
      --disable-shared \
      --disable-threads \
      --enable-languages=c \
      --without-headers \
      --with-newlib \
      --disable-libatomic \
      --disable-libgomp \
      --disable-libquadmath \
      --disable-libssp \
      --disable-libstdcxx \
      --disable-libvtv
    make all-gcc -j"$JOBS"
    make install-gcc
  )

  need "$TRIPLET-gcc"
  stamp_set "T3-gcc-pass1"
  ok "T3 concluído"
}

# =========================
# PASSO T4: musl -> SYSROOT (lib + headers)
# =========================
build_musl_sysroot(){
  stamp_has "T4-musl-sysroot" && { ok "T4 musl sysroot: já feito"; return; }
  export_toolenv

  local tb src
  tb="$(fetch musl)"
  src="$(extract "$tb" "$WORK/musl")"

  step "T4: musl -> sysroot ($SYSROOT)"
  ( cd "$src"
    make distclean >/dev/null 2>&1 || true
    CC="$TRIPLET-gcc" ./configure --prefix=/usr --syslibdir=/lib
    make -j"$JOBS"
    DESTDIR="$SYSROOT" make install
  )

  # sanity: loader e libc presentes
  [[ -e "$SYSROOT/lib/libc.so" || -e "$SYSROOT/lib/libc.musl-*.so.1" || -e "$SYSROOT/lib/libc.musl-x86_64.so.1" ]] || warn "musl: libc no sysroot não encontrado em /lib (verifique layout)"
  [[ -d "$SYSROOT/usr/include" ]] || die "musl: headers não instalados em $SYSROOT/usr/include"

  stamp_set "T4-musl-sysroot"
  ok "T4 concluído"
}

# =========================
# PASSO T5: gcc pass2 (C/C++) -> TOOLS (usando libc no sysroot)
# =========================
build_gcc_pass2(){
  stamp_has "T5-gcc-pass2" && { ok "T5 gcc pass2: já feito"; return; }
  export_toolenv

  local tb src bld
  tb="$(fetch gcc)"
  src="$(extract "$tb" "$WORK/gcc2")"
  bld="$WORK/gcc-pass2-build"
  rm -rf "$bld"; mkdir -p "$bld"

  step "T5: gcc pass2 (C/C++) -> $TOOLS"
  ( cd "$bld"
    "$src/configure" \
      --prefix="$TOOLS" \
      --target="$TRIPLET" \
      --with-sysroot="$SYSROOT" \
      --disable-nls \
      --disable-multilib \
      --disable-bootstrap \
      --enable-languages=c,c++ \
      --enable-shared \
      --enable-threads=posix \
      --with-system-zlib
    make -j"$JOBS"
    make install
  )

  # sanity: compilar e linkar um hello (target) usando sysroot
  step "Sanity: $TRIPLET-gcc link (sysroot)"
  cat >"$WORK/hello.c" <<'EOF'
int main(){return 0;}
EOF
  "$TRIPLET-gcc" --sysroot="$SYSROOT" -o "$WORK/hello" "$WORK/hello.c"
  file "$WORK/hello" | grep -qi "x86-64" || warn "Sanity: 'file' não identificou x86-64 (verifique ARCH/TRIPLET)"

  stamp_set "T5-gcc-pass2"
  ok "T5 concluído"
}

# =========================
# PASSO R2: BusyBox estático -> ROOT
# =========================
build_busybox(){
  stamp_has "R2-busybox" && { ok "R2 busybox: já feito"; return; }
  export_toolenv
  mkroot_layout

  local tb src
  tb="$(fetch busybox)"
  src="$(extract "$tb" "$WORK/busybox")"

  step "R2: busybox (static) -> $ROOT"
  ( cd "$src"
    make distclean >/dev/null 2>&1 || true
    make defconfig

    # Tornar BusyBox estático para simplificar o chroot inicial
    # (se você quiser dinâmico, remova isto e garanta loader/musl no rootfs)
    scripts/config -e CONFIG_STATIC || true

    # compilar com o cross gcc
    make -j"$JOBS" CROSS_COMPILE="$TRIPLET-" CC="$TRIPLET-gcc"

    # instalar no rootfs
    make CONFIG_PREFIX="$ROOT" install
  )

  # garantir /bin/sh
  [[ -x "$ROOT/bin/busybox" ]] || die "busybox não instalado em $ROOT/bin/busybox"
  ln -sf busybox "$ROOT/bin/sh"

  stamp_set "R2-busybox"
  ok "R2 concluído"
}

# =========================
# Preparar chroot seguro (mounts)
# =========================
prep_chroot_mounts(){
  step "Preparando mounts para chroot seguro"
  mkdir -p "$ROOT"/{proc,sys,dev,run}

  mountpoint -q "$ROOT/proc" || mount -t proc proc "$ROOT/proc"
  mountpoint -q "$ROOT/sys"  || mount -t sysfs sys  "$ROOT/sys"

  # /dev: bind é o mais simples e compatível
  mountpoint -q "$ROOT/dev"  || mount --bind /dev "$ROOT/dev"

  # /run tmpfs opcional
  mountpoint -q "$ROOT/run"  || mount -t tmpfs tmpfs "$ROOT/run"

  ok "mounts OK"
}

# =========================
# Checagens finais (pronto para o adm)
# =========================
final_checks(){
  step "Checagens finais"
  [[ -x "$TOOLS/bin/$TRIPLET-gcc" ]] || die "Toolchain faltando: $TOOLS/bin/$TRIPLET-gcc"
  [[ -x "$ROOT/bin/sh" ]] || die "Rootfs faltando shell: $ROOT/bin/sh"
  [[ -d "$ROOT/usr/include" ]] || die "Rootfs faltando headers: $ROOT/usr/include"
  ok "Toolchain e rootfs mínimos OK"

  cat <<EOF
Pronto.

Rootfs:   $ROOT
Tools:    $TOOLS
Triplet:  $TRIPLET

Próximo passo:
  1) prep mounts:
       sudo $0 --mounts
  2) entrar no chroot:
       sudo chroot "$ROOT" /bin/sh

Para o 'adm assumir' dentro do chroot, copie:
  - seu /usr/sbin/adm para $ROOT/usr/sbin/adm
  - seu /usr/local/adm/packages para $ROOT/usr/local/adm/packages
  - e garanta curl/git/ca-certificates se você pretende baixar fontes dentro do chroot.
EOF
}

usage(){
  cat <<EOF
Uso:
  sudo $0 [opções] [--all | --toolchain | --busybox | --mounts | --checks]

Opções:
  --root PATH        (default: /mnt/adm/rootfs)
  --triplet TRIPLET  (default: x86_64-linux-musl)
  --arch ARCH        (default: x86_64)
  -j N               paralelismo
  --insecure         permite manifesto sem SHA256 (não recomendado)

Ações:
  --all        toolchain + busybox + checks
  --toolchain  T1..T5
  --busybox    R2
  --mounts     monta /proc /sys /dev /run no rootfs
  --checks     checagens finais

EOF
}

main(){
  local action="--all"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) ROOT="$2"; TOOLS="$ROOT/cross-tools"; SYSROOT="$ROOT"; shift 2;;
      --triplet) TRIPLET="$2"; shift 2;;
      --arch) ARCH="$2"; shift 2;;
      -j) JOBS="$2"; shift 2;;
      --insecure) INSECURE=1; shift;;
      --all|--toolchain|--busybox|--mounts|--checks) action="$1"; shift;;
      -h|--help) usage; exit 0;;
      *) die "Argumento desconhecido: $1";;
    esac
  done

  init

  case "$action" in
    --toolchain)
      build_linux_headers
      build_binutils_pass1
      build_gcc_pass1
      build_musl_sysroot
      build_gcc_pass2
      ;;
    --busybox)
      build_busybox
      ;;
    --mounts)
      prep_chroot_mounts
      ;;
    --checks)
      final_checks
      ;;
    --all)
      build_linux_headers
      build_binutils_pass1
      build_gcc_pass1
      build_musl_sysroot
      build_gcc_pass2
      build_busybox
      final_checks
      ;;
  esac
}

main "$@"
