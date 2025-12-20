#!/bin/sh
# pm-bootstrap.sh (POSIX sh)
# Bootstrap de toolchain temporária (binutils + linux-headers + gcc-stage1 + musl + gcc-final)
# Opcional (recomendado para chroot): xz + busybox no sysroot
#
# IMPORTANTE:
# - pm.sh instala extraindo tarball em "/". Este script é seguro porque as receitas bootstrap
#   devem instalar em /state/toolchain/prefix e /state/toolchain/sysroot (via TC_PREFIX/TC_SYSROOT).
#
# Variáveis configuráveis:
#   TARGET=x86_64-linux-musl
#   BOOTSTRAP_DIR=state/toolchain
#   JOBS=1
#   KEEP_WORK=0
#   CLEAN=1
#   WITH_XZ=1
#   WITH_BUSYBOX=1
#
set -eu

PM_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PM="$PM_ROOT/pm.sh"
PKGS_DIR="$PM_ROOT/pkgs"

: "${TARGET:=x86_64-linux-musl}"
: "${BOOTSTRAP_DIR:=$PM_ROOT/state/toolchain}"
: "${JOBS:=1}"
: "${KEEP_WORK:=0}"
: "${CLEAN:=1}"
: "${WITH_XZ:=1}"
: "${WITH_BUSYBOX:=1}"

TC_PREFIX="$BOOTSTRAP_DIR/prefix"
TC_SYSROOT="$BOOTSTRAP_DIR/sysroot"
TC_LOGDIR="$BOOTSTRAP_DIR/logs"
TC_ENV="$BOOTSTRAP_DIR/env.sh"
LOCKDIR="$BOOTSTRAP_DIR/.lock"

ts() { date -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date; }
log() { printf "%s [BOOT] %s\n" "$(ts)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

need_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Comando requerido não encontrado: $c"
  done
}

# lock simples via mkdir
lock_acquire() {
  i=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    i=$((i+1))
    [ "$i" -le 120 ] || die "Timeout aguardando lock: $LOCKDIR"
    sleep 1
  done
}
lock_release() { rmdir "$LOCKDIR" 2>/dev/null || true; }

pkg_dir() { echo "$PKGS_DIR/$1"; }
pkg_exists() { [ -d "$(pkg_dir "$1")" ]; }

pick_pkg() {
  for p in "$@"; do
    if pkg_exists "$p"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

safe_rm_rf() {
  p=$1
  [ -n "$p" ] || die "safe_rm_rf: path vazio"
  case "$p" in
    /*) ap="$p" ;;
    *) ap="$PWD/$p" ;;
  esac
  case "$ap" in
    "$BOOTSTRAP_DIR"|"${BOOTSTRAP_DIR}/"*) ;;
    *) die "Recusando apagar fora do BOOTSTRAP_DIR: $ap" ;;
  esac
  rm -rf -- "$ap"
}

write_env() {
  # Ambiente para "assumir" toolchain temporária
  cat >"$TC_ENV" <<EOF
# Fonte este arquivo: . "$TC_ENV"
# Toolchain temporária gerada por pm-bootstrap.sh

export TARGET='${TARGET}'
export TC_PREFIX='${TC_PREFIX}'
export TC_SYSROOT='${TC_SYSROOT}'

export PATH="\${TC_PREFIX}/bin:\${PATH}"

# Preferir toolchain prefixada
if [ -x "\${TC_PREFIX}/bin/\${TARGET}-gcc" ]; then
  export CC="\${TC_PREFIX}/bin/\${TARGET}-gcc"
  export CXX="\${TC_PREFIX}/bin/\${TARGET}-g++"
  export AR="\${TC_PREFIX}/bin/\${TARGET}-ar"
  export AS="\${TC_PREFIX}/bin/\${TARGET}-as"
  export LD="\${TC_PREFIX}/bin/\${TARGET}-ld"
  export RANLIB="\${TC_PREFIX}/bin/\${TARGET}-ranlib"
  export STRIP="\${TC_PREFIX}/bin/\${TARGET}-strip"
else
  export CC="\${CC:-cc}"
  export CXX="\${CXX:-c++}"
fi

# sysroot flags (receitas podem sobrescrever)
export CPPFLAGS="\${CPPFLAGS:-} --sysroot=\${TC_SYSROOT}"
export CFLAGS="\${CFLAGS:-} --sysroot=\${TC_SYSROOT}"
export CXXFLAGS="\${CXXFLAGS:-} --sysroot=\${TC_SYSROOT}"
export LDFLAGS="\${LDFLAGS:-} --sysroot=\${TC_SYSROOT}"

# pkg-config apontando para sysroot (útil quando começar a construir userland no chroot)
export PKG_CONFIG_SYSROOT_DIR="\${TC_SYSROOT}"
export PKG_CONFIG_LIBDIR="\${TC_SYSROOT}/usr/lib/pkgconfig:\${TC_SYSROOT}/usr/share/pkgconfig"
EOF
}

usage() {
  cat <<EOF
Uso:
  ./pm-bootstrap.sh [comando]

Comandos:
  bootstrap   Constrói a toolchain temporária completa (padrão)
  clean       Remove BOOTSTRAP_DIR (state/toolchain)
  env         Mostra o caminho do env.sh gerado
  doctor      Verifica pré-requisitos e receitas esperadas

Variáveis:
  TARGET=${TARGET}
  BOOTSTRAP_DIR=${BOOTSTRAP_DIR}
  JOBS=${JOBS}
  CLEAN=${CLEAN}
  KEEP_WORK=${KEEP_WORK}
  WITH_XZ=${WITH_XZ}
  WITH_BUSYBOX=${WITH_BUSYBOX}

Exemplo:
  JOBS=4 WITH_XZ=1 WITH_BUSYBOX=1 ./pm-bootstrap.sh bootstrap
  . ${TC_ENV}
EOF
}

doctor() {
  [ -f "$PM" ] || die "pm.sh não encontrado em: $PM"
  [ -x "$PM" ] || log "AVISO: pm.sh não executável; tentarei rodar via sh."

  need_cmd sh find sort awk sed tar xz sha256sum mkdir rm mv date

  command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 \
    || die "Nenhum compilador encontrado no host (cc/gcc/clang). Necessário para stage0."
  command -v make >/dev/null 2>&1 || die "make não encontrado no host. Necessário para stage0."
  command -v patch >/dev/null 2>&1 || log "AVISO: patch não encontrado (ok se você não usa patch/ nas receitas)."

  BINUTILS=$(pick_pkg bootstrap/binutils toolchain/binutils) || die "Receita binutils não encontrada (bootstrap/binutils)."
  LINUX_HEADERS=$(pick_pkg bootstrap/linux-headers bootstrap/kernel-headers toolchain/linux-headers) || die "Receita de headers do kernel não encontrada."
  MUSL=$(pick_pkg bootstrap/musl toolchain/musl) || die "Receita musl não encontrada."
  GCC_STAGE1=$(pick_pkg bootstrap/gcc-stage1 toolchain/gcc-stage1) || die "Receita gcc-stage1 não encontrada."
  GCC_FINAL=$(pick_pkg bootstrap/gcc-final toolchain/gcc-final 2>/dev/null || echo "")

  if [ "$WITH_XZ" = "1" ]; then
    XZ_PKG=$(pick_pkg bootstrap/xz toolchain/xz 2>/dev/null || echo "")
    [ -n "$XZ_PKG" ] || log "AVISO: WITH_XZ=1 mas receita bootstrap/xz não encontrada (recomendado para chroot)."
  fi

  if [ "$WITH_BUSYBOX" = "1" ]; then
    BB_PKG=$(pick_pkg bootstrap/busybox toolchain/busybox 2>/dev/null || echo "")
    [ -n "$BB_PKG" ] || log "AVISO: WITH_BUSYBOX=1 mas receita bootstrap/busybox não encontrada (recomendado para /bin/sh no chroot)."
  fi

  log "OK receitas:"
  log "  BINUTILS=$BINUTILS"
  log "  LINUX_HEADERS=$LINUX_HEADERS"
  log "  GCC_STAGE1=$GCC_STAGE1"
  log "  MUSL=$MUSL"
  if [ -n "$GCC_FINAL" ]; then
    log "  GCC_FINAL=$GCC_FINAL"
  else
    log "  GCC_FINAL: não encontrado (sem gcc-final; você ficará com stage1)."
  fi
  log "doctor concluído."
}

run_pm_install() {
  pkg=$1
  log "Instalando via pm: $pkg"

  mkdir -p "$TC_LOGDIR"
  tmp="$TC_LOGDIR/.pm.$$.$(echo "$pkg" | tr '/ ' '__').tmp"
  out="$TC_LOGDIR/bootstrap.log"

  # BUG corrigido: não usar pipeline direto com tee (mascara falha do pm).
  # Aqui capturamos o status real do pm.
  if [ -x "$PM" ]; then
    PM_PREFIX="$TC_PREFIX" PM_JOBS="$JOBS" TARGET="$TARGET" \
    TC_PREFIX="$TC_PREFIX" TC_SYSROOT="$TC_SYSROOT" BOOTSTRAP=1 \
      "$PM" install "$pkg" >"$tmp" 2>&1 || st=$?
  else
    PM_PREFIX="$TC_PREFIX" PM_JOBS="$JOBS" TARGET="$TARGET" \
    TC_PREFIX="$TC_PREFIX" TC_SYSROOT="$TC_SYSROOT" BOOTSTRAP=1 \
      sh "$PM" install "$pkg" >"$tmp" 2>&1 || st=$?
  fi

  st=${st:-0}
  cat "$tmp" | tee -a "$out" >&2
  rm -f "$tmp" 2>/dev/null || true

  [ "$st" -eq 0 ] || die "pm install falhou para: $pkg"
}

# checks de sanidade por estágio (evita “construiu mas não gerou nada”)
check_binutils() {
  [ -d "$TC_PREFIX/bin" ] || die "binutils: TC_PREFIX/bin não existe"
  # pelo menos um dos binutils comuns
  if [ ! -x "$TC_PREFIX/bin/${TARGET}-ld" ] && [ ! -x "$TC_PREFIX/bin/ld" ]; then
    log "AVISO: não encontrei ${TARGET}-ld nem ld em $TC_PREFIX/bin; verifique a receita binutils."
  fi
}

check_headers() {
  # headers normalmente em $TC_SYSROOT/usr/include
  [ -d "$TC_SYSROOT/usr/include" ] || die "linux-headers: $TC_SYSROOT/usr/include não existe (receita deve instalar no sysroot)"
}

check_musl() {
  # musl final deve criar loader e libc no sysroot
  # (caminhos podem variar, então checamos sinais comuns)
  if [ ! -f "$TC_SYSROOT/usr/lib/libc.so" ] && [ ! -f "$TC_SYSROOT/lib/libc.so" ]; then
    log "AVISO: musl: libc.so não encontrada em sysroot; verifique receita."
  fi
}

check_gcc() {
  if [ ! -x "$TC_PREFIX/bin/${TARGET}-gcc" ]; then
    log "AVISO: gcc: ${TARGET}-gcc não encontrado em $TC_PREFIX/bin; env.sh usará fallback do host."
  fi
}

check_busybox_sysroot() {
  if [ ! -x "$TC_SYSROOT/bin/sh" ] && [ ! -x "$TC_SYSROOT/bin/busybox" ]; then
    log "AVISO: busybox: /bin/sh e /bin/busybox não encontrados no sysroot. Para chroot, isso é crítico."
  fi
}

check_xz_sysroot() {
  if [ ! -x "$TC_SYSROOT/bin/xz" ]; then
    log "AVISO: xz: /bin/xz não encontrado no sysroot. Para pm rodar confortável no chroot, é recomendado."
  fi
}

do_clean() {
  if [ -d "$BOOTSTRAP_DIR" ]; then
    log "Removendo: $BOOTSTRAP_DIR"
    safe_rm_rf "$BOOTSTRAP_DIR"
  fi
  log "clean concluído."
}

bootstrap() {
  doctor
  lock_acquire
  trap 'lock_release' EXIT INT TERM

  if [ "$CLEAN" = "1" ]; then
    do_clean || true
  fi

  mkdir -p "$TC_PREFIX" "$TC_SYSROOT" "$TC_LOGDIR"
  : >"$TC_LOGDIR/bootstrap.log"

  write_env

  log "BOOTSTRAP_DIR=$BOOTSTRAP_DIR"
  log "TC_PREFIX=$TC_PREFIX"
  log "TC_SYSROOT=$TC_SYSROOT"
  log "TARGET=$TARGET"
  log "JOBS=$JOBS"
  log "WITH_XZ=$WITH_XZ WITH_BUSYBOX=$WITH_BUSYBOX"

  BINUTILS=$(pick_pkg bootstrap/binutils toolchain/binutils)
  LINUX_HEADERS=$(pick_pkg bootstrap/linux-headers bootstrap/kernel-headers toolchain/linux-headers)
  GCC_STAGE1=$(pick_pkg bootstrap/gcc-stage1 toolchain/gcc-stage1)
  MUSL=$(pick_pkg bootstrap/musl toolchain/musl)
  GCC_FINAL=$(pick_pkg bootstrap/gcc-final toolchain/gcc-final 2>/dev/null || echo "")

  # Opcional (recomendado): xz e busybox no sysroot para facilitar chroot + builds posteriores
  XZ_PKG=""
  BB_PKG=""
  if [ "$WITH_XZ" = "1" ]; then
    XZ_PKG=$(pick_pkg bootstrap/xz toolchain/xz 2>/dev/null || echo "")
  fi
  if [ "$WITH_BUSYBOX" = "1" ]; then
    BB_PKG=$(pick_pkg bootstrap/busybox toolchain/busybox 2>/dev/null || echo "")
  fi

  # 1) binutils
  run_pm_install "$BINUTILS"
  check_binutils

  # 2) linux headers (DEVE ir para sysroot via TC_SYSROOT na receita)
  run_pm_install "$LINUX_HEADERS"
  check_headers

  # 3) gcc stage1
  run_pm_install "$GCC_STAGE1"
  check_gcc

  # 4) musl (DEVE ir para sysroot via TC_SYSROOT na receita)
  run_pm_install "$MUSL"
  check_musl

  # 5) gcc final (opcional mas recomendado)
  if [ -n "$GCC_FINAL" ]; then
    run_pm_install "$GCC_FINAL"
    check_gcc
  else
    log "AVISO: gcc-final não encontrado; você ficará com stage1 (pode limitar builds no chroot)."
  fi

  # 6) opcional: xz no sysroot (melhora robustez do pm/tar.xz no chroot)
  if [ -n "$XZ_PKG" ]; then
    run_pm_install "$XZ_PKG"
    check_xz_sysroot
  fi

  # 7) opcional: busybox no sysroot (necessário para /bin/sh no chroot mínimo)
  if [ -n "$BB_PKG" ]; then
    run_pm_install "$BB_PKG"
    check_busybox_sysroot
  fi

  # Limpa builds do pm (mantém cache binário)
  if [ "$KEEP_WORK" != "1" ]; then
    log "Limpando diretórios de build do pm (mantendo cache)..."
    if [ -x "$PM" ]; then
      "$PM" clean 2>&1 | tee -a "$TC_LOGDIR/bootstrap.log" >&2 || die "pm clean falhou"
    else
      sh "$PM" clean 2>&1 | tee -a "$TC_LOGDIR/bootstrap.log" >&2 || die "pm clean falhou"
    fi
  fi

  write_env

  log "Bootstrap concluído."
  log "Assuma a toolchain temporária:"
  log "  . $TC_ENV"
  if [ -x "$TC_SYSROOT/bin/sh" ]; then
    log "Sysroot já tem /bin/sh (ok para chroot mínimo)."
  else
    log "AVISO: sysroot NÃO tem /bin/sh; para chroot mínimo, instale bootstrap/busybox."
  fi
}

cmd=${1:-bootstrap}
case "$cmd" in
  bootstrap) bootstrap ;;
  clean) do_clean ;;
  env) echo "$TC_ENV" ;;
  doctor) doctor ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
