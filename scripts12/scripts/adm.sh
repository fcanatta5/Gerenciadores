#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ADM - Rolling Release Source Manager (Shell Script)
# Layout do pacote:
#   /var/lib/adm/packages/<categoria>/<programa>/
#     build            (arquivo executável ou sourceable bash com metadados+funções)
#     patch/           (*.patch / *.diff aplicados automaticamente)
#     files/           (overlay copiado para DESTDIR antes do empacotamento)
#
# Build script do pacote (obrigatório):
#   .../<categoria>/<programa>/build
#
# Requisitos do build script:
#   Variáveis:
#     PKG_NAME, PKG_VERSION, PKG_RELEASE, PKG_DESC, PKG_LICENSE, PKG_URL
#     PKG_SOURCES (array), PKG_SUMS (array: sha256:<hex> | md5:<hex> | skip)
#     PKG_DEPS (array) opcional
#     PKG_BUILD_DEPS (array) opcional
#   Funções:
#     build()   obrigatório (compilar)
#     install() obrigatório (instalar em $DESTDIR)
#     Hooks opcionais:
#       pre_build, post_build, pre_install, post_install, pre_uninstall, post_uninstall
#     upstream_check() opcional: imprime "versao url" se houver atualização
###############################################################################

# =========================
# CONFIGURAÇÃO NO TOPO
# =========================
ADM_ROOT="/var/lib/adm"
PKGROOT="$ADM_ROOT/packages"
CACHEDL="$ADM_ROOT/cache/sources"
CACHEPKG="$ADM_ROOT/cache/packages"
LOGROOT="$ADM_ROOT/logs"
DBROOT="$ADM_ROOT/db"
WORKROOT="$ADM_ROOT/work"
LOCKFILE="$ADM_ROOT/adm.lock"

# Chroot build environment
CHROOT_ROOT="$ADM_ROOT/chroot"
CHROOT_MOUNTS=( "dev" "dev/pts" "proc" "sys" "run" )
CHROOT_SHELL="/bin/sh"   # dentro do chroot precisa existir
HOST_RESOLV="/etc/resolv.conf"

# Ferramentas
ARIA2C="${ARIA2C:-aria2c}"
ARIA2C_JOBS="${ARIA2C_JOBS:-8}"
ARIA2C_SPLIT="${ARIA2C_SPLIT:-8}"
ARIA2C_CONN="${ARIA2C_CONN:-16}"

ZSTD_LEVEL="${ZSTD_LEVEL:-19}"
XZ_LEVEL="${XZ_LEVEL:--9e}"

NOTIFY_BIN="${NOTIFY_BIN:-notify-send}"

# Git sync
GIT_REMOTE="${GIT_REMOTE:-}"   # ex: https://seu.repo/adm-packages.git
GIT_BRANCH="${GIT_BRANCH:-main}"

# =========================
# ESTADO GLOBAL (opções)
# =========================
USE_COLOR=1
DRYRUN=0
QUIET=0
SKIP_VERIFY=0
SKIP_IF_CACHED=0

CHECK_MARK="✔️"
CROSS_MARK="✖"

# =========================
# CORES (recalculáveis)
# =========================
C_RESET="" C_BOLD="" C_RED="" C_GRN="" C_YLW="" C_BLU="" C_CYN=""

setup_colors() {
  if [[ -t 1 && "$USE_COLOR" -eq 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_RED=$'\033[1;31m'
    C_GRN=$'\033[1;32m'
    C_YLW=$'\033[1;33m'
    C_BLU=$'\033[1;34m'
    C_CYN=$'\033[1;36m'
  else
    C_RESET="" C_BOLD="" C_RED="" C_GRN="" C_YLW="" C_BLU="" C_CYN=""
  fi
}

ts() { date -Is; }

say()  { [[ "$QUIET" -eq 1 ]] || printf "%s\n" "$*"; }
info() { say "${C_CYN}${C_BOLD}==>${C_RESET} $*"; }
ok()   { say "${C_GRN}${C_BOLD}OK${C_RESET}  $*"; }
warn() { say "${C_YLW}${C_BOLD}WARN${C_RESET} $*"; }
err()  { say "${C_RED}${C_BOLD}ERRO${C_RESET} $*"; }
die()  { err "$*"; exit 1; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Execute como root."; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Execução segura sem eval (aceita argv)
run() {
  if [[ "$DRYRUN" -eq 1 ]]; then
    # imprimir com quoting simples
    local out=()
    local a
    for a in "$@"; do
      out+=( "$(printf "%q" "$a")" )
    done
    say "${C_BLU}(dry-run)${C_RESET} ${out[*]}"
    return 0
  fi
  "$@"
}

mkdirs() {
  run mkdir -p "$PKGROOT" "$CACHEDL" "$CACHEPKG" "$LOGROOT" "$DBROOT" "$WORKROOT" "$CHROOT_ROOT"
}

mounted() {
  # 0 se montado, 1 caso contrário
  mountpoint -q "$1"
}

with_lock() {
  mkdir -p "$(dirname "$LOCKFILE")"
  have_cmd flock || die "flock não encontrado (necessário para trava)."
  exec 9>"$LOCKFILE"
  flock -n 9 || die "Outra operação do ADM já está em execução (lock: $LOCKFILE)."
  "$@"
}

# =========================
# SANITIZAÇÃO DE SPEC
# =========================
valid_spec() {
  # categoria/programa com caracteres seguros
  [[ "$1" =~ ^[A-Za-z0-9._+-]+/[A-Za-z0-9._+-]+$ ]]
}

pkg_path_from_spec() {
  local spec="$1"
  valid_spec "$spec" || die "Spec inválido: '$spec' (use categoria/programa; chars: A-Za-z0-9._+-)"
  printf "%s\n" "$PKGROOT/$spec"
}

pkg_build_script() {
  local spec="$1"
  printf "%s\n" "$(pkg_path_from_spec "$spec")/build"
}

pkg_patch_dir() {
  local spec="$1"
  printf "%s\n" "$(pkg_path_from_spec "$spec")/patch"
}

pkg_files_dir() {
  local spec="$1"
  printf "%s\n" "$(pkg_path_from_spec "$spec")/files"
}

pkg_db_dir() {
  local spec="$1"
  printf "%s\n" "$DBROOT/${spec//\//__}"
}

is_installed() {
  local spec="$1"
  [[ -f "$(pkg_db_dir "$spec")/installed" ]]
}

installed_mark() {
  local spec="$1"
  if is_installed "$spec"; then
    printf "< %s >" "$CHECK_MARK"
  else
    printf "<   >"
  fi
}

# =========================
# METADADOS DO PACOTE
# =========================
# Carrega build script em subshell para reduzir vazamento de variáveis globais
# e exporta somente o necessário via "declare -p".
read_pkg_meta() {
  local spec="$1"
  local bs
  bs="$(pkg_build_script "$spec")"
  [[ -r "$bs" ]] || die "build não encontrado: $bs"

  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  # Extrai variáveis via subshell
  if [[ "$DRYRUN" -eq 1 ]]; then
    # dry-run: ainda precisamos validar presença do arquivo
    :
  fi

  bash -c "
    set -euo pipefail
    source '$bs'
    : \"\${PKG_NAME:?}\"
    : \"\${PKG_VERSION:?}\"
    : \"\${PKG_RELEASE:?}\"
    : \"\${PKG_DESC:?}\"
    : \"\${PKG_LICENSE:?}\"
    : \"\${PKG_URL:?}\"
    declare -p PKG_NAME PKG_VERSION PKG_RELEASE PKG_DESC PKG_LICENSE PKG_URL
    declare -p PKG_SOURCES PKG_SUMS
    declare -p PKG_DEPS 2>/dev/null || true
    declare -p PKG_BUILD_DEPS 2>/dev/null || true
  " >"$tmp"

  # shellcheck disable=SC1090
  source "$tmp"

  # Normaliza arrays se não existirem
  if ! declare -p PKG_DEPS >/dev/null 2>&1; then
    PKG_DEPS=()
  fi
  if ! declare -p PKG_BUILD_DEPS >/dev/null 2>&1; then
    PKG_BUILD_DEPS=()
  fi

  # Verificações finais
  [[ "$(declare -p PKG_SOURCES 2>/dev/null || true)" == declare\ -a* ]] || die "PKG_SOURCES deve ser array em $spec"
  [[ "$(declare -p PKG_SUMS 2>/dev/null || true)" == declare\ -a* ]] || die "PKG_SUMS deve ser array em $spec"
  [[ "${#PKG_SOURCES[@]}" -eq "${#PKG_SUMS[@]}" ]] || die "PKG_SOURCES e PKG_SUMS devem ter mesmo tamanho em $spec"
}

# =========================
# DEPENDÊNCIAS (DFS com detecção de ciclo)
# =========================
declare -A VISITING=()
declare -A VISITED=()
declare -a ORDER=()

reset_graph() { VISITING=(); VISITED=(); ORDER=(); }

dfs() {
  local spec="$1"
  if [[ -n "${VISITED[$spec]:-}" ]]; then return 0; fi
  if [[ -n "${VISITING[$spec]:-}" ]]; then
    die "Dependência circular detectada envolvendo: $spec"
  fi

  VISITING["$spec"]=1
  read_pkg_meta "$spec"

  local dep
  for dep in "${PKG_DEPS[@]}" "${PKG_BUILD_DEPS[@]}"; do
    [[ -z "${dep:-}" ]] && continue
    valid_spec "$dep" || die "Dependência inválida em $spec: '$dep'"
    dfs "$dep"
  done

  VISITING["$spec"]=""
  VISITED["$spec"]=1
  ORDER+=( "$spec" )
}

resolve_deps_order() {
  local spec="$1"
  reset_graph
  dfs "$spec"
  printf "%s\n" "${ORDER[@]}"
}

# =========================
# DOWNLOAD + CHECKSUM
# =========================
require_download_tool() {
  have_cmd "$ARIA2C" || die "Requer aria2c (aria2). Instale e tente novamente."
  have_cmd sha256sum || die "sha256sum não encontrado."
  have_cmd md5sum || die "md5sum não encontrado."
}

cache_name_for_url() {
  # nome único: <sha256(url)>-<basename_sem_query>
  local url="$1"
  local base="${url%%\?*}"
  local bn="${base##*/}"
  local h
  h="$(printf "%s" "$url" | sha256sum | awk '{print $1}')"
  printf "%s-%s\n" "$h" "$bn"
}

checksum_ok() {
  local file="$1"
  local sumspec="$2"

  [[ "$sumspec" == "skip" ]] && return 0

  if [[ "$sumspec" == sha256:* ]]; then
    local want="${sumspec#sha256:}"
    local got
    got="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$got" == "$want" ]]
    return
  fi
  if [[ "$sumspec" == md5:* ]]; then
    local want="${sumspec#md5:}"
    local got
    got="$(md5sum "$file" | awk '{print $1}')"
    [[ "$got" == "$want" ]]
    return
  fi

  # hex puro: tenta sha256 (64) ou md5 (32)
  if [[ "$sumspec" =~ ^[a-fA-F0-9]{64}$ ]]; then
    [[ "$(sha256sum "$file" | awk '{print $1}')" == "$sumspec" ]]
    return
  fi
  if [[ "$sumspec" =~ ^[a-fA-F0-9]{32}$ ]]; then
    [[ "$(md5sum "$file" | awk '{print $1}')" == "$sumspec" ]]
    return
  fi

  die "Formato de checksum inválido: $sumspec"
}

download_sources_parallel() {
  local spec="$1"
  local skip_verify="$2"    # 1/0
  local skip_if_cached="$3" # 1/0

  read_pkg_meta "$spec"
  require_download_tool

  local pkgcache="$CACHEDL/${spec//\//__}"
  run mkdir -p "$pkgcache"

  local listfile
  listfile="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$listfile'" RETURN

  local i url sum name dest
  for i in "${!PKG_SOURCES[@]}"; do
    url="${PKG_SOURCES[$i]}"
    sum="${PKG_SUMS[$i]}"
    name="$(cache_name_for_url "$url")"
    dest="$pkgcache/$name"

    if [[ "$skip_if_cached" -eq 1 && -f "$dest" ]]; then
      if [[ "$skip_verify" -eq 1 || "$sum" == "skip" || checksum_ok "$dest" "$sum" ]]; then
        ok "Source em cache: $name"
        continue
      else
        warn "Checksum falhou (cache): $name. Removendo e rebaixando."
        run rm -f "$dest"
      fi
    fi

    {
      echo "$url"
      echo "  out=$name"
      echo "  dir=$pkgcache"
    } >> "$listfile"
  done

  if [[ -s "$listfile" ]]; then
    info "Baixando sources em paralelo para $spec"
    run "$ARIA2C" \
      --allow-overwrite=true --auto-file-renaming=false \
      --max-concurrent-downloads="$ARIA2C_JOBS" \
      --split="$ARIA2C_SPLIT" --max-connection-per-server="$ARIA2C_CONN" \
      --file-allocation=none --summary-interval=1 --console-log-level=warn \
      --input-file="$listfile"
  else
    ok "Nada para baixar (tudo em cache)."
  fi

  if [[ "$skip_verify" -eq 1 ]]; then
    warn "Checksum SKIP habilitado: não verificando sources."
    return 0
  fi

  info "Verificando checksums"
  for i in "${!PKG_SOURCES[@]}"; do
    url="${PKG_SOURCES[$i]}"
    sum="${PKG_SUMS[$i]}"
    name="$(cache_name_for_url "$url")"
    dest="$pkgcache/$name"

    [[ -f "$dest" ]] || die "Source ausente após download: $dest"
    [[ "$sum" == "skip" ]] && { warn "Checksum skip: $name"; continue; }

    if checksum_ok "$dest" "$sum"; then
      ok "Checksum OK: $name"
    else
      warn "Checksum FALHOU: $name. Rebaixando."
      run rm -f "$dest"

      local onefile
      onefile="$(mktemp)"
      # shellcheck disable=SC2064
      trap "rm -f '$onefile'" RETURN
      {
        echo "$url"
        echo "  out=$name"
        echo "  dir=$pkgcache"
      } > "$onefile"

      run "$ARIA2C" \
        --allow-overwrite=true --auto-file-renaming=false \
        --split="$ARIA2C_SPLIT" --max-connection-per-server="$ARIA2C_CONN" \
        --file-allocation=none --summary-interval=1 --console-log-level=warn \
        --input-file="$onefile"

      checksum_ok "$dest" "$sum" || die "Checksum continua falhando após redownload: $name"
      ok "Checksum OK após redownload: $name"
    fi
  done
}

# =========================
# CHROOT (build seguro)
# =========================
chroot_require_minimum() {
  [[ -x "$CHROOT_ROOT/bin/sh" || -x "$CHROOT_ROOT/bin/bash" ]] || die "Chroot sem /bin/sh (ou /bin/bash). Instale base mínima no chroot."
  [[ -x "$CHROOT_ROOT/usr/bin/env" ]] || die "Chroot sem /usr/bin/env. Instale coreutils/posix env no chroot."
}

chroot_setup() {
  need_root
  mkdirs

  # cria dirs reais (sem brace expansion quebrada)
  run mkdir -p \
    "$CHROOT_ROOT" \
    "$CHROOT_ROOT/dev" \
    "$CHROOT_ROOT/dev/pts" \
    "$CHROOT_ROOT/proc" \
    "$CHROOT_ROOT/sys" \
    "$CHROOT_ROOT/run" \
    "$CHROOT_ROOT/tmp" \
    "$CHROOT_ROOT/root" \
    "$CHROOT_ROOT/etc" \
    "$CHROOT_ROOT/adm" \
    "$CHROOT_ROOT/cache" \
    "$CHROOT_ROOT/out" \
    "$CHROOT_ROOT/tools"

  run chmod 1777 "$CHROOT_ROOT/tmp" || true

  # DNS
  if [[ -r "$HOST_RESOLV" ]]; then
    run cp -L "$HOST_RESOLV" "$CHROOT_ROOT/etc/resolv.conf"
  fi

  # mounts essenciais
  mounted "$CHROOT_ROOT/dev"      || run mount --bind /dev "$CHROOT_ROOT/dev"
  mounted "$CHROOT_ROOT/dev/pts"  || run mount -t devpts devpts "$CHROOT_ROOT/dev/pts" -o gid=5,mode=620
  mounted "$CHROOT_ROOT/proc"     || run mount -t proc proc "$CHROOT_ROOT/proc"
  mounted "$CHROOT_ROOT/sys"      || run mount -t sysfs sysfs "$CHROOT_ROOT/sys"
  mounted "$CHROOT_ROOT/run"      || run mount --bind /run "$CHROOT_ROOT/run"

  # binds do ADM e caches
  mounted "$CHROOT_ROOT/adm"   || run mount --bind "$ADM_ROOT" "$CHROOT_ROOT/adm"
  mounted "$CHROOT_ROOT/cache" || run mount --bind "$ADM_ROOT/cache" "$CHROOT_ROOT/cache"
  mounted "$CHROOT_ROOT/out"   || run mount --bind "$ADM_ROOT/cache/packages" "$CHROOT_ROOT/out"

  # toolchain temporário (se existir)
  if [[ -d "/mnt/adm/tools" ]]; then
    mounted "$CHROOT_ROOT/tools" || run mount --bind "/mnt/adm/tools" "$CHROOT_ROOT/tools"
  fi

  chroot_require_minimum
}

chroot_teardown() {
  need_root

  local p
  for p in "$CHROOT_ROOT/tools" "$CHROOT_ROOT/out" "$CHROOT_ROOT/cache" "$CHROOT_ROOT/adm"; do
    if mounted "$p"; then
      run umount "$p" || run umount -l "$p"
    fi
  done

  local i
  for (( i=${#CHROOT_MOUNTS[@]}-1; i>=0; i-- )); do
    p="$CHROOT_ROOT/${CHROOT_MOUNTS[$i]}"
    if mounted "$p"; then
      run umount "$p" || run umount -l "$p"
    fi
  done
}

chroot_exec() {
  local cmd="$1"
  local -a envs=(
    "HOME=/root"
    "TERM=${TERM:-xterm-256color}"
    "PATH=/tools/bin:/usr/bin:/usr/sbin:/bin:/sbin"
    "LANG=C"
    "LC_ALL=C"
  )

  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} chroot $(printf "%q" "$CHROOT_ROOT") env -i ... sh -lc $(printf "%q" "$cmd")"
    return 0
  fi

  chroot "$CHROOT_ROOT" /usr/bin/env -i "${envs[@]}" "$CHROOT_SHELL" -lc "$cmd"
}

# Smoke test do toolchain dentro do chroot (se existir)
chroot_toolchain_smoke() {
  # não falha se toolchain não existe; falha apenas se existir mas não funciona
  local cc="x86_64-linux-musl-gcc"
  if [[ ! -d "/mnt/adm/tools/bin" ]]; then
    return 0
  fi

  info "Validando toolchain dentro do chroot: $cc"
  chroot_exec "
    set -e
    command -v $cc >/dev/null 2>&1 || { echo 'NOK: $cc não encontrado no PATH'; exit 1; }
    cat > /tmp/__adm_cc_test.c <<'EOF'
int main(void){return 0;}
EOF
    $cc /tmp/__adm_cc_test.c -o /tmp/__adm_cc_test
    command -v readelf >/dev/null 2>&1 && readelf -h /tmp/__adm_cc_test >/dev/null || true
    echo 'OK: toolchain funcional no chroot'
  "
}

# =========================
# BUILD / PATCH / FILES / PKG
# =========================
pkg_log_dir() { printf "%s\n" "$LOGROOT/${1//\//__}"; }
pkg_work_dir() { printf "%s\n" "$WORKROOT/${1//\//__}"; }

pkg_pkgfile_base() {
  local spec="$1"
  read_pkg_meta "$spec"
  printf "%s-%s-%s\n" "${spec//\//__}" "$PKG_VERSION" "$PKG_RELEASE"
}

apply_patches() {
  local spec="$1" srcdir="$2"
  local pdir
  pdir="$(pkg_patch_dir "$spec")"
  [[ -d "$pdir" ]] || return 0

  shopt -s nullglob
  local patch
  for patch in "$pdir"/*.patch "$pdir"/*.diff; do
    info "Aplicando patch: $(basename "$patch")"
    run patch -d "$srcdir" -p1 < "$patch"
  done
  shopt -u nullglob
}

copy_files_overlay() {
  local spec="$1" destdir="$2"
  local fdir
  fdir="$(pkg_files_dir "$spec")"
  [[ -d "$fdir" ]] || return 0
  info "Aplicando overlay files/ em DESTDIR"
  run cp -a "$fdir"/. "$destdir"/
}

extract_sources_heuristic() {
  local pkgcache="$1"
  local outdir="$2"

  run mkdir -p "$outdir"

  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} extrair fontes em $(printf "%q" "$outdir")"
    return 0
  fi

  shopt -s nullglob
  local f
  for f in "$pkgcache"/*; do
    case "$f" in
      *.tar.gz|*.tgz) tar -xzf "$f" -C "$outdir" ;;
      *.tar.xz)       tar -xJf "$f" -C "$outdir" ;;
      *.tar.zst)      zstd -dc "$f" | tar -xf - -C "$outdir" ;;
      *.tar.bz2)      tar -xjf "$f" -C "$outdir" ;;
      *.zip)          unzip -q "$f" -d "$outdir" ;;
      *)              : ;;
    esac
  done
  shopt -u nullglob
}

make_pkg_tarball() {
  local spec="$1" destdir="$2"
  local base outdir pkgfile

  base="$(pkg_pkgfile_base "$spec")"
  outdir="$CACHEPKG"
  run mkdir -p "$outdir"

  if have_cmd zstd; then
    pkgfile="$outdir/${base}.tar.zst"
    info "Empacotando (tar.zst) -> $(basename "$pkgfile")"
    if [[ "$DRYRUN" -eq 1 ]]; then
      say "${C_BLU}(dry-run)${C_RESET} tar -C DESTDIR -cf - . | zstd -$ZSTD_LEVEL -o PKG"
    else
      tar -C "$destdir" -cf - . | zstd -T0 "-$ZSTD_LEVEL" -o "$pkgfile"
    fi
    printf "%s\n" "$pkgfile"
    return 0
  fi

  pkgfile="$outdir/${base}.tar.xz"
  info "Empacotando (tar.xz fallback) -> $(basename "$pkgfile")"
  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} XZ_OPT=$(printf "%q" "$XZ_LEVEL") tar -C DESTDIR -cJf PKG ."
  else
    XZ_OPT="$XZ_LEVEL" tar -C "$destdir" -cJf "$pkgfile" .
  fi
  printf "%s\n" "$pkgfile"
}

# Cria lista de arquivos a partir do DESTDIR (para DB)
record_install_db_from_destdir() {
  local spec="$1" destdir="$2"
  local dbd
  dbd="$(pkg_db_dir "$spec")"
  run mkdir -p "$dbd"

  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} gravar DB (DESTDIR) em $dbd"
    return 0
  fi

  ( cd "$destdir" && find . -type f -o -type l -o -type d | sed 's|^\./|/|' | sort ) > "$dbd/files"
  printf "%s\n" "$(ts)" > "$dbd/installed"
  printf "%s\n" "$spec" > "$dbd/spec"

  read_pkg_meta "$spec"
  printf "%s\n" "$PKG_NAME" > "$dbd/name"
  printf "%s\n" "$PKG_VERSION" > "$dbd/version"
  printf "%s\n" "$PKG_RELEASE" > "$dbd/release"
  printf "%s\n" "$PKG_DESC" > "$dbd/desc"
}

# Cria DB a partir do tar (para installs de cache binário)
record_install_db_from_tar() {
  local spec="$1" pkgfile="$2"
  local dbd
  dbd="$(pkg_db_dir "$spec")"
  run mkdir -p "$dbd"

  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} gravar DB (tar) em $dbd"
    return 0
  fi

  if [[ "$pkgfile" == *.tar.zst ]]; then
    zstd -dc "$pkgfile" | tar -tf - | sed 's|^\./||' | awk '{print "/"$0}' | sed 's|//$|/|' | sort > "$dbd/files"
  else
    tar -tf "$pkgfile" | sed 's|^\./||' | awk '{print "/"$0}' | sed 's|//$|/|' | sort > "$dbd/files"
  fi

  printf "%s\n" "$(ts)" > "$dbd/installed"
  printf "%s\n" "$spec" > "$dbd/spec"
  printf "%s\n" "installed-from-cache" > "$dbd/name"
  printf "%s\n" "unknown" > "$dbd/version"
  printf "%s\n" "unknown" > "$dbd/release"
  printf "%s\n" "Installed from binary cache (DB from tar listing)" > "$dbd/desc"
}

install_pkg_tarball_to_root() {
  local pkgfile="$1"
  info "Instalando pacote no sistema: $(basename "$pkgfile")"

  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} extrair $(printf "%q" "$pkgfile") em /"
    return 0
  fi

  if [[ "$pkgfile" == *.tar.zst ]]; then
    zstd -dc "$pkgfile" | tar -xpf - -C /
  else
    tar -xpf "$pkgfile" -C /
  fi
}

uninstall_spec() {
  local spec="$1"
  local dbd
  dbd="$(pkg_db_dir "$spec")"
  [[ -f "$dbd/files" ]] || die "Programa não instalado ou DB incompleto: $spec"

  local bs
  bs="$(pkg_build_script "$spec")"
  [[ -r "$bs" ]] || warn "build script não encontrado para hooks: $spec"

  # hooks rodam fora do chroot por padrão (ajuste se quiser)
  if [[ -r "$bs" ]]; then
    # shellcheck disable=SC1090
    source "$bs"
    if declare -F pre_uninstall >/dev/null 2>&1; then
      info "Hook pre_uninstall: $spec"
      [[ "$DRYRUN" -eq 1 ]] || pre_uninstall
    fi
  fi

  info "Removendo arquivos de $spec"
  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} remover arquivos listados em $dbd/files"
  else
    # remove arquivos e links primeiro
    grep -E '^/' "$dbd/files" | while read -r p; do
      [[ "$p" == "/" ]] && continue
      if [[ -L "$p" || -f "$p" ]]; then rm -f -- "$p" || true; fi
    done
    # remove dirs vazios em ordem mais profunda primeiro
    grep -E '^/' "$dbd/files" \
      | awk '{ print length($0), $0 }' | sort -nr | cut -d' ' -f2- \
      | while read -r p; do
          if [[ -d "$p" ]]; then rmdir --ignore-fail-on-non-empty "$p" 2>/dev/null || true; fi
        done
  fi

  if [[ -r "$bs" ]]; then
    if declare -F post_uninstall >/dev/null 2>&1; then
      info "Hook post_uninstall: $spec"
      [[ "$DRYRUN" -eq 1 ]] || post_uninstall
    fi
  fi

  run rm -rf "$dbd"
  ok "Uninstall concluído: $spec"
}

# Upgrade “real”: remove stale files com base no diff do DB antigo vs novo
upgrade_commit_with_stale_cleanup() {
  local spec="$1" new_pkgfile="$2" new_db_files="$3"

  local dbd oldfiles
  dbd="$(pkg_db_dir "$spec")"
  oldfiles="$dbd/files"

  if [[ ! -f "$oldfiles" ]]; then
    # sem DB antigo -> apenas instala
    install_pkg_tarball_to_root "$new_pkgfile"
    record_install_db_from_tar "$spec" "$new_pkgfile"
    return 0
  fi

  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} instalar novo e remover stale files de $spec"
    return 0
  fi

  # instalar novo
  install_pkg_tarball_to_root "$new_pkgfile"

  # remover arquivos que existiam antes e não existem mais
  # apenas arquivos/links; dirs serão limpos depois
  comm -23 <(sort "$oldfiles") <(sort "$new_db_files") | while read -r p; do
    [[ "$p" == "/" ]] && continue
    if [[ -f "$p" || -L "$p" ]]; then
      rm -f -- "$p" || true
    fi
  done

  # limpar dirs vazios (dos removidos)
  comm -23 <(sort "$oldfiles") <(sort "$new_db_files") \
    | awk '{ print length($0), $0 }' | sort -nr | cut -d' ' -f2- \
    | while read -r p; do
        if [[ -d "$p" ]]; then rmdir --ignore-fail-on-non-empty "$p" 2>/dev/null || true; fi
      done

  # atualizar DB
  cp -f "$new_db_files" "$oldfiles"
  printf "%s\n" "$(ts)" > "$dbd/installed"
}

# =========================
# BUILD (isolado com log sem vazamento)
# =========================
build_one() {
  local spec="$1"
  local skip_verify="$2"
  local skip_if_cached="$3"

  mkdirs
  read_pkg_meta "$spec"

  local logd workd pkgcache srcdir destdir
  logd="$(pkg_log_dir "$spec")"
  workd="$(pkg_work_dir "$spec")"
  pkgcache="$CACHEDL/${spec//\//__}"

  run mkdir -p "$logd" "$workd" "$pkgcache"

  local op_log="$logd/$(date +%Y%m%d-%H%M%S).log"
  info "Build: $spec ($PKG_VERSION-$PKG_RELEASE)"
  info "Log: $op_log"

  # encapsula logs em subshell (não vaza exec)
  (
    if [[ "$DRYRUN" -eq 0 ]]; then
      exec > >(tee -a "$op_log") 2>&1
    fi

    download_sources_parallel "$spec" "$skip_verify" "$skip_if_cached"

    srcdir="$workd/src"
    destdir="$workd/dest"
    run rm -rf "$srcdir" "$destdir"
    run mkdir -p "$srcdir" "$destdir"

    info "Extraindo sources (heurística)"
    extract_sources_heuristic "$pkgcache" "$srcdir"

    # tenta aplicar patches no primeiro diretório extraído
    local top
    top="$(find "$srcdir" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
    if [[ -n "${top:-}" ]]; then
      apply_patches "$spec" "$top"
    else
      warn "Nenhum diretório extraído automaticamente; patches podem ser aplicados pelo build()."
    fi

    chroot_setup
    chroot_toolchain_smoke

    # cria runner dentro do chroot (arquivo) para evitar interpolação quebrada
    local runner="$workd/runner.sh"
    if [[ "$DRYRUN" -eq 0 ]]; then
      cat > "$runner" <<'EOF'
#!/bin/sh
set -euo pipefail

# Variáveis vindas do ambiente:
# SPEC, MAKEFLAGS, DESTDIR, SRCROOT, PKGCACHE

bs="/adm/packages/${SPEC}/build"
. "$bs"

# Hooks
command -v pre_build >/dev/null 2>&1 && pre_build
build
command -v post_build >/dev/null 2>&1 && post_build

command -v pre_install >/dev/null 2>&1 && pre_install
install
command -v post_install >/dev/null 2>&1 && post_install
EOF
      chmod +x "$runner"
    fi

    # executa runner no chroot com env bem definido
    local ch_cmd
    ch_cmd=$(cat <<EOF
set -e
export SPEC="$(printf "%s" "$spec")"
export MAKEFLAGS="$(printf "%s" "${MAKEFLAGS:-}")"
export DESTDIR="/adm/work/${spec//\//__}/dest"
export SRCROOT="/adm/work/${spec//\//__}/src"
export PKGCACHE="/cache/sources/${spec//\//__}"
/adm/work/${spec//\//__}/runner.sh
EOF
)
    info "Executando build/install no chroot"
    chroot_exec "$ch_cmd"

    copy_files_overlay "$spec" "$destdir"

    local pkgfile
    pkgfile="$(make_pkg_tarball "$spec" "$destdir")"
    ok "Pacote gerado: $pkgfile"

    record_install_db_from_destdir "$spec" "$destdir"
    ok "Build concluído: $spec"
  )
}

# =========================
# INSTALAÇÃO / CACHE / UPGRADE
# =========================
find_latest_pkg_in_cache() {
  local spec="$1"
  local prefix="${spec//\//__}-"
  # lista por mtime; seguro com nullglob via array
  shopt -s nullglob
  local -a files=( "$CACHEPKG/${prefix}"*.tar.zst "$CACHEPKG/${prefix}"*.tar.xz )
  shopt -u nullglob
  if [[ "${#files[@]}" -eq 0 ]]; then
    printf "\n"
    return 0
  fi
  # ordena por mtime
  local latest=""
  local f
  local best_mtime=0
  for f in "${files[@]}"; do
    local mt
    mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    if (( mt > best_mtime )); then
      best_mtime=$mt
      latest="$f"
    fi
  done
  printf "%s\n" "$latest"
}

install_from_cache_or_build() {
  local spec="$1"

  if is_installed "$spec"; then
    ok "Já instalado: $spec"
    return 0
  fi

  local latest
  latest="$(find_latest_pkg_in_cache "$spec")"

  if [[ -n "$latest" ]]; then
    info "Instalando do cache: $(basename "$latest")"
    install_pkg_tarball_to_root "$latest"
    record_install_db_from_tar "$spec" "$latest"
    ok "Instalado do cache: $spec"
    return 0
  fi

  build_one "$spec" "$SKIP_VERIFY" "$SKIP_IF_CACHED"

  # instala o pacote recém-gerado (base atual)
  local base
  base="$(pkg_pkgfile_base "$spec")"
  local zst="$CACHEPKG/${base}.tar.zst"
  local xz="$CACHEPKG/${base}.tar.xz"

  if [[ -f "$zst" ]]; then
    install_pkg_tarball_to_root "$zst"
    record_install_db_from_tar "$spec" "$zst"
  elif [[ -f "$xz" ]]; then
    install_pkg_tarball_to_root "$xz"
    record_install_db_from_tar "$spec" "$xz"
  else
    die "Pacote não encontrado após build: $spec"
  fi

  ok "Instalado (build local): $spec"
}

install_spec() {
  local spec="$1"
  valid_spec "$spec" || die "Spec inválido: $spec"

  local -a order
  mapfile -t order < <(resolve_deps_order "$spec")

  info "Ordem de instalação (deps resolvidas):"
  printf "  - %s\n" "${order[@]}"

  local s
  for s in "${order[@]}"; do
    install_from_cache_or_build "$s"
  done

  ok "Instalação concluída: $spec"
}

upgrade_spec() {
  local spec="$1"
  valid_spec "$spec" || die "Spec inválido: $spec"

  if ! is_installed "$spec"; then
    info "Não instalado; executando install: $spec"
    install_spec "$spec"
    return 0
  fi

  info "Upgrade: $spec (com remoção de stale files)"
  build_one "$spec" "$SKIP_VERIFY" "$SKIP_IF_CACHED"

  # localizar novo pacote gerado
  local base
  base="$(pkg_pkgfile_base "$spec")"
  local zst="$CACHEPKG/${base}.tar.zst"
  local xz="$CACHEPKG/${base}.tar.xz"
  local pkgfile=""
  if [[ -f "$zst" ]]; then pkgfile="$zst"; elif [[ -f "$xz" ]]; then pkgfile="$xz"; else die "Pacote novo não encontrado: $spec"; fi

  # gerar lista files do novo pacote para diff stale
  local newlist
  newlist="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$newlist'" RETURN

  if [[ "$DRYRUN" -eq 0 ]]; then
    if [[ "$pkgfile" == *.tar.zst ]]; then
      zstd -dc "$pkgfile" | tar -tf - | sed 's|^\./||' | awk '{print "/"$0}' | sed 's|//$|/|' | sort > "$newlist"
    else
      tar -tf "$pkgfile" | sed 's|^\./||' | awk '{print "/"$0}' | sed 's|//$|/|' | sort > "$newlist"
    fi
  fi

  upgrade_commit_with_stale_cleanup "$spec" "$pkgfile" "$newlist"
  ok "Upgrade concluído: $spec"
}

# =========================
# SEARCH / INFO
# =========================
list_all_specs() {
  # encontra diretórios que contenham arquivo "build" no layout novo
  find "$PKGROOT" -mindepth 2 -maxdepth 2 -type f -name build 2>/dev/null \
    | awk -v root="$PKGROOT/" '{sub(root,"",$0); sub("/build$","",$0); print $0}' \
    | sort
}

cmd_search() {
  local q="${1:-}"
  [[ -n "$q" ]] || die "Uso: adm search <termo>"
  info "Procurando: $q"
  list_all_specs | grep -i -- "$q" | while read -r spec; do
    printf "%-6s %s\n" "$(installed_mark "$spec")" "$spec"
  done
}

cmd_info() {
  local spec="${1:-}"
  valid_spec "$spec" || die "Uso: adm info <categoria/programa>"
  local bs
  bs="$(pkg_build_script "$spec")"
  [[ -r "$bs" ]] || die "Pacote não encontrado: $spec"

  read_pkg_meta "$spec"

  say "${C_BOLD}${spec}${C_RESET} $(installed_mark "$spec")"
  say "  Nome     : $PKG_NAME"
  say "  Versão   : $PKG_VERSION"
  say "  Release  : $PKG_RELEASE"
  say "  Desc     : $PKG_DESC"
  say "  URL      : $PKG_URL"
  say "  Licença  : $PKG_LICENSE"
  say "  Deps     : ${PKG_DEPS[*]:-}"
  say "  BuildDeps: ${PKG_BUILD_DEPS[*]:-}"
  say "  Sources  :"
  local u
  for u in "${PKG_SOURCES[@]}"; do
    say "    - $u"
  done
}

# =========================
# SYNC GIT
# =========================
cmd_sync() {
  need_root
  [[ -n "$GIT_REMOTE" ]] || die "Defina GIT_REMOTE (env ou topo do script)."
  have_cmd git || die "git não encontrado."

  mkdirs

  # proteção contra rm -rf perigoso
  [[ "$PKGROOT" == "$ADM_ROOT/packages" ]] || die "PKGROOT inesperado; abortando por segurança."

  if [[ -d "$PKGROOT/.git" ]]; then
    info "Atualizando repo em $PKGROOT"
    run git -C "$PKGROOT" fetch --all --prune
    run git -C "$PKGROOT" checkout "$GIT_BRANCH"
    run git -C "$PKGROOT" pull --ff-only origin "$GIT_BRANCH"
  else
    info "Clonando repo em $PKGROOT"
    run rm -rf "$PKGROOT"
    run git clone --branch "$GIT_BRANCH" "$GIT_REMOTE" "$PKGROOT"
  fi
  ok "Sync concluído."
}

# =========================
# UPDATE (UPSTREAM)
# =========================
ver_gt() {
  local a="$1" b="$2"
  [[ "$(printf "%s\n%s\n" "$a" "$b" | sort -V | tail -n1)" == "$a" && "$a" != "$b" ]]
}

cmd_update() {
  mkdirs
  local out="$ADM_ROOT/packages/updates"
  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} gerar $out"
    return 0
  fi

  : > "$out"
  local count=0

  local spec
  while read -r spec; do
    local bs
    bs="$(pkg_build_script "$spec")"
    [[ -r "$bs" ]] || continue

    # executa upstream_check em subshell controlado
    local line
    line="$(bash -c "
      set -euo pipefail
      source '$bs'
      if declare -F upstream_check >/dev/null 2>&1; then
        upstream_check || true
      fi
    " 2>/dev/null || true)"

    [[ -z "$line" ]] && continue

    local newver newurl
    newver="$(awk '{print $1}' <<<"$line")"
    newurl="$(awk '{print $2}' <<<"$line")"
    [[ -z "$newver" || -z "$newurl" ]] && continue

    read_pkg_meta "$spec"
    if ver_gt "$newver" "$PKG_VERSION"; then
      printf "%s %s %s\n" "$spec" "$newver" "$newurl" >> "$out"
      count=$((count+1))
    fi
  done < <(list_all_specs)

  ok "Updates gerado: $out (total: $count)"
  if have_cmd "$NOTIFY_BIN" && [[ "$count" -gt 0 ]]; then
    run "$NOTIFY_BIN" "ADM Updates" "$count atualizações disponíveis (ver: $out)"
  fi
}

# =========================
# REBUILD-ALL / CLEAN
# =========================
cmd_rebuild_all() {
  need_root
  mkdirs
  info "Rebuild-all: respeitando dependências"

  # specs instalados via DB dirs
  local -a installed=()
  local d
  while IFS= read -r d; do
    local s
    s="$(basename "$d")"
    s="${s//__/\/}"
    installed+=( "$s" )
  done < <(find "$DBROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  local -A seen=()
  local -a final=()

  local spec
  for spec in "${installed[@]}"; do
    valid_spec "$spec" || continue
    local -a order
    mapfile -t order < <(resolve_deps_order "$spec")
    local s
    for s in "${order[@]}"; do
      if [[ -z "${seen[$s]:-}" ]]; then
        seen["$s"]=1
        final+=( "$s" )
      fi
    done
  done

  info "Ordem final (rebuild-all):"
  printf "  - %s\n" "${final[@]}"

  local s
  for s in "${final[@]}"; do
    info "Rebuild/Upgrade: $s"
    upgrade_spec "$s"
  done

  ok "Rebuild-all concluído."
}

cmd_clean() {
  need_root
  mkdirs
  info "Limpeza inteligente"
  run rm -rf "$WORKROOT" || true
  run mkdir -p "$WORKROOT"

  # logs > 30d
  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} limpar logs antigos"
  else
    find "$LOGROOT" -type f -name '*.log' -mtime +30 -delete 2>/dev/null || true
    find "$CACHEDL" -type f -mtime +90 -delete 2>/dev/null || true
    find "$CACHEPKG" -type f -mtime +180 -delete 2>/dev/null || true
  fi

  chroot_teardown || true
  ok "Clean concluído."
}

# =========================
# HELP
# =========================
usage() {
  cat <<EOF
${C_BOLD}ADM${C_RESET} - Rolling Release Source Manager (Shell)

${C_BOLD}Uso:${C_RESET}
  adm [opções] <comando> [args]

${C_BOLD}Opções globais:${C_RESET}
  --dry-run           Não executa (mostra o que faria)
  --quiet             Reduz saída
  --no-color          Desliga cores
  --skip-verify       Não confere checksums
  --skip-if-cached    Se já baixado e válido, não baixa de novo

${C_BOLD}Comandos:${C_RESET}
  search <termo>                 Procura pacotes (marca < ✔️ > se instalado)
  info <categoria/programa>      Informações completas (marca < ✔️ > se instalado)

  chroot-setup                   Prepara chroot de build (mounts e binds)
  chroot-teardown                Desmonta tudo do chroot

  build <categoria/programa>     Baixa/verifica, aplica patch, build em chroot, gera pacote
  install <categoria/programa>   Resolve deps, instala (cache binário ou build)
  upgrade <categoria/programa>   Upgrade com remoção de stale files
  uninstall <categoria/programa> Remove arquivos via DB (hooks)

  rebuild-all                    Recompila/reinstala tudo instalado (deps ordenadas)
  clean                          Limpeza inteligente (work, logs antigos, caches antigos)
  sync                           Git sync do repositório (GIT_REMOTE, GIT_BRANCH)
  update                         Checa upstream e gera ${ADM_ROOT}/packages/updates + notify-send

${C_BOLD}Exemplos:${C_RESET}
  adm search musl
  adm info base/busybox
  adm --skip-if-cached install base/busybox
  adm --dry-run upgrade base/zlib
  adm rebuild-all
EOF
}

# =========================
# PARSE DE ARGUMENTOS (sem perder quoting)
# =========================
parse_opts() {
  # consome opções globais e deixa resto em ARGS (array)
  local -a args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRYRUN=1; shift ;;
      --quiet) QUIET=1; shift ;;
      --no-color) USE_COLOR=0; shift ;;
      --skip-verify) SKIP_VERIFY=1; shift ;;
      --skip-if-cached) SKIP_IF_CACHED=1; shift ;;
      --) shift; break ;;
      --*) die "Opção inválida: $1" ;;
      *) break ;;
    esac
  done
  args=( "$@" )
  printf "%s\0" "${args[@]}"
}

main() {
  setup_colors
  mkdirs

  # parse retorna NUL-separated; reconstruímos array
  local parsed
  parsed="$(parse_opts "$@")"
  local -a argv=()
  if [[ -n "$parsed" ]]; then
    while IFS= read -r -d '' item; do
      argv+=( "$item" )
    done <<<"$parsed"
  fi

  # atualizar cores se --no-color
  setup_colors

  local cmd="${argv[0]:-}"
  local arg1="${argv[1]:-}"

  case "$cmd" in
    ""|help|-h|--help) usage ;;
    search) cmd_search "${arg1:-}" ;;
    info) cmd_info "${arg1:-}" ;;

    chroot-setup) with_lock chroot_setup ;;
    chroot-teardown) with_lock chroot_teardown ;;

    build)
      [[ -n "${arg1:-}" ]] || die "Uso: adm build <categoria/programa>"
      with_lock build_one "$arg1" "$SKIP_VERIFY" "$SKIP_IF_CACHED"
      ;;
    install)
      [[ -n "${arg1:-}" ]] || die "Uso: adm install <categoria/programa>"
      with_lock install_spec "$arg1"
      ;;
    upgrade)
      [[ -n "${arg1:-}" ]] || die "Uso: adm upgrade <categoria/programa>"
      with_lock upgrade_spec "$arg1"
      ;;
    uninstall)
      [[ -n "${arg1:-}" ]] || die "Uso: adm uninstall <categoria/programa>"
      with_lock uninstall_spec "$arg1"
      ;;
    rebuild-all) with_lock cmd_rebuild_all ;;
    clean) with_lock cmd_clean ;;
    sync) with_lock cmd_sync ;;
    update) with_lock cmd_update ;;
    *)
      die "Comando inválido: $cmd (use: adm help)"
      ;;
  esac
}

main "$@"
