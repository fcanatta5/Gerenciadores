#!/bin/sh
# pm-bootstrap.sh
# Bootstrap de toolchain temporária (POSIX sh) usando pm.sh
#
# Objetivo:
# - Construir uma toolchain temporária (binutils + headers + musl + gcc) em um prefix isolado
# - Gerar um arquivo de ambiente para o pm “assumir corretamente” (PATH/CC/etc)
#
# Pré-requisitos:
# - Um compilador/assembler/linker funcional no host (ex.: gcc/clang + binutils) para o estágio 0
# - ./pm.sh na mesma pasta deste script
# - Receitas no repo para toolchain (nomes sugeridos abaixo)
#
# Convenções recomendadas de receitas (você pode adaptar o script):
#   core/binutils
#   core/linux-headers         (ou core/kernel-headers)
#   core/musl                  (ou core/musl-headers + core/musl)
#   core/gcc                   (ou core/gcc-stage1 + core/gcc-final)
#
# Variáveis configuráveis:
#   TARGET=x86_64-linux-musl
#   BOOTSTRAP_DIR=state/toolchain
#   JOBS=1
#   KEEP_WORK=0
#   CLEAN=1

set -eu

PM_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PM="$PM_ROOT/pm.sh"
PKGS_DIR="$PM_ROOT/pkgs"

: "${TARGET:=x86_64-linux-musl}"
: "${BOOTSTRAP_DIR:=$PM_ROOT/state/toolchain}"
: "${JOBS:=1}"
: "${KEEP_WORK:=0}"
: "${CLEAN:=1}"

TC_PREFIX="$BOOTSTRAP_DIR/prefix"      # onde o pm instalará os binários do toolchain
TC_SYSROOT="$BOOTSTRAP_DIR/sysroot"   # sysroot (libc/headers finais) – receitas devem usar
TC_LOGDIR="$BOOTSTRAP_DIR/logs"
TC_ENV="$BOOTSTRAP_DIR/env.sh"

ts() { date -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date; }
log() { printf "%s [BOOT] %s\n" "$(ts)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

need_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Comando requerido não encontrado: $c"
  done
}

pkg_dir() {
  # $1 = cat/pkg
  echo "$PKGS_DIR/$1"
}

pkg_exists() {
  [ -d "$(pkg_dir "$1")" ]
}

run_pm_install() {
  pkg=$1
  log "Instalando via pm: $pkg"
  # Importante: passamos PM_PREFIX para instalar tudo dentro do TC_PREFIX,
  # e exportamos também TARGET/TC_SYSROOT para as receitas de toolchain.
  PM_PREFIX="$TC_PREFIX" \
  PM_JOBS="$JOBS" \
  TARGET="$TARGET" \
  TC_PREFIX="$TC_PREFIX" \
  TC_SYSROOT="$TC_SYSROOT" \
  BOOTSTRAP=1 \
  "$PM" install "$pkg" 2>&1 | tee -a "$TC_LOGDIR/bootstrap.log" >&2
}

# Escolhe o primeiro pacote existente em uma lista de alternativas
pick_pkg() {
  for p in "$@"; do
    if pkg_exists "$p"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

# Limpeza segura do bootstrap dir (fora do pm)
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
  # Gera um arquivo para "assumir corretamente" (source antes de usar o pm)
  cat >"$TC_ENV" <<EOF
# Fonte este arquivo: . "$TC_ENV"
# Toolchain temporária gerada por pm-bootstrap.sh

export TARGET='${TARGET}'
export TC_PREFIX='${TC_PREFIX}'
export TC_SYSROOT='${TC_SYSROOT}'

# Toolchain no PATH
export PATH="\${TC_PREFIX}/bin:\${PATH}"

# Compiladores (se as receitas criarem toolchain prefixada)
if [ -x "\${TC_PREFIX}/bin/\${TARGET}-gcc" ]; then
  export CC="\${TC_PREFIX}/bin/\${TARGET}-gcc"
  export CXX="\${TC_PREFIX}/bin/\${TARGET}-g++"
  export AR="\${TC_PREFIX}/bin/\${TARGET}-ar"
  export AS="\${TC_PREFIX}/bin/\${TARGET}-as"
  export LD="\${TC_PREFIX}/bin/\${TARGET}-ld"
  export RANLIB="\${TC_PREFIX}/bin/\${TARGET}-ranlib"
  export STRIP="\${TC_PREFIX}/bin/\${TARGET}-strip"
else
  # fallback: use o cc do host com sysroot (se aplicável)
  export CC="\${CC:-cc}"
  export CXX="\${CXX:-c++}"
fi

# Flags base (receitas podem sobrescrever)
export CFLAGS="\${CFLAGS:-} --sysroot=\${TC_SYSROOT}"
export LDFLAGS="\${LDFLAGS:-} --sysroot=\${TC_SYSROOT}"
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

Exemplo:
  JOBS=4 TARGET=x86_64-linux-musl ./pm-bootstrap.sh bootstrap
  . ${TC_ENV}
  ./pm.sh install core/zlib
EOF
}

doctor() {
  [ -x "$PM" ] || die "pm.sh não encontrado/executável em: $PM"
  need_cmd sh find sort awk sed tar xz sha256sum mkdir rm mv date

  # Necessidades típicas para bootstrap (host)
  # (Você pode ter clang em vez de gcc; testamos cc.)
  command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 \
    || die "Nenhum compilador encontrado no host (cc/gcc/clang). Necessário para stage0."
  command -v make >/dev/null 2>&1 || die "make não encontrado no host. Necessário para stage0."
  command -v patch >/dev/null 2>&1 || log "AVISO: patch não encontrado (ok se você não usa patch/ nas receitas)."

  # Receitas mínimas
  BINUTILS=$(pick_pkg bootstrap/binutils toolchain/binutils) || die "Receita binutils não encontrada (bootstrap/binutils)."
  LINUX_HEADERS=$(pick_pkg bootstrap/linux-headers bootstrap/kernel-headers toolchain/linux-headers) || die "Receita de headers do kernel não encontrada."
  MUSL=$(pick_pkg bootstrap/musl toolchain/musl) || die "Receita musl não encontrada."
  GCC_STAGE1=$(pick_pkg bootstrap/gcc-stage1 toolchain/gcc-stage1 bootstrap/gcc) || die "Receita gcc não encontrada."
  log "OK receitas:"
  log "  BINUTILS=$BINUTILS"
  log "  LINUX_HEADERS=$LINUX_HEADERS"
  log "  MUSL=$MUSL"
  log "  GCC_STAGE1(or gcc)=$GCC_STAGE1"

  # Opcional: gcc final
  if pick_pkg core/gcc-final toolchain/gcc-final >/dev/null 2>&1; then
    log "  GCC_FINAL=$(pick_pkg core/gcc-final toolchain/gcc-final)"
  else
    log "  GCC_FINAL: não encontrado (o script usará core/gcc se não houver split stage)."
  fi

  log "doctor concluído."
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

  mkdir -p "$TC_LOGDIR"
  : >"$TC_LOGDIR/bootstrap.log"

  if [ "$CLEAN" = "1" ]; then
    do_clean || true
  fi

  mkdir -p "$TC_PREFIX" "$TC_SYSROOT" "$TC_LOGDIR"

  # Env inicial: PATH aponta para TC_PREFIX/bin mesmo antes de existir, para “assumir” assim que instalar binutils/gcc.
  write_env

  log "BOOTSTRAP_DIR=$BOOTSTRAP_DIR"
  log "TC_PREFIX=$TC_PREFIX"
  log "TC_SYSROOT=$TC_SYSROOT"
  log "TARGET=$TARGET"
  log "JOBS=$JOBS"

  # Seleciona nomes conforme suas receitas existirem
  BINUTILS=$(pick_pkg bootstrap/binutils toolchain/binutils)
  LINUX_HEADERS=$(pick_pkg bootstrap/linux-headers bootstrap/kernel-headers toolchain/linux-headers)
  MUSL=$(pick_pkg bootstrap/musl toolchain/musl)
  GCC_STAGE1=$(pick_pkg bootstrap/gcc-stage1 toolchain/gcc-stage1)
  GCC_FINAL=$(pick_pkg bootstrap/gcc-final toolchain/gcc-final 2>/dev/null || echo "")
  # 1) binutils (assembler/linker/ar/ranlib)
  run_pm_install "$BINUTILS"

  # 2) headers do kernel (instala em sysroot; receitas devem obedecer TC_SYSROOT)
  run_pm_install "$LINUX_HEADERS"

  # 3) gcc stage1 (se existir). Se não existir, cai para core/gcc (monolítico).
  #    Stage1 normalmente usa --without-headers/--with-newlib e/ou sysroot vazio.
  if [ -n "$GCC_STAGE1" ]; then
    run_pm_install "$GCC_STAGE1"
  else
    # fallback para gcc monolítico
    if pkg_exists core/gcc; then
      run_pm_install core/gcc
    else
      die "Nenhuma receita gcc-stage1 ou core/gcc encontrada."
    fi
  fi

  # 4) musl (instala headers+libc no sysroot; receitas devem usar TC_SYSROOT)
  run_pm_install "$MUSL"

  # 5) gcc final (se existir). Caso contrário, reinstala/instala core/gcc para gerar toolchain completa.
  if [ -n "$GCC_FINAL" ]; then
    run_pm_install "$GCC_FINAL"
  else
    # Se você usa receita única core/gcc (sem split), instale agora (se não instalou) ou reinstale para linkar com musl completa.
    if pkg_exists core/gcc; then
      run_pm_install core/gcc
    else
      log "AVISO: gcc-final não existe e core/gcc não existe; mantendo stage1."
    fi
  fi

  # Opcional: limpeza de work/build do pm (mantém cache binário)
  if [ "$KEEP_WORK" != "1" ]; then
    # limpa build roots do pm (mas não apaga cache de binários)
    # nota: depende do seu pm.sh ter o comando clean (o seu tem).
    log "Limpando diretórios de build do pm (mantendo cache)..."
    "$PM" clean 2>&1 | tee -a "$TC_LOGDIR/bootstrap.log" >&2
  fi

  write_env

  log "Bootstrap concluído."
  log "Para assumir a toolchain temporária:"
  log "  . $TC_ENV"
  log "Depois, rode o pm normalmente para construir o sistema usando essa toolchain."
  log "Exemplo:"
  log "  . $TC_ENV"
  log "  ./pm.sh install core/zlib"
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
