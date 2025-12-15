#!/usr/bin/env bash
# adm - package manager for LFS-style systems using external build scripts
# Build scripts path: /usr/src/adm/packages/<categoria>/<programa>-<versao>.sh

set -Eeuo pipefail
shopt -s nullglob

###############################################################################
# Configuração
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
PKG_SCRIPTS_DIR="${PKG_SCRIPTS_DIR:-$ADM_ROOT/packages}"

STATE_DIR="${STATE_DIR:-/var/lib/admpkg}"
CACHE_DIR="${CACHE_DIR:-/var/cache/admpkg}"
LOG_DIR="${LOG_DIR:-/var/log/admpkg}"

SRC_CACHE="$CACHE_DIR/sources"
BIN_CACHE="$CACHE_DIR/binaries"
SUM_CACHE="$CACHE_DIR/checksums"
TMP_DIR="$CACHE_DIR/tmp"

INST_DB="$STATE_DIR/installed"
BUILD_DB="$STATE_DIR/builds"
REV_DB="$STATE_DIR/revdeps"

HOOKS_DIR="${HOOKS_DIR:-$ADM_ROOT/hooks}" # opcional
SYNC_REPO_URL="${SYNC_REPO_URL:-}"        # ex: git@seu_repo:adm-packages.git
SYNC_BRANCH="${SYNC_BRANCH:-main}"

LOCK_FILE="${LOCK_FILE:-/var/lock/admpkg.lock}"

REQUIRED_TOOLS=(bash tar zstd sha256sum md5sum find sed awk grep sort uniq xargs date mkdir rm cp ln readlink tac)
OPTIONAL_TOOLS=(curl wget git patch flock shellcheck)

###############################################################################
# Flags globais
###############################################################################
DRY_RUN=0
YES=0

# flags por comando
DOCTOR_FIX=0
REMOVE_PRUNE_DIRS=0
REMOVE_DEEP=0
UPGRADE_ALL=0
UPGRADE_KEEP_OLD=0
LINT_ALL=0

###############################################################################
# UI: cores e logs
###############################################################################
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'
  C_BOLD=$'\e[1m'
  C_DIM=$'\e[2m'
  C_RED=$'\e[31m'
  C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'
  C_MAG=$'\e[35m'
  C_CYAN=$'\e[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAG=""; C_CYAN=""
fi

ts() { date '+%Y-%m-%d %H:%M:%S'; }

mkdir -p "$STATE_DIR" "$CACHE_DIR" "$LOG_DIR" "$SRC_CACHE" "$BIN_CACHE" "$SUM_CACHE" "$TMP_DIR" "$INST_DB" "$BUILD_DB" "$REV_DB"

LOG_FILE="$LOG_DIR/admpkg-$(date '+%Y%m%d').log"
log() { printf '%s %s\n' "$(ts)" "$*" >>"$LOG_FILE"; }
info() { printf '%b\n' "${C_CYAN}${C_BOLD}==>${C_RESET} $*"; log "INFO: $*"; }
warn() { printf '%b\n' "${C_YELLOW}${C_BOLD}WARN:${C_RESET} $*"; log "WARN: $*"; }
err()  { printf '%b\n' "${C_RED}${C_BOLD}ERRO:${C_RESET} $*"; log "ERRO: $*"; }
die()  { err "$*"; exit 1; }

###############################################################################
# Execução / dry-run
###############################################################################
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%b\n' "${C_DIM}[dry-run]${C_RESET} $*"
    log "DRYRUN: $*"
    return 0
  fi
  log "RUN: $*"
  "$@"
}

need_confirm() {
  local msg="$1"
  [[ "$YES" -eq 1 ]] && return 0
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  printf '%b' "${C_YELLOW}${msg}${C_RESET} [y/N]: "
  read -r ans || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

###############################################################################
# Utilitários
###############################################################################
have() { command -v "$1" >/dev/null 2>&1; }

check_tools() {
  for t in "${REQUIRED_TOOLS[@]}"; do
    have "$t" || die "Ferramenta obrigatória ausente: $t"
  done
  if ! have flock; then
    warn "flock ausente: concorrência não será bloqueada (recomendado util-linux)."
  fi
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Execute como root (necessário para instalar/remover)."
  fi
}

sanitize() { echo "$1" | tr -cd 'A-Za-z0-9._+-'; }

pkg_id() {
  local name="$1" ver="$2"
  echo "$(sanitize "$name")-$(sanitize "$ver")"
}

installed_manifest_dir() {
  local name="$1" ver="$2"
  echo "$INST_DB/$(pkg_id "$name" "$ver")"
}

is_installed() {
  local name="$1" ver="$2"
  [[ -d "$(installed_manifest_dir "$name" "$ver")" ]]
}

###############################################################################
# Lock global
###############################################################################
lock_global() {
  if have flock; then
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Outro processo do adm está em execução (lock: $LOCK_FILE)."
  fi
}

###############################################################################
# Descoberta de scripts
###############################################################################
find_build_script() {
  local category="$1" name="$2" ver="$3"
  local script="$PKG_SCRIPTS_DIR/$category/${name}-${ver}.sh"
  [[ -f "$script" ]] || return 1
  echo "$script"
}

list_all_build_scripts() {
  find "$PKG_SCRIPTS_DIR" -type f -name '*.sh' 2>/dev/null | sort
}

find_any_category_script() {
  local name="$1" ver="$2"
  local f
  f="$(find "$PKG_SCRIPTS_DIR" -type f -name "${name}-${ver}.sh" 2>/dev/null | head -n1 || true)"
  [[ -n "$f" ]] || return 1
  echo "$f"
}

category_from_script() {
  local path="$1"
  basename "$(dirname "$path")"
}

###############################################################################
# Parsing de dependências
# Aceita: nome-versao (legado), nome@versao, nome>=versao, nome<=versao, nome=versao
###############################################################################
parse_dep() {
  local s="$1"
  local name op ver
  if [[ "$s" == *">="* ]]; then
    name="${s%%>=*}"; op=">="; ver="${s#*>=}"
  elif [[ "$s" == *"<="* ]]; then
    name="${s%%<=*}"; op="<="; ver="${s#*<=}"
  elif [[ "$s" == *"="* ]]; then
    name="${s%%=*}"; op="="; ver="${s#*=}"
  elif [[ "$s" == *"@"* ]]; then
    name="${s%%@*}"; op="="; ver="${s#*@}"
  else
    if [[ "$s" == *"-"* ]]; then
      local suf="${s##*-}"
      if [[ "$suf" =~ ^[0-9] ]]; then
        name="${s%-*}"; op="="; ver="$suf"
      else
        name="$s"; op=""; ver=""
      fi
    else
      name="$s"; op=""; ver=""
    fi
  fi
  name="$(sanitize "$name")"
  ver="$(sanitize "$ver")"
  echo "${name}|${op}|${ver}"
}

# Compat: scripts antigos usam dep_name/dep_ver
dep_name() { IFS='|' read -r n _ _ <<<"$(parse_dep "$1")"; echo "$n"; }
dep_ver()  { IFS='|' read -r _ _ v <<<"$(parse_dep "$1")"; echo "$v"; }

###############################################################################
# Metadata sandbox (evita source no processo principal para leitura de metadata)
###############################################################################
meta_dump_sandbox() {
  local script="$1"
  [[ -f "$script" ]] || die "meta: script não encontrado: $script"
  bash -n "$script" || die "meta: erro de sintaxe em: $script"

  bash -c "
    set -Eeuo pipefail
    shopt -s nullglob
    source '$script'

    : \"\${PKG_NAME:=}\"
    : \"\${PKG_VERSION:=}\"
    : \"\${PKG_CATEGORY:=}\"

    declare -p PKG_NAME PKG_VERSION PKG_CATEGORY 2>/dev/null || true
    declare -p PKG_DEPENDS 2>/dev/null || echo 'declare -a PKG_DEPENDS=()'
    declare -p PKG_SOURCES 2>/dev/null || echo 'declare -a PKG_SOURCES=()'
    declare -p PKG_PATCHES 2>/dev/null || echo 'declare -a PKG_PATCHES=()'

    if declare -F build >/dev/null 2>&1; then echo '__HAS_BUILD=1'; else echo '__HAS_BUILD=0'; fi
    if declare -F install >/dev/null 2>&1; then echo '__HAS_INSTALL=1'; else echo '__HAS_INSTALL=0'; fi
  "
}

meta_load_from_script() {
  local script="$1"
  local dump
  dump="$(meta_dump_sandbox "$script")" || die "meta: falha ao extrair metadata: $script"

  local __HAS_BUILD=0 __HAS_INSTALL=0
  local PKG_NAME="" PKG_VERSION="" PKG_CATEGORY=""
  local -a PKG_DEPENDS=() PKG_SOURCES=() PKG_PATCHES=()

  # shellcheck disable=SC1090
  eval "$dump"

  META_PKG_NAME="$PKG_NAME"
  META_PKG_VERSION="$PKG_VERSION"
  META_PKG_CATEGORY="$PKG_CATEGORY"
  META_HAS_BUILD="$__HAS_BUILD"
  META_HAS_INSTALL="$__HAS_INSTALL"
  META_PKG_DEPENDS=("${PKG_DEPENDS[@]}")
  META_PKG_SOURCES=("${PKG_SOURCES[@]}")
  META_PKG_PATCHES=("${PKG_PATCHES[@]}")
}

meta_require_build_contract() {
  local script="$1"
  [[ "${#META_PKG_SOURCES[@]}" -gt 0 ]] || die "meta: PKG_SOURCES vazio/ausente em $script"
  [[ "$META_HAS_BUILD" == "1" ]] || die "meta: build() ausente em $script"
  [[ "$META_HAS_INSTALL" == "1" ]] || die "meta: install() ausente em $script"
}

###############################################################################
# Resolução de dependências com detecção de ciclo (DFS)
###############################################################################
declare -A DEP_VISIT=()
declare -a DEP_ORDER=()

resolve_deps_dfs() {
  local category="$1" pkg="$2" ver="$3"
  local key; key="$(pkg_id "$pkg" "$ver")"

  local st="${DEP_VISIT[$key]:-0}"
  if [[ "$st" -eq 1 ]]; then
    die "Ciclo de dependências detectado envolvendo: $key"
  elif [[ "$st" -eq 2 ]]; then
    return 0
  fi
  DEP_VISIT["$key"]=1

  local script; script="$(find_build_script "$category" "$pkg" "$ver")" || die "Script não encontrado: $category/$pkg-$ver"
  meta_load_from_script "$script"
  local deps=("${META_PKG_DEPENDS[@]:-}")

  local d
  for d in "${deps[@]:-}"; do
    local dn dop dv
    IFS='|' read -r dn dop dv <<<"$(parse_dep "$d")"
    [[ -n "$dn" ]] || die "Dependência inválida ($script): $d"
    [[ -n "$dv" ]] || die "Dependência sem versão não suportada: $d (em $script)"

    local dep_script; dep_script="$(find_any_category_script "$dn" "$dv")" || die "Dependência não encontrada nos scripts: $dn-$dv"
    local dep_cat; dep_cat="$(category_from_script "$dep_script")"
    resolve_deps_dfs "$dep_cat" "$dn" "$dv"
  done

  DEP_VISIT["$key"]=2
  DEP_ORDER+=("$category|$pkg|$ver")
}

###############################################################################
# Reverse-deps DB
###############################################################################
revdeps_path() { echo "$REV_DB/$1.rdeps"; }

revdeps_add() {
  local dep_id="$1" dependent_id="$2"
  local f; f="$(revdeps_path "$dep_id")"
  run mkdir -p "$REV_DB"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "revdeps: adicionaria $dependent_id -> $dep_id"
    return 0
  fi
  touch "$f"
  grep -qxF "$dependent_id" "$f" 2>/dev/null || echo "$dependent_id" >>"$f"
}

revdeps_remove() {
  local dep_id="$1" dependent_id="$2"
  local f; f="$(revdeps_path "$dep_id")"
  [[ -f "$f" ]] || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "revdeps: removeria $dependent_id -> $dep_id"
    return 0
  fi
  grep -vxF "$dependent_id" "$f" >"$f.tmp" || true
  mv "$f.tmp" "$f"
  [[ -s "$f" ]] || rm -f "$f"
}

revdeps_list() {
  local dep_id="$1"
  local f; f="$(revdeps_path "$dep_id")"
  [[ -f "$f" ]] || return 0
  cat "$f"
}

revdeps_register_install() {
  local pkg="$1"; shift || true
  local dep
  for dep in "$@"; do
    [[ -n "$dep" ]] || continue
    revdeps_add "$dep" "$pkg"
  done
}

revdeps_unregister_remove() {
  local pkg="$1"; shift || true
  local dep
  for dep in "$@"; do
    [[ -n "$dep" ]] || continue
    revdeps_remove "$dep" "$pkg"
  done
}

revdeps_from_manifest() {
  local pkg_id="$1"
  local mf="$INST_DB/$pkg_id/manifest.info"
  [[ -f "$mf" ]] || return 0
  local deps
  deps="$(grep -E '^deps=' "$mf" | cut -d= -f2- || true)"
  for d in $deps; do echo "$d"; done
}

revdeps_rebuild_index() {
  info "revdeps: reconstruindo índice a partir de $INST_DB"
  run mkdir -p "$REV_DB"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "DRY-RUN: limparia e reconstruiria $REV_DB"
    return 0
  fi
  rm -f "$REV_DB"/*.rdeps 2>/dev/null || true

  local d
  for d in "$INST_DB"/*; do
    [[ -d "$d" ]] || continue
    local pkg; pkg="$(basename "$d")"
    local dep
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      revdeps_add "$dep" "$pkg"
    done < <(revdeps_from_manifest "$pkg")
  done
  info "revdeps: reconstrução concluída."
}

###############################################################################
# Download + checksums
###############################################################################
cache_key_for_url() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

filename_from_url() {
  local url="$1"
  local base="${url##*/}"
  base="${base%%\?*}"
  [[ -n "$base" && "$base" != "$url" ]] || base="source"
  echo "$(sanitize "$base")"
}

download_one() {
  local url="$1" out="$2"
  run mkdir -p "$(dirname "$out")"
  [[ -e "$out" ]] && return 0

  if [[ "$url" =~ ^git\+ ]]; then
    have git || die "git ausente para baixar: $url"
    local real="${url#git+}"
    run rm -rf "$out.tmp"
    run git clone --depth 1 "$real" "$out.tmp"
    run mv "$out.tmp" "$out"
    return 0
  fi
  if [[ "$url" =~ \.git$ ]] || [[ "$url" =~ ^git:// ]]; then
    have git || die "git ausente para baixar: $url"
    run rm -rf "$out.tmp"
    run git clone --depth 1 "$url" "$out.tmp"
    run mv "$out.tmp" "$out"
    return 0
  fi

  if have curl; then
    info "Baixando: $url"
    run curl -L --fail --retry 3 --retry-delay 1 --progress-bar -o "$out.tmp" "$url"
    run mv "$out.tmp" "$out"
  elif have wget; then
    info "Baixando: $url"
    run wget --tries=3 --progress=bar:force:noscroll -O "$out.tmp" "$url"
    run mv "$out.tmp" "$out"
  else
    die "Sem curl/wget para baixar: $url"
  fi
}

verify_checksum() {
  local file="$1" algo="$2" expected="$3"
  run mkdir -p "$SUM_CACHE/$algo"
  local got=""
  case "$algo" in
    sha256) got="$(sha256sum "$file" | awk '{print $1}')" ;;
    md5) got="$(md5sum "$file" | awk '{print $1}')" ;;
    *) die "Algoritmo inválido: $algo (use sha256 ou md5)" ;;
  esac
  [[ "$got" == "$expected" ]] || die "Checksum inválido para $(basename "$file"): esperado=$expected obtido=$got"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '%s  %s\n' "$got" "$file" >"$SUM_CACHE/$algo/$expected"
  fi
}

###############################################################################
# Hooks
###############################################################################
run_hook_external() {
  local hook="$1"
  local hook_path="$HOOKS_DIR/$hook"
  if [[ -x "$hook_path" ]]; then
    info "Hook externo: $hook"
    run "$hook_path" || die "Hook externo falhou: $hook"
  fi
}

run_hook_function() {
  local hook="$1"
  if declare -F "$hook" >/dev/null 2>&1; then
    info "Hook do pacote: $hook()"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "Chamaria hook (dry-run): $hook()"
    else
      "$hook" || die "Hook do pacote falhou: $hook"
    fi
  fi
}

###############################################################################
# Patches
###############################################################################
apply_patches() {
  local work="$1"
  ((${#PKG_PATCHES[@]:-0})) || return 0
  have patch || die "patch ausente para aplicar PKG_PATCHES"
  run mkdir -p "$work/patches"

  local p
  for p in "${PKG_PATCHES[@]}"; do
    local purl palgo phex pstrip pcwd
    IFS='|' read -r purl palgo phex pstrip pcwd <<<"$p"
    [[ -n "${purl:-}" && -n "${palgo:-}" && -n "${phex:-}" ]] || die "Entrada inválida em PKG_PATCHES: $p"
    pstrip="${pstrip:-1}"
    pcwd="${pcwd:-.}"

    local pkey; pkey="$(cache_key_for_url "$purl")"
    local pf; pf="$(filename_from_url "$purl")"
    local ptarget="$SRC_CACHE/${pkey}-${pf}"

    download_one "$purl" "$ptarget"
    verify_checksum "$ptarget" "$palgo" "$phex"
    run cp -f "$ptarget" "$work/patches/$pf"

    info "Aplicando patch: $pf (strip=$pstrip cwd=$pcwd)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "patch -p${pstrip} < $work/patches/$pf (dry-run)"
    else
      ( cd "$work/$pcwd" && patch -p"$pstrip" <"$work/patches/$pf" ) || die "Falha ao aplicar patch: $pf"
    fi
  done
}

###############################################################################
# Tar safety
###############################################################################
normalize_tar_list() { sed -e 's#^\./##' -e '/^$/d'; }

validate_tar_list() {
  local list_file="$1"
  local bad=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ "$f" == /* ]] || [[ "$f" == *".."* ]] || [[ "$f" =~ [[:cntrl:]] ]]; then
      warn "Entrada perigosa no tar: [$f]"
      bad=1
    fi
  done <"$list_file"
  [[ "$bad" -eq 0 ]] || die "Pacote contém caminhos perigosos; instalação bloqueada."
}

###############################################################################
# Build pipeline
###############################################################################
build_pkg() {
  local category="$1" name="$2" ver="$3"
  local script; script="$(find_build_script "$category" "$name" "$ver")" || die "Script não encontrado: $category/$name-$ver"

  local id; id="$(pkg_id "$name" "$ver")"
  local work="$TMP_DIR/work-$id"
  local stage="$TMP_DIR/stage-$id"
  local meta="$BUILD_DB/$id"

  run rm -rf "$work" "$stage"
  run mkdir -p "$work" "$stage" "$meta"

  # build precisa source para obter build()/install()
  # shellcheck disable=SC1090
  source "$script"

  : "${PKG_NAME:=$name}"
  : "${PKG_VERSION:=$ver}"
  : "${PKG_SOURCES:?PKG_SOURCES não definido em $script}"
  declare -F build >/dev/null 2>&1 || die "Função build() ausente em $script"
  declare -F install >/dev/null 2>&1 || die "Função install() ausente em $script"

  export ADM_WORKDIR="$work"
  export ADM_STAGEDIR="$stage"
  export DESTDIR="$stage"

  run_hook_external "pre_fetch"
  run_hook_function "pre_fetch"

  run mkdir -p "$work/sources"
  local src_entry
  for src_entry in "${PKG_SOURCES[@]}"; do
    local url algo hex
    IFS='|' read -r url algo hex <<<"$src_entry"
    [[ -n "${url:-}" && -n "${algo:-}" && -n "${hex:-}" ]] || die "Entrada inválida em PKG_SOURCES: $src_entry"

    local key; key="$(cache_key_for_url "$url")"
    local fname; fname="$(filename_from_url "$url")"
    local target="$SRC_CACHE/${key}-${fname}"

    download_one "$url" "$target"
    verify_checksum "$target" "$algo" "$hex"
    run ln -sf "$target" "$work/sources/$fname"
  done

  run_hook_external "post_fetch"
  run_hook_function "post_fetch"

  apply_patches "$work"

  run_hook_external "pre_build"
  run_hook_function "pre_build"

  info "Construindo: $PKG_NAME-$PKG_VERSION ($category)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Executaria build() (dry-run)"
  else
    ( cd "$work" && build )
  fi

  run_hook_external "post_build"
  run_hook_function "post_build"

  run_hook_external "pre_install"
  run_hook_function "pre_install"

  info "Instalando em staging: $stage"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Executaria install() com DESTDIR=$stage (dry-run)"
  else
    ( cd "$work" && install )
  fi

  run_hook_external "post_install"
  run_hook_function "post_install"

  local pkgfile="$BIN_CACHE/${id}.tar.zst"
  info "Empacotando: $(basename "$pkgfile")"
  run rm -f "$pkgfile"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Criaria pacote tar.zst (dry-run): $pkgfile"
  else
    ( cd "$stage" && tar --numeric-owner --xattrs --acls -cf - . ) \
      | zstd -T0 -19 --long=31 -o "$pkgfile"
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    {
      echo "name=$PKG_NAME"
      echo "version=$PKG_VERSION"
      echo "category=$category"
      echo "built_at=$(ts)"
      echo "pkgfile=$pkgfile"
      echo "script=$script"
    } >"$meta/build.info"
  fi

  info "Build concluído: $id"
}

###############################################################################
# Install do cache (metadata sandbox + tar safety + revdeps)
###############################################################################
install_pkg_from_cache() {
  need_root
  local category="$1" name="$2" ver="$3"
  local id; id="$(pkg_id "$name" "$ver")"
  local pkgfile="$BIN_CACHE/${id}.tar.zst"
  [[ -f "$pkgfile" ]] || die "Binário não encontrado em cache: $pkgfile (faça build primeiro)"

  if is_installed "$name" "$ver"; then
    warn "Já instalado: $id"
    return 0
  fi

  local script; script="$(find_build_script "$category" "$name" "$ver")" || die "Script não encontrado: $category/$name-$ver"
  meta_load_from_script "$script"

  local -a dep_ids=()
  local d
  for d in "${META_PKG_DEPENDS[@]:-}"; do
    local dn dop dv
    IFS='|' read -r dn dop dv <<<"$(parse_dep "$d")"
    [[ -n "$dn" ]] || die "Dependência inválida ($script): $d"
    [[ -n "$dv" ]] || die "Dependência sem versão não suportada no install: $d (em $script)"
    dep_ids+=("$(pkg_id "$dn" "$dv")")
  done

  # instalar deps antes
  for d in "${META_PKG_DEPENDS[@]:-}"; do
    local dn dop dv
    IFS='|' read -r dn dop dv <<<"$(parse_dep "$d")"
    local dep_script; dep_script="$(find_any_category_script "$dn" "$dv")" || die "Dependência sem script: $dn-$dv"
    local dep_cat; dep_cat="$(category_from_script "$dep_script")"

    if ! is_installed "$dn" "$dv"; then
      local dep_id; dep_id="$(pkg_id "$dn" "$dv")"
      if [[ -f "$BIN_CACHE/${dep_id}.tar.zst" ]]; then
        install_pkg_from_cache "$dep_cat" "$dn" "$dv"
      else
        build_pkg "$dep_cat" "$dn" "$dv"
        install_pkg_from_cache "$dep_cat" "$dn" "$dv"
      fi
    fi
  done

  info "Instalando do cache: $id"

  local mdir="$INST_DB/$id"
  run mkdir -p "$mdir"
  local files_list="$mdir/files.txt"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "DRY-RUN: validaria/extrairia $pkgfile em / e registraria manifest + revdeps"
    return 0
  fi

  zstd -dc "$pkgfile" | tar -tf - | normalize_tar_list >"$files_list"
  validate_tar_list "$files_list"
  zstd -dc "$pkgfile" | tar --xattrs --acls -xpf - -C /

  {
    echo "name=$name"
    echo "version=$ver"
    echo "category=$category"
    echo "installed_at=$(ts)"
    echo "pkgfile=$pkgfile"
    echo "deps=${dep_ids[*]:-}"
    echo "script=$script"
  } >"$mdir/manifest.info"

  if ((${#dep_ids[@]})); then
    revdeps_register_install "$id" "${dep_ids[@]}"
  fi

  info "Instalado: $id"
}

###############################################################################
# Remove + remove --deep
###############################################################################
remove_pkg() {
  need_root
  local name="$1" ver="$2"
  local id; id="$(pkg_id "$name" "$ver")"
  local mdir="$INST_DB/$id"
  [[ -d "$mdir" ]] || die "Não instalado: $id"

  local dependents
  dependents="$(revdeps_list "$id" | tr '\n' ' ' || true)"
  if [[ -n "${dependents// }" ]]; then
    die "Remoção bloqueada: pacotes dependem de $id: $dependents"
  fi

  local files="$mdir/files.txt"
  [[ -f "$files" ]] || die "Manifesto de arquivos ausente: $files"

  if ! need_confirm "Remover $id do sistema?"; then
    warn "Operação cancelada."
    return 0
  fi

  local -a deps_ids=()
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && deps_ids+=("$dep")
  done < <(revdeps_from_manifest "$id" || true)

  info "Removendo: $id"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "DRY-RUN: removeria arquivos e atualizaria manifest/revdeps"
    return 0
  fi

  tac "$files" | while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    local abs="/$rel"
    case "$abs" in
      /etc/passwd|/etc/shadow|/bin/sh) warn "Protegido (não removido): $abs"; continue ;;
    esac
    if [[ -e "$abs" || -L "$abs" ]]; then
      rm -f "$abs" 2>/dev/null || true
      if [[ "$REMOVE_PRUNE_DIRS" -eq 1 ]]; then
        rmdir --ignore-fail-on-non-empty -p "$(dirname "$abs")" 2>/dev/null || true
      fi
    fi
  done

  if ((${#deps_ids[@]})); then
    revdeps_unregister_remove "$id" "${deps_ids[@]}"
  fi
  rm -rf "$mdir"

  info "Removido: $id"
}

is_orphan_pkgid() {
  local id="$1"
  [[ -d "$INST_DB/$id" ]] || return 1
  local deps
  deps="$(revdeps_list "$id" || true)"
  [[ -z "${deps//[[:space:]]/}" ]]
}

remove_pkgid() {
  local id="$1"
  remove_pkg "${id%-*}" "${id##*-}"
}

remove_deep() {
  need_root
  local name="$1" ver="$2"
  local root_id; root_id="$(pkg_id "$name" "$ver")"
  [[ -d "$INST_DB/$root_id" ]] || die "Não instalado: $root_id"

  local -a queue=()
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && queue+=("$dep")
  done < <(revdeps_from_manifest "$root_id" || true)

  remove_pkg "$name" "$ver"

  declare -A SEEN=()
  while ((${#queue[@]})); do
    local id="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n "$id" ]] || continue
    [[ -n "${SEEN[$id]:-}" ]] && continue
    SEEN["$id"]=1

    if is_orphan_pkgid "$id"; then
      local -a deps=()
      while IFS= read -r dep; do
        [[ -n "$dep" ]] && deps+=("$dep")
      done < <(revdeps_from_manifest "$id" || true)

      info "remove --deep: removendo órfão: $id"
      remove_pkgid "$id"
      queue+=("${deps[@]:-}")
    fi
  done
}

cmd_remove() {
  [[ $# -eq 2 ]] || die "Use: adm remove [--deep] [--prune-dirs] <programa> <versao>"
  if [[ "$REMOVE_DEEP" -eq 1 ]]; then
    remove_deep "$1" "$2"
  else
    remove_pkg "$1" "$2"
  fi
}

###############################################################################
# Search / Info
###############################################################################
cmd_search() {
  local needle="${1:-}"
  [[ -n "$needle" ]] || die "Use: adm search <termo>"
  local found=0
  while IFS= read -r s; do
    local cat base name ver
    cat="$(category_from_script "$s")"
    base="$(basename "$s" .sh)"
    name="${base%-*}"
    ver="${base##*-}"
    if [[ "$base" == *"$needle"* || "$name" == *"$needle"* || "$cat" == *"$needle"* ]]; then
      local mark="[   ]"
      is_installed "$name" "$ver" && mark="[ ✔ ]"
      printf '%b\n' "${mark} ${C_BOLD}${name}${C_RESET}-${ver} ${C_DIM}(${cat})${C_RESET}"
      found=1
    fi
  done < <(list_all_build_scripts)
  [[ "$found" -eq 1 ]] || warn "Nada encontrado para: $needle"
}

cmd_info() {
  local category="$1" name="$2" ver="$3"
  local script; script="$(find_build_script "$category" "$name" "$ver")" || die "Script não encontrado: $category/$name-$ver"
  meta_load_from_script "$script"
  local mark="[   ]"
  is_installed "$name" "$ver" && mark="[ ✔ ]"

  printf '%b\n' "${mark} ${C_BOLD}${name}${C_RESET}-${ver} ${C_DIM}(${category})${C_RESET}"
  printf '%b\n' "Script: $script"
  printf '%b\n' "Dependências: ${META_PKG_DEPENDS[*]:-(nenhuma)}"
  printf '%b\n' "Sources:"
  local x
  for x in "${META_PKG_SOURCES[@]:-}"; do printf '  - %s\n' "$x"; done
  if ((${#META_PKG_PATCHES[@]:-0})); then
    printf '%b\n' "Patches:"
    for x in "${META_PKG_PATCHES[@]:-}"; do printf '  - %s\n' "$x"; done
  fi
}

###############################################################################
# Sync (repo de scripts)
###############################################################################
cmd_sync() {
  [[ -n "$SYNC_REPO_URL" ]] || die "Defina SYNC_REPO_URL (export SYNC_REPO_URL=git@... )"
  have git || die "git ausente para sync"
  if [[ ! -d "$PKG_SCRIPTS_DIR/.git" ]]; then
    info "Clonando repo de scripts em: $PKG_SCRIPTS_DIR"
    run rm -rf "$PKG_SCRIPTS_DIR"
    run mkdir -p "$(dirname "$PKG_SCRIPTS_DIR")"
    run git clone -b "$SYNC_BRANCH" "$SYNC_REPO_URL" "$PKG_SCRIPTS_DIR"
  else
    info "Atualizando repo de scripts: $PKG_SCRIPTS_DIR"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "DRY-RUN: git fetch/pull"
    else
      ( cd "$PKG_SCRIPTS_DIR" && git fetch --all --prune && git checkout "$SYNC_BRANCH" && git pull --ff-only )
    fi
  fi
  info "Sync concluído."
}

###############################################################################
# Clean
###############################################################################
cmd_clean() {
  need_root
  info "Clean inteligente"
  run find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 -print -exec rm -rf {} + 2>/dev/null || true
  find "$BIN_CACHE" -type f -name '*.tar.zst' -mtime +30 | while IFS= read -r f; do
    local base; base="$(basename "$f" .tar.zst)"
    if [[ ! -d "$INST_DB/$base" ]]; then
      run rm -f "$f" || true
    fi
  done
  run find "$SUM_CACHE" -type f -mtime +90 -exec rm -f {} + 2>/dev/null || true
  info "Clean concluído."
}

###############################################################################
# Upgrade
###############################################################################
latest_script_for_name() {
  local name="$1"
  local best_ver="" best_path=""
  local s
  while IFS= read -r s; do
    local base n v
    base="$(basename "$s" .sh)"
    n="${base%-*}"
    v="${base##*-}"
    [[ "$n" == "$name" ]] || continue
    if [[ -z "$best_ver" ]]; then
      best_ver="$v"; best_path="$s"
    else
      if [[ "$(printf '%s\n' "$best_ver" "$v" | sort -V | tail -n1)" == "$v" && "$v" != "$best_ver" ]]; then
        best_ver="$v"; best_path="$s"
      fi
    fi
  done < <(list_all_build_scripts)
  [[ -n "$best_path" ]] || return 1
  echo "$best_path"
}

installed_versions_for_name() {
  local name="$1"
  local d
  for d in "$INST_DB"/*; do
    [[ -d "$d" ]] || continue
    local id; id="$(basename "$d")"
    [[ "$id" == "$name-"* ]] || continue
    echo "${id#"$name-"}"
  done
}

cmd_upgrade_one() {
  local name="$1"
  local latest_path; latest_path="$(latest_script_for_name "$name")" || die "Nenhum script encontrado para: $name"
  local latest_cat; latest_cat="$(category_from_script "$latest_path")"
  local latest_base; latest_base="$(basename "$latest_path" .sh)"
  local latest_ver="${latest_base##*-}"

  local cur_ver=""
  cur_ver="$(installed_versions_for_name "$name" | sort -V | tail -n1 || true)"

  if [[ -z "$cur_ver" ]]; then
    info "Não instalado: $name. Instalando última versão: $latest_ver"
  elif [[ "$cur_ver" == "$latest_ver" ]]; then
    info "$name já está na versão mais recente: $cur_ver"
    return 0
  else
    info "Upgrade: $name $cur_ver -> $latest_ver"
  fi

  DEP_VISIT=(); DEP_ORDER=()
  resolve_deps_dfs "$latest_cat" "$name" "$latest_ver"
  local item
  for item in "${DEP_ORDER[@]}"; do
    IFS='|' read -r c n v <<<"$item"
    local id; id="$(pkg_id "$n" "$v")"
    if [[ -f "$BIN_CACHE/${id}.tar.zst" ]]; then
      info "Cache binário já existe, pulando build: $id"
    else
      build_pkg "$c" "$n" "$v"
    fi
  done

  install_pkg_from_cache "$latest_cat" "$name" "$latest_ver"

  if [[ -n "$cur_ver" && "$UPGRADE_KEEP_OLD" -eq 0 ]]; then
    remove_pkg "$name" "$cur_ver"
  elif [[ -n "$cur_ver" ]]; then
    warn "Mantendo versão antiga instalada (--keep-old): $name-$cur_ver"
  fi
}

cmd_upgrade() {
  need_root
  if [[ "$UPGRADE_ALL" -eq 1 ]]; then
    info "Upgrade de todos os pacotes instalados"
    local d
    for d in "$INST_DB"/*; do
      [[ -d "$d" ]] || continue
      local id; id="$(basename "$d")"
      cmd_upgrade_one "${id%-*}"
    done
  else
    local name="${1:-}"
    [[ -n "$name" ]] || die "Use: adm upgrade <programa> ou adm upgrade --all"
    cmd_upgrade_one "$name"
  fi
}

###############################################################################
# Doctor
###############################################################################
doctor_reinstall_or_rebuild() {
  local id="$1"
  local name="${id%-*}"
  local ver="${id##*-}"
  local mf="$INST_DB/$id/manifest.info"
  local cat
  cat="$(grep -E '^category=' "$mf" | cut -d= -f2- || true)"

  local pkgfile="$BIN_CACHE/$id.tar.zst"
  if [[ -f "$pkgfile" ]]; then
    info "Doctor fix: reinstalando do cache: $id"
    install_pkg_from_cache "$cat" "$name" "$ver"
    return 0
  fi

  local script=""
  if [[ -n "$cat" ]]; then
    script="$(find_build_script "$cat" "$name" "$ver" || true)"
  fi
  if [[ -z "$script" ]]; then
    script="$(find_any_category_script "$name" "$ver" || true)"
    [[ -n "$script" ]] && cat="$(category_from_script "$script")"
  fi
  [[ -n "$script" ]] || { warn "Sem script para rebuild: $id"; return 1; }

  info "Doctor fix: rebuild + reinstall: $id"
  DEP_VISIT=(); DEP_ORDER=()
  resolve_deps_dfs "$cat" "$name" "$ver"
  local item
  for item in "${DEP_ORDER[@]}"; do
    IFS='|' read -r c n v <<<"$item"
    local bid; bid="$(pkg_id "$n" "$v")"
    [[ -f "$BIN_CACHE/${bid}.tar.zst" ]] || build_pkg "$c" "$n" "$v"
  done
  install_pkg_from_cache "$cat" "$name" "$ver"
}

cmd_doctor() {
  need_root
  info "Doctor: analisando integridade"
  local issues=0

  # 0) revdeps sanity
  local stale=0
  local f
  for f in "$REV_DB"/*.rdeps; do
    [[ -f "$f" ]] || continue
    while IFS= read -r depper; do
      [[ -n "$depper" ]] || continue
      [[ -d "$INST_DB/$depper" ]] || { warn "revdeps órfão: $(basename "$f") referencia pacote inexistente: $depper"; stale=1; }
    done <"$f"
  done

  if [[ "$stale" -eq 1 ]]; then
    ((issues++))
    if [[ "$DOCTOR_FIX" -eq 1 ]]; then
      warn "Doctor fix: reconstruindo banco de reverse-deps (REV_DB)"
      revdeps_rebuild_index
    else
      warn "Doctor: reverse-deps inconsistente. Use: adm doctor --fix"
    fi
  fi

  # 1) manifestos incompletos
  local d
  for d in "$INST_DB"/*; do
    [[ -d "$d" ]] || continue
    if [[ ! -f "$d/files.txt" || ! -f "$d/manifest.info" ]]; then
      warn "Manifesto incompleto: $(basename "$d")"
      ((issues++))
    fi
  done

  # 2) arquivos ausentes
  for d in "$INST_DB"/*; do
    [[ -d "$d" ]] || continue
    local id; id="$(basename "$d")"
    local fl="$d/files.txt"
    [[ -f "$fl" ]] || continue
    local missing=0
    while IFS= read -r rel; do
      [[ -z "$rel" ]] && continue
      local abs="/$rel"
      [[ -e "$abs" || -L "$abs" ]] || ((missing++))
    done <"$fl"
    if ((missing>0)); then
      warn "$id: $missing arquivos ausentes"
      ((issues++))
      if [[ "$DOCTOR_FIX" -eq 1 ]]; then
        doctor_reinstall_or_rebuild "$id" || true
      fi
    fi
  done

  # 3) deps ausentes
  local mf
  for mf in "$INST_DB"/*/manifest.info; do
    [[ -f "$mf" ]] || continue
    local id; id="$(basename "$(dirname "$mf")")"
    local deps; deps="$(grep -E '^deps=' "$mf" | cut -d= -f2- || true)"
    for dep in $deps; do
      [[ -n "$dep" ]] || continue
      if [[ ! -d "$INST_DB/$dep" ]]; then
        warn "$id depende de $dep, mas $dep não está instalado"
        ((issues++))
      fi
    done
  done

  if ((issues==0)); then
    info "Doctor: nenhuma anomalia detectada."
    return 0
  fi

  if [[ "$DOCTOR_FIX" -eq 1 ]]; then
    warn "Doctor: correções aplicadas (conservadoras). Revise logs: $LOG_FILE"
  else
    warn "Doctor: $issues problema(s) identificado(s). Use: adm doctor --fix para correção conservadora."
  fi
}

###############################################################################
# Lint
###############################################################################
lint_script() {
  local script="$1"
  local rel="${script#"$PKG_SCRIPTS_DIR"/}"

  bash -n "$script" 2>/dev/null || { err "lint: bash -n falhou: $rel"; bash -n "$script" || true; return 1; }

  if have shellcheck; then
    shellcheck -x "$script" >/dev/null 2>&1 || { warn "lint: shellcheck alertas em: $rel"; shellcheck -x "$script" || true; }
  fi

  # heurística anti top-level side effects
  local bad_lines
  bad_lines="$(awk '
    /^[[:space:]]*#!/ {next}
    /^[[:space:]]*$/ {next}
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*(export|declare|readonly)[[:space:]]+/ {next}
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ {next}
    /^[[:space:]]*function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {next}
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {next}
    /^[[:space:]]*[\{\}]?[[:space:]]*$/ {next}
    {print NR ":" $0; bad=1}
    END{exit(bad)}
  ' "$script" || true)"
  if [[ -n "$bad_lines" ]]; then
    err "lint: comandos no topo detectados (bloqueado): $rel"
    printf '%s\n' "$bad_lines" | head -n 20
    return 1
  fi

  meta_load_from_script "$script" >/dev/null 2>&1 || { err "lint: falha metadata: $rel"; return 1; }

  info "lint ok: $rel"
  return 0
}

cmd_lint() {
  local failures=0
  if [[ "$LINT_ALL" -eq 1 ]]; then
    info "Lint: verificando todos os scripts"
    local s
    while IFS= read -r s; do lint_script "$s" || failures=$((failures+1)); done < <(list_all_build_scripts)
  else
    [[ $# -eq 3 ]] || die "Use: adm lint --all  OU  adm lint <categoria> <programa> <versao>"
    local script; script="$(find_build_script "$1" "$2" "$3")" || die "Script não encontrado: $1/$2-$3"
    lint_script "$script" || failures=$((failures+1))
  fi
  ((failures==0)) || die "Lint falhou: $failures erro(s)."
  info "Lint concluído sem erros."
}

###############################################################################
# Flags parsing
###############################################################################
parse_global_flags() {
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -n|--dry-run) DRY_RUN=1; shift ;;
      -y|--yes) YES=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  echo "$@"
}

parse_cmd_flags() {
  local cmd="$1"; shift || true
  case "$cmd" in
    remove)
      while [[ "${1:-}" == -* ]]; do
        case "$1" in
          --deep) REMOVE_DEEP=1; shift ;;
          --prune-dirs) REMOVE_PRUNE_DIRS=1; shift ;;
          --dry-run|-n) DRY_RUN=1; shift ;;
          --yes|-y) YES=1; shift ;;
          --) shift; break ;;
          *) break ;;
        esac
      done
      ;;
    doctor)
      while [[ "${1:-}" == -* ]]; do
        case "$1" in
          --fix) DOCTOR_FIX=1; shift ;;
          --dry-run|-n) DRY_RUN=1; shift ;;
          --yes|-y) YES=1; shift ;;
          --) shift; break ;;
          *) break ;;
        esac
      done
      ;;
    upgrade)
      while [[ "${1:-}" == -* ]]; do
        case "$1" in
          --all) UPGRADE_ALL=1; shift ;;
          --keep-old) UPGRADE_KEEP_OLD=1; shift ;;
          --dry-run|-n) DRY_RUN=1; shift ;;
          --yes|-y) YES=1; shift ;;
          --) shift; break ;;
          *) break ;;
        esac
      done
      ;;
    lint)
      while [[ "${1:-}" == -* ]]; do
        case "$1" in
          --all) LINT_ALL=1; shift ;;
          --) shift; break ;;
          *) break ;;
        esac
      done
      ;;
    *) ;;
  esac
  echo "$@"
}

###############################################################################
# Ajuda
###############################################################################
usage() {
  cat <<EOF
adm - gerenciador de pacotes (LFS-style)

Uso:
  adm [--dry-run|-n] [--yes|-y] sync
  adm search <termo>
  adm info <categoria> <programa> <versao>
  adm [--dry-run|-n] build <categoria> <programa> <versao>
  adm [--dry-run|-n] install <categoria> <programa> <versao>
  adm [--dry-run|-n] remove [--deep] [--prune-dirs] <programa> <versao>
  adm [--dry-run|-n] clean
  adm [--dry-run|-n] doctor [--fix]
  adm [--dry-run|-n] upgrade [--all] [--keep-old] [<programa>]
  adm lint --all
  adm lint <categoria> <programa> <versao>

Variáveis úteis (export):
  ADM_ROOT, PKG_SCRIPTS_DIR, STATE_DIR, CACHE_DIR, LOG_DIR
  SYNC_REPO_URL, SYNC_BRANCH
EOF
}

###############################################################################
# Main (único)
###############################################################################
main() {
  check_tools
  lock_global

  local args
  args="$(parse_global_flags "$@")"
  # shellcheck disable=SC2206
  set -- $args

  local cmd="${1:-}"
  shift || true

  local rest
  rest="$(parse_cmd_flags "$cmd" "$@")"
  # shellcheck disable=SC2206
  set -- $rest

  case "$cmd" in
    sync)   cmd_sync "$@" ;;
    search) cmd_search "$@" ;;
    info)   [[ $# -eq 3 ]] || die "Use: adm info <categoria> <programa> <versao>"; cmd_info "$@" ;;
    lint)   cmd_lint "$@" ;;
    build)
      [[ $# -eq 3 ]] || die "Use: adm build <categoria> <programa> <versao>"
      DEP_VISIT=(); DEP_ORDER=()
      resolve_deps_dfs "$1" "$2" "$3"
      local item
      for item in "${DEP_ORDER[@]}"; do
        IFS='|' read -r c n v <<<"$item"
        local id; id="$(pkg_id "$n" "$v")"
        if [[ -f "$BIN_CACHE/${id}.tar.zst" ]]; then
          info "Cache binário já existe, pulando build: $id"
        else
          build_pkg "$c" "$n" "$v"
        fi
      done
      ;;
    install) [[ $# -eq 3 ]] || die "Use: adm install <categoria> <programa> <versao>"; install_pkg_from_cache "$@" ;;
    remove)  [[ $# -eq 2 ]] || die "Use: adm remove [--deep] [--prune-dirs] <programa> <versao>"; cmd_remove "$@" ;;
    upgrade) cmd_upgrade "$@" ;;
    clean)   cmd_clean ;;
    doctor)  cmd_doctor ;;
    ""|help|-h|--help) usage ;;
    *) die "Comando desconhecido: $cmd (use: adm help)" ;;
  esac
}

main "$@"
