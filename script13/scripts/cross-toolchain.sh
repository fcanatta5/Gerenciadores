#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# cross-toolchain.sh
# Build a temporary cross toolchain and prepare a musl-based rootfs + chroot,
# then bootstrap minimal environment for "adm" to take over.
#
# Everything stateful stays under /mnt/adm/cross-toolchain/cross-toolchain.sh
# Tudo do programa em /mnt/adm/cross-toolchain
# Rootfs at /mnt/adm/rootfs
# Tools at /mnt/adm/rootfs/tools
#
# Package scripts live at /mnt/adm/packages/<pkg>/build
###############################################################################

# -------------------- Config --------------------
BASE="/mnt/adm"
ROOTFS="$BASE/rootfs"
TOOLS="$ROOTFS/tools"
PKGDIR="$BASE/packages"
WORKBASE="$BASE/cross-toolchain"

CACHEDIR="$WORKBASE/cache"
BUILDDIR="$WORKBASE/build"
LOGDIR="$WORKBASE/log"
STATEDIR="$WORKBASE/state"
SRCDIR="$WORKBASE/src"
PATCHDIR="$WORKBASE/patches"

TARGET="${TARGET:-x86_64-linux-musl}"
LIBC="${LIBC:-musl}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

# Queue (default). You can override by exporting PLAN="pkg1 pkg2 ..."
DEFAULT_PLAN=(
  # --- toolchain temporária ---
  "binutils-pass1"
  "gcc-pass1"
  "linux-headers"
  "musl"
  "gcc-final"
  "binutils-final"

  # --- base mínima do chroot (shell + utilitários básicos) ---
  "busybox"
  "bash"

  # --- ferramentas de build / patch / texto ---
  "make"
  "patch"
  "sed"
  "gawk"
  "grep"
  "findutils"

  # --- empacotamento/compressão (útil para adm e sources) ---
  "tar"
  "gzip"
  "xz"
  "zstd"

  # --- libs necessárias para internet real e git ---
  "zlib"
  "openssl"
  "expat"

  # --- sync / download / scm ---
  "rsync"
  "curl"
  "git"
)

PLAN_STR="${PLAN:-}"
DRYRUN=0
RESUME=1
CLEAN=0
VERBOSE=0

# -------------------- UI --------------------
if [[ -t 1 ]]; then
  C0=$'\033[0m'; B=$'\033[1m'
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'
  C=$'\033[36m'; W=$'\033[37m'
else
  C0=""; B=""; R=""; G=""; Y=""; C=""; W=""
fi

say()  { printf "%s\n" "$*"; }
info() { printf "%s%s[i]%s %s\n" "$C" "$B" "$C0" "$*"; }
ok()   { printf "%s%s[OK]%s %s\n" "$G" "$B" "$C0" "$*"; }
warn() { printf "%s%s[WARN]%s %s\n" "$Y" "$B" "$C0" "$*"; }
err()  { printf "%s%s[ERR]%s %s\n" "$R" "$B" "$C0" "$*" >&2; }
die()  { err "$*"; exit 1; }

run() {
  if ((DRYRUN)); then
    printf "%s%s[dry-run]%s " "$Y" "$B" "$C0"
    printf "%q " "$@"
    printf "\n"
    return 0
  fi
  ((VERBOSE)) && { printf "%s%s[run]%s " "$W" "$B" "$C0"; printf "%q " "$@"; printf "\n"; }
  "$@"
}

need() { command -v "$1" >/dev/null 2>&1 || die "Ferramenta ausente: $1"; }

ts() { date +"%Y-%m-%d %H:%M:%S"; }

mkdirs() {
  run mkdir -p "$ROOTFS" "$TOOLS" "$PKGDIR" "$WORKBASE" \
    "$CACHEDIR" "$BUILDDIR" "$LOGDIR" "$STATEDIR" "$SRCDIR" "$PATCHDIR"
}

# -------------------- Lock --------------------
lock() {
  mkdirs
  need flock
  exec 9>"$WORKBASE/.lock"
  flock -x 9
}

# -------------------- Environment exports --------------------
export_env() {
  export ROOTFS TOOLS TARGET LIBC JOBS
  export SYSROOT="$ROOTFS"
  export PATH="$TOOLS/bin:$TOOLS/sbin:/usr/bin:/bin"
  export MAKEFLAGS="-j$JOBS"

  # Common build variables (package scripts can override)
  export CC_FOR_TARGET="${TARGET}-gcc"
  export CXX_FOR_TARGET="${TARGET}-g++"
  export AR_FOR_TARGET="${TARGET}-ar"
  export RANLIB_FOR_TARGET="${TARGET}-ranlib"
  export STRIP_FOR_TARGET="${TARGET}-strip"

  export CONFIG_SITE="${WORKBASE}/config.site"
  if (( !DRYRUN )); then
    cat >"$CONFIG_SITE" <<EOF
# Global configure defaults for cross bootstrap
EOF
  fi
}

print_env() {
  say "${B}Bootstrap env${C0}"
  say "  ROOTFS=$ROOTFS"
  say "  TOOLS=$TOOLS"
  say "  WORKBASE=$WORKBASE"
  say "  PKGDIR=$PKGDIR"
  say "  TARGET=$TARGET"
  say "  LIBC=$LIBC"
  say "  JOBS=$JOBS"
  say "  PATH=$PATH"
}

# -------------------- Download + checksum (cache) --------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

fetch_http() {
  local url="$1" out="$2"
  if have_cmd curl; then
    run curl -L --fail --retry 3 --connect-timeout 20 -o "$out" "$url"
  elif have_cmd wget; then
    run wget -O "$out" "$url"
  else
    die "Nem curl nem wget disponível para baixar: $url"
  fi
}

sha_ok() {
  local hex="$1" file="$2"
  need sha256sum
  printf "%s  %s\n" "$hex" "$file" | sha256sum -c - >/dev/null 2>&1
}

md5_ok() {
  local hex="$1" file="$2"
  need md5sum
  printf "%s  %s\n" "$hex" "$file" | md5sum -c - >/dev/null 2>&1
}

# Contract: package build script may define:
#   sources=( "URL::filename" "URL" ... )
#   sha256sums=( "HEX filename" "HEX" ... ) OR aligned
#   md5sums=( ... ) similarly optional
parse_source() {
  local s="$1"
  if [[ "$s" == *"::"* ]]; then
    printf "%s\n" "${s%%::*}" "${s##*::}"
  else
    printf "%s\n" "$s" ""
  fi
}

src_cache_key() {
  local url="$1"
  local base="${url##*/}"
  local h
  h="$(printf "%s" "$url" | sha256sum | awk '{print $1}' | cut -c1-12)"
  printf "%s__%s" "$h" "$base"
}

checksum_for_file() {
  # args: fname idx -> prints: "sha256 HEX" or "md5 HEX" or empty
  local fname="$1" idx="$2"
  local entry hex file

  # sha256 "HEX file"
  for entry in "${sha256sums[@]:-}"; do
    if [[ "$entry" == *" "* ]]; then
      hex="${entry%% *}"; file="${entry##* }"
      [[ "$file" == "$fname" ]] && { printf "sha256 %s\n" "$hex"; return 0; }
    fi
  done
  for entry in "${md5sums[@]:-}"; do
    if [[ "$entry" == *" "* ]]; then
      hex="${entry%% *}"; file="${entry##* }"
      [[ "$file" == "$fname" ]] && { printf "md5 %s\n" "$hex"; return 0; }
    fi
  done

  # aligned
  if (( idx >= 0 )); then
    if (( ${#sha256sums[@]:-0} > idx )); then
      entry="${sha256sums[$idx]}"
      [[ "$entry" != *" "* && -n "$entry" ]] && { printf "sha256 %s\n" "$entry"; return 0; }
    fi
    if (( ${#md5sums[@]:-0} > idx )); then
      entry="${md5sums[$idx]}"
      [[ "$entry" != *" "* && -n "$entry" ]] && { printf "md5 %s\n" "$entry"; return 0; }
    fi
  fi
  return 1
}

fetch_sources() {
  # Uses sources[] and checksums from the package build script.
  local pkg="$1"
  ((${#sources[@]:-0})) || return 0

  local pkgsrc="$SRCDIR/$pkg"
  run mkdir -p "$pkgsrc"

  local i=0
  for s in "${sources[@]}"; do
    local url out
    read -r url out < <(parse_source "$s")
    local fname="${out:-${url##*/}}"
    [[ -n "$fname" ]] || fname="source_$i"

    local cachekey cachepath dst
    cachekey="$(src_cache_key "$url")"
    cachepath="$CACHEDIR/$cachekey"
    dst="$pkgsrc/$fname"

    if [[ -f "$cachepath" ]]; then
      if checksum_for_file "$fname" "$i" >/dev/null 2>&1; then
        local algo hex
        read -r algo hex < <(checksum_for_file "$fname" "$i")
        if [[ "$algo" == "sha256" ]] && sha_ok "$hex" "$cachepath"; then
          run cp -f "$cachepath" "$dst"
          ((i++)); continue
        fi
        if [[ "$algo" == "md5" ]] && md5_ok "$hex" "$cachepath"; then
          run cp -f "$cachepath" "$dst"
          ((i++)); continue
        fi
        run rm -f "$cachepath"
      else
        run cp -f "$cachepath" "$dst"
        ((i++)); continue
      fi
    fi

    info "Baixando: $fname"
    fetch_http "$url" "$dst"

    if checksum_for_file "$fname" "$i" >/dev/null 2>&1; then
      local algo hex
      read -r algo hex < <(checksum_for_file "$fname" "$i")
      if [[ "$algo" == "sha256" ]]; then
        sha_ok "$hex" "$dst" || die "sha256 falhou para $pkg/$fname"
      else
        md5_ok "$hex" "$dst" || die "md5 falhou para $pkg/$fname"
      fi
    else
      warn "Sem checksum declarado para $pkg/$fname"
    fi

    run cp -f "$dst" "$cachepath"
    ((i++))
  done
}

# -------------------- Extract + patches --------------------
tar_supports_zstd() { tar --help 2>/dev/null | grep -q -- '--zstd'; }

extract_zst() {
  local archive="$1" dest="$2"
  if tar_supports_zstd; then
    run tar --zstd -xf "$archive" -C "$dest"
  elif have_cmd unzstd; then
    run bash -c "unzstd -c \"$archive\" | tar -xf - -C \"$dest\""
  elif have_cmd zstd; then
    run bash -c "zstd -dc \"$archive\" | tar -xf - -C \"$dest\""
  else
    die "Sem suporte para .zst"
  fi
}

extract_sources() {
  local pkg="$1"
  local pkgsrc="$SRCDIR/$pkg"
  local work="$BUILDDIR/$pkg/work"
  run rm -rf "$work"
  run mkdir -p "$work"

  shopt -s nullglob
  local f
  for f in "$pkgsrc"/*; do
    case "$f" in
      *.tar.gz|*.tgz) run tar -xzf "$f" -C "$work" ;;
      *.tar.xz|*.txz) run tar -xJf "$f" -C "$work" ;;
      *.tar.bz2|*.tbz2) run tar -xjf "$f" -C "$work" ;;
      *.tar.zst|*.tzst) extract_zst "$f" "$work" ;;
      *.zip) need unzip; run unzip -q "$f" -d "$work" ;;
      *) run cp -a "$f" "$work/" ;;
    esac
  done
  shopt -u nullglob

  # choose SRC_DIR: single directory -> that dir, else work
  local dcount
  dcount="$(find "$work" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  if [[ "$dcount" == "1" ]]; then
    find "$work" -mindepth 1 -maxdepth 1 -type d -print -quit
  else
    printf "%s\n" "$work"
  fi
}

apply_patches() {
  local pkg="$1" srcdir="$2"
  local pdir="$PKGDIR/$pkg/patch"
  [[ -d "$pdir" ]] || return 0
  need patch

  shopt -s nullglob
  local p
  for p in "$pdir"/*.patch "$pdir"/*.diff; do
    info "Patch: ${p##*/}"
    if ! run patch -d "$srcdir" -p1 <"$p" >>"$LOG_CURRENT" 2>&1; then
      run patch -d "$srcdir" -p0 <"$p" >>"$LOG_CURRENT" 2>&1 || die "Falha patch: ${p##*/}"
    fi
  done
  shopt -u nullglob
}

# -------------------- Package build contract --------------------
# Each package: /mnt/adm/packages/<pkg>/build
# Must define:
#   pkgname, pkgver (optional pkgrel)
#   sources=() (optional)
#   sha256sums=() or md5sums=() (optional)
#   build() and install()
# Optional:
#   pre_build(), post_build(), pre_install(), post_install()
#
# Also package can export:
#   BOOTSTRAP_STAGE="pass1|final|chroot"
#   and use env vars:
#   ROOTFS, TOOLS, SYSROOT, TARGET, PATH, JOBS
#
load_pkg_build() {
  local pkg="$1"
  local script="$PKGDIR/$pkg/build"
  [[ -f "$script" ]] || die "Build script não encontrado: $script"

  # Reset
  unset pkgname pkgver pkgrel
  unset -v sources sha256sums md5sums
  sources=(); sha256sums=(); md5sums=()
  unset -f pre_build build post_build pre_install install post_install 2>/dev/null || true

  # shellcheck disable=SC1090
  source "$script"

  [[ -n "${pkgname:-}" ]] || die "$pkg: pkgname não definido"
  [[ -n "${pkgver:-}" ]] || die "$pkg: pkgver não definido"
  [[ "${pkgname}" == "$pkg" ]] || die "$pkg: pkgname deve ser '$pkg' (atual: '$pkgname')"
  [[ -n "${pkgrel:-}" ]] || pkgrel=1

  declare -p sources >/dev/null 2>&1 || sources=()
}

# -------------------- Steps + resume --------------------
step_done() { [[ -f "$STATEDIR/$1.$2" ]]; } # pkg step
mark_done() { run touch "$STATEDIR/$1.$2"; }
clear_pkg_state() { run rm -f "$STATEDIR/$1."* 2>/dev/null || true; }

pkg_log_path() { printf "%s/%s-%s-%s.log\n" "$LOGDIR" "$1" "${pkgver:-?}" "${pkgrel:-?}"; }

print_queue() {
  local -a q=("$@")
  local total="${#q[@]}"
  say "${B}Fila de bootstrap (total=$total)${C0}"
  printf "%-4s %-22s %-10s %-10s\n" "#" "PACOTE" "ETAPA" "STATUS"
  printf "%-4s %-22s %-10s %-10s\n" "---" "------" "-----" "------"
  local i=0 p
  for p in "${q[@]}"; do
    ((i++))
    printf "%-4s %-22s %-10s %-10s\n" "$i/$total" "$p" "pending" "."
  done
  say ""
}

# -------------------- Build runner --------------------
build_pkg() {
  local pkg="$1"
  load_pkg_build "$pkg"
  LOG_CURRENT="$(pkg_log_path "$pkg")"
  run mkdir -p "$LOGDIR"
  ((DRYRUN)) || : >"$LOG_CURRENT"

  local work="$BUILDDIR/$pkg"
  local dest="$work/destdir"
  run mkdir -p "$work" "$dest"

  # Clean package workdir if asked
  if ((CLEAN)); then
    info "$pkg: limpando work..."
    run rm -rf "$work"
    run mkdir -p "$work" "$dest"
    clear_pkg_state "$pkg"
  fi

  say "${B}============================================================${C0}"
  say "${B}Pacote:${C0} ${G}${pkg}${C0}   ${B}Versão:${C0} ${Y}${pkgver}-${pkgrel}${C0}"
  say "${B}Work:${C0}   $work"
  say "${B}Log:${C0}    $LOG_CURRENT"
  say "${B}============================================================${C0}"

  # Step: fetch
  if ((RESUME)) && step_done "$pkg" fetch; then
    info "$pkg: resume fetch"
  else
    info "$pkg: fetch"
    fetch_sources "$pkg" >>"$LOG_CURRENT" 2>&1
    mark_done "$pkg" fetch
  fi

  # Step: extract
  local srcdir
  if ((RESUME)) && step_done "$pkg" extract; then
    info "$pkg: resume extract"
    srcdir="$(cat "$work/.srcdir" 2>/dev/null || true)"
    [[ -n "$srcdir" && -d "$srcdir" ]] || die "$pkg: srcdir inválido para resume"
  else
    info "$pkg: extract"
    srcdir="$(extract_sources "$pkg")"
    ((DRYRUN)) || printf "%s\n" "$srcdir" >"$work/.srcdir"
    mark_done "$pkg" extract
  fi

  # Step: patch
  if ((RESUME)) && step_done "$pkg" patch; then
    info "$pkg: resume patch"
  else
    apply_patches "$pkg" "$srcdir" >>"$LOG_CURRENT" 2>&1
    mark_done "$pkg" patch
  fi

  # Step: build
  if ((RESUME)) && step_done "$pkg" build; then
    info "$pkg: resume build"
  else
    if declare -F pre_build >/dev/null 2>&1; then info "$pkg: pre_build"; pre_build >>"$LOG_CURRENT" 2>&1; fi
    info "$pkg: build"
    ( cd "$srcdir" && build ) >>"$LOG_CURRENT" 2>&1
    if declare -F post_build >/dev/null 2>&1; then info "$pkg: post_build"; post_build >>"$LOG_CURRENT" 2>&1; fi
    mark_done "$pkg" build
  fi

  # Step: install
  if ((RESUME)) && step_done "$pkg" install; then
    info "$pkg: resume install"
  else
    if declare -F pre_install >/dev/null 2>&1; then info "$pkg: pre_install"; pre_install >>"$LOG_CURRENT" 2>&1; fi
    info "$pkg: install"
    ( cd "$srcdir" && DESTDIR="$dest" install ) >>"$LOG_CURRENT" 2>&1
    if declare -F post_install >/dev/null 2>&1; then info "$pkg: post_install"; post_install >>"$LOG_CURRENT" 2>&1; fi
    mark_done "$pkg" install
  fi

  # Commit: copy DESTDIR into SYSROOT or TOOLS based on package stage.
  # Convention:
  # - pass1 packages install into $TOOLS
  # - linux-headers/musl/gcc-final/binutils-final/base packages install into $ROOTFS (/)
  #
  # Package scripts can set INSTALL_ROOT="tools" or "sysroot"
  local install_root="${INSTALL_ROOT:-}"
  if [[ -z "$install_root" ]]; then
    case "$pkg" in
      *pass1) install_root="tools" ;;
      *)      install_root="sysroot" ;;
    esac
  fi

  info "$pkg: commit -> $install_root"
  if [[ "$install_root" == "tools" ]]; then
    # Ensure tools dirs exist
    run mkdir -p "$TOOLS"
    if command -v rsync >/dev/null 2>&1; then
      run rsync -aH --numeric-ids "$dest"/ "$TOOLS"/ >>"$LOG_CURRENT" 2>&1
    else
      run cp -a "$dest"/. "$TOOLS"/
    fi
  else
    run mkdir -p "$ROOTFS"
    if command -v rsync >/dev/null 2>&1; then
      run rsync -aH --numeric-ids "$dest"/ "$ROOTFS"/ >>"$LOG_CURRENT" 2>&1
    else
      run cp -a "$dest"/. "$ROOTFS"/
    fi
  fi

  ok "✔ $pkg concluído"
}

# -------------------- Rootfs preparation --------------------
prepare_rootfs_layout() {
  mkdirs
  info "Preparando layout do rootfs em $ROOTFS"
  run mkdir -p "$ROOTFS"/{bin,dev,etc,proc,run,sys,tmp,var}
  run mkdir -p "$ROOTFS"/usr/{bin,lib,include,sbin,share}
  run mkdir -p "$ROOTFS"/lib
  run chmod 1777 "$ROOTFS/tmp" || true
  run mkdir -p "$TOOLS"/{bin,lib,sbin,include}
}

# -------------------- Toolchain sanity checks --------------------
check_toolchain() {
  info "Verificando toolchain..."
  local cc="$TOOLS/bin/${TARGET}-gcc"
  local ld="$TOOLS/bin/${TARGET}-ld"

  [[ -x "$ld" ]] || die "Faltando: $ld (binutils-pass1 não instalou?)"
  [[ -x "$cc" ]] || die "Faltando: $cc (gcc-pass1 não instalou?)"

  # basic compile test against sysroot after musl is installed
  if [[ -e "$ROOTFS/lib/ld-musl-x86_64.so.1" ]]; then
    info "Teste de compilação/link (nativo no sysroot)..."
    local tdir="$WORKBASE/tmp-test"
    run rm -rf "$tdir"
    run mkdir -p "$tdir"
    cat >"$tdir/t.c" <<'EOF'
#include <stdio.h>
int main(){ puts("toolchain-ok"); return 0; }
EOF
    run "$cc" --sysroot="$ROOTFS" "$tdir/t.c" -o "$tdir/a.out" >>"$LOGDIR/toolchain-test.log" 2>&1 \
      || die "Falha no compile/link de teste (veja $LOGDIR/toolchain-test.log)"
    ok "Teste OK: compilou e linkou."
  else
    warn "musl ainda não instalada no sysroot; teste de link completo será feito após musl."
  fi

  ok "Toolchain check concluído."
}

# -------------------- chroot (safe mount/umount) --------------------
is_mounted() { mountpoint -q "$1"; }

mount_chroot() {
  info "Montando chroot (proc/sys/dev/run)..."
  run mkdir -p "$ROOTFS"/{proc,sys,dev,run}
  is_mounted "$ROOTFS/proc" || run mount -t proc proc "$ROOTFS/proc"
  is_mounted "$ROOTFS/sys"  || run mount -t sysfs sysfs "$ROOTFS/sys"
  is_mounted "$ROOTFS/dev"  || run mount --bind /dev "$ROOTFS/dev"
  is_mounted "$ROOTFS/run"  || run mount --bind /run "$ROOTFS/run"

  # resolv.conf (dns)
  run mkdir -p "$ROOTFS/etc"
  if [[ -f /etc/resolv.conf ]]; then
    run cp -f /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
  fi
  ok "Chroot montado."
}

umount_chroot() {
  info "Desmontando chroot..."
  is_mounted "$ROOTFS/run"  && run umount -l "$ROOTFS/run" || true
  is_mounted "$ROOTFS/dev"  && run umount -l "$ROOTFS/dev" || true
  is_mounted "$ROOTFS/sys"  && run umount -l "$ROOTFS/sys" || true
  is_mounted "$ROOTFS/proc" && run umount -l "$ROOTFS/proc" || true
  ok "Chroot desmontado."
}

enter_chroot() {
  mount_chroot
  info "Entrando no chroot em $ROOTFS"
  run chroot "$ROOTFS" /bin/sh -l
}

# -------------------- Prepare minimal for adm inside chroot --------------------
prepare_adm_in_chroot() {
  info "Preparando diretórios do adm dentro do chroot..."
  run mkdir -p "$ROOTFS/var/lib/adm"/{packages,cache/pkgs,cache/sources,cache/backups,build,log,db,stage,locks,tmp}

  # Install adm if provided at /mnt/adm/adm.sh
  if [[ -f "$BASE/adm.sh" ]]; then
    info "Instalando adm.sh no chroot (/usr/sbin/adm)"
    run mkdir -p "$ROOTFS/usr/sbin"
    run cp -f "$BASE/adm.sh" "$ROOTFS/usr/sbin/adm"
    run chmod +x "$ROOTFS/usr/sbin/adm"
  else
    warn "Não encontrei $BASE/adm.sh. Copie seu adm.sh para /mnt/adm/adm.sh para instalar automaticamente."
  fi

  ok "adm preparado no chroot."
}

# -------------------- Main actions --------------------
do_plan() {
  local -a plan=()
  if [[ -n "$PLAN_STR" ]]; then
    # shellcheck disable=SC2206
    plan=($PLAN_STR)
  else
    plan=("${DEFAULT_PLAN[@]}")
  fi

  prepare_rootfs_layout
  export_env
  print_env
  print_queue "${plan[@]}"

  local p total="${#plan[@]}" i=0
  for p in "${plan[@]}"; do
    ((i++))
    info "[$i/$total] Construindo: $p"
    build_pkg "$p"
  done

  check_toolchain
  prepare_adm_in_chroot

  ok "Bootstrap concluído."
  say ""
  say "${B}Próximos passos${C0}"
  say "  1) Montar chroot:   $0 mount"
  say "  2) Entrar chroot:   $0 chroot"
  say "  3) Desmontar:       $0 umount"
}

clean_all() {
  info "Limpando workbase (mantendo rootfs intacto)..."
  run rm -rf "$WORKBASE"/{build,src,state,tmp-test} 2>/dev/null || true
  run mkdir -p "$BUILDDIR" "$SRCDIR" "$STATEDIR"
  ok "Clean concluído."
}

usage() {
  cat <<EOF
Uso:
  $0 run [opções]         Executa a fila completa
  $0 mount                Monta /proc /sys /dev /run no rootfs
  $0 umount               Desmonta com segurança
  $0 chroot               Entra no chroot
  $0 check                Verifica toolchain
  $0 clean                Limpa build/src/state (não apaga rootfs)
  $0 env                  Mostra ambiente atual

Opções do run:
  --dry-run               Simula comandos
  --no-resume             Desativa retomada
  --clean                 Limpa work do pacote antes de construir
  --jobs N                Define paralelismo (default: $JOBS)
  -v                      Verbose

Personalização:
  export TARGET=x86_64-linux-musl
  export PLAN="binutils-pass1 gcc-pass1 linux-headers musl gcc-final binutils-final ..."
EOF
}

main() {
  lock

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    run)
      while (($#)); do
        case "$1" in
          --dry-run) DRYRUN=1; shift ;;
          --no-resume) RESUME=0; shift ;;
          --clean) CLEAN=1; shift ;;
          --jobs) JOBS="${2:-$JOBS}"; shift 2 ;;
          -v) VERBOSE=1; shift ;;
          *) die "Opção desconhecida: $1" ;;
        esac
      done
      do_plan
      ;;
    mount) prepare_rootfs_layout; mount_chroot ;;
    umount) umount_chroot ;;
    chroot) prepare_rootfs_layout; enter_chroot ;;
    check) export_env; check_toolchain ;;
    clean) clean_all ;;
    env) export_env; print_env ;;
    ""|-h|--help|help) usage ;;
    *) die "Comando desconhecido: $cmd (use: $0 help)" ;;
  esac
}

main "$@"
