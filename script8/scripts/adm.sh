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

HOOKS_DIR="${HOOKS_DIR:-$ADM_ROOT/hooks}" # opcional: scripts executáveis por etapa
SYNC_REPO_URL="${SYNC_REPO_URL:-}"        # ex: git@seu_repo:adm-packages.git
SYNC_BRANCH="${SYNC_BRANCH:-main}"

LOCK_FILE="${LOCK_FILE:-/var/lock/admpkg.lock}"
REV_DB="$STATE_DIR/revdeps"

# ferramentas mínimas
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
UPGRADE_ALL=0
UPGRADE_KEEP_OLD=0
LINT_ALL=0

###############################################################################
# UI: cores, logs, spinner
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

LOG_FILE="$LOG_DIR/admpkg-$(date '+%Y%m%d').log"
mkdir -p "$STATE_DIR" "$CACHE_DIR" "$LOG_DIR" "$SRC_CACHE" "$BIN_CACHE" "$SUM_CACHE" "$TMP_DIR" "$INST_DB" "$BUILD_DB" "$REV_DB"

log() { printf '%s %s\n' "$(ts)" "$*" >>"$LOG_FILE"; }
info() { printf '%b\n' "${C_CYAN}${C_BOLD}==>${C_RESET} $*"; log "INFO: $*"; }
warn() { printf '%b\n' "${C_YELLOW}${C_BOLD}WARN:${C_RESET} $*"; log "WARN: $*"; }
err()  { printf '%b\n' "${C_RED}${C_BOLD}ERRO:${C_RESET} $*"; log "ERRO: $*"; }
die()  { err "$*"; exit 1; }

# spinner simples (para etapas que não têm progresso nativo)
SPIN_PID=""
spin_start() {
  local msg="$1"
  [[ "$DRY_RUN" -eq 1 ]] && { printf '%b\n' "${C_DIM}${msg}${C_RESET} (dry-run)"; return 0; }
  printf '%b' "${C_DIM}${msg}${C_RESET} "
  (
    local frames='|/-\'
    local i=0
    while :; do
      printf '\b%b' "${frames:i++%4:1}"
      sleep 0.1
    done
  ) &
  SPIN_PID=$!
  disown || true
}
spin_stop() {
  local rc="${1:-0}"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  if [[ -n "${SPIN_PID:-}" ]] && kill -0 "$SPIN_PID" 2>/dev/null; then
    kill "$SPIN_PID" 2>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
  fi
  SPIN_PID=""
  if [[ "$rc" -eq 0 ]]; then
    printf '\b%b\n' "${C_GREEN}✔${C_RESET}"
  else
    printf '\b%b\n' "${C_RED}✖${C_RESET}"
  fi
}

on_err() {
  local rc=$?
  spin_stop "$rc" || true
  err "Falha (exit=$rc). Veja log: $LOG_FILE"
}
trap on_err ERR

###############################################################################
# Execução segura / dry-run
###############################################################################
run() {
  # uso: run cmd arg...
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
need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Execute como root (necessário para instalar/remover)."
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

check_tools() {
  for t in "${REQUIRED_TOOLS[@]}"; do
    have "$t" || die "Ferramenta obrigatória ausente: $t"
  done
  # flock é recomendável (lock global); se não existir, ainda funciona mas sem lock
  if ! have flock; then
    warn "flock ausente: concorrência não será bloqueada (recomendado instalar util-linux)."
  fi
}

sanitize() {
  # remove chars perigosos para paths
  echo "$1" | tr -cd 'A-Za-z0-9._+-'
}

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

# -----------------------------------------------------------------------------
# Reverse-deps DB (persistente)
#   - Para cada pacote DEP (id), há um arquivo:
#       $REV_DB/<dep-id>.rdeps
#     contendo (um por linha) os pacotes que dependem dele.
# -----------------------------------------------------------------------------

revdeps_path() {
  local dep_id="$1"
  echo "$REV_DB/${dep_id}.rdeps"
}

revdeps_add() {
  # uso: revdeps_add <dep_id> <dependent_id>
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
  # uso: revdeps_remove <dep_id> <dependent_id>
  local dep_id="$1" dependent_id="$2"
  local f; f="$(revdeps_path "$dep_id")"
  [[ -f "$f" ]] || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "revdeps: removeria $dependent_id -> $dep_id"
    return 0
  fi
  grep -vxF "$dependent_id" "$f" >"$f.tmp" || true
  mv "$f.tmp" "$f"
  # limpa arquivo vazio
  [[ -s "$f" ]] || rm -f "$f"
}

revdeps_list() {
  # uso: revdeps_list <pkg_id>  (retorna dependentes)
  local dep_id="$1"
  local f; f="$(revdeps_path "$dep_id")"
  [[ -f "$f" ]] || return 0
  cat "$f"
}

revdeps_register_install() {
  # uso: revdeps_register_install <pkg_id> <dep_ids...>
  local pkg="$1"; shift || true
  local dep
  for dep in "$@"; do
    [[ -n "$dep" ]] || continue
    revdeps_add "$dep" "$pkg"
  done
}

revdeps_unregister_remove() {
  # uso: revdeps_unregister_remove <pkg_id> <dep_ids...>
  local pkg="$1"; shift || true
  local dep
  for dep in "$@"; do
    [[ -n "$dep" ]] || continue
    revdeps_remove "$dep" "$pkg"
  done
}

revdeps_from_manifest() {
  # uso: revdeps_from_manifest <pkg_id>  -> imprime deps (ids) a partir do manifest.info
  local pkg_id="$1"
  local mf="$INST_DB/$pkg_id/manifest.info"
  [[ -f "$mf" ]] || return 0
  local deps
  deps="$(grep -E '^deps=' "$mf" | cut -d= -f2- || true)"
  # devolve como linhas
  for d in $deps; do
    echo "$d"
  done
}

revdeps_rebuild_index() {
  info "revdeps: reconstruindo índice a partir de $INST_DB"
  run mkdir -p "$REV_DB"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "DRY-RUN: limparia $REV_DB/*.rdeps e reconstruiria a partir dos manifestos"
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
# Descoberta de scripts de build
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
  local dir; dir="$(dirname "$path")"
  basename "$dir"
}

###############################################################################
# Lock
###############################################################################
lock_global() {
  if have flock; then
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Outro processo do adm está em execução (lock: $LOCK_FILE)."
  fi
}

# -----------------------------------------------------------------------------
# Metadata sandbox: extrai variáveis sem "source" no processo principal.
# Requer que o script não tenha efeitos colaterais no top-level (use lint para garantir).
# -----------------------------------------------------------------------------

meta_dump_sandbox() {
  local script="$1"
  [[ -f "$script" ]] || die "meta: script não encontrado: $script"

  # Verifica sintaxe antes
  bash -n "$script" || die "meta: erro de sintaxe em: $script"

  # Rodar em subshell controlado e devolver somente metadata (declare -p)
  # Importante: não executar build/install aqui.
  bash -c "
    set -Eeuo pipefail
    shopt -s nullglob
    source '$script'

    # defaults defensivos
    : \"\${PKG_NAME:=}\"
    : \"\${PKG_VERSION:=}\"
    : \"\${PKG_CATEGORY:=}\"
    declare -p PKG_NAME PKG_VERSION PKG_CATEGORY 2>/dev/null || true
    declare -p PKG_DEPENDS 2>/dev/null || echo 'declare -a PKG_DEPENDS=()'
    declare -p PKG_SOURCES 2>/dev/null || echo 'declare -a PKG_SOURCES=()'
    declare -p PKG_PATCHES 2>/dev/null || echo 'declare -a PKG_PATCHES=()'

    # flags sobre funções (para validação)
    if declare -F build >/dev/null 2>&1; then echo '__HAS_BUILD=1'; else echo '__HAS_BUILD=0'; fi
    if declare -F install >/dev/null 2>&1; then echo '__HAS_INSTALL=1'; else echo '__HAS_INSTALL=0'; fi
  "
}

meta_load_from_script() {
  # Carrega metadata no processo atual SEM source do script:
  # popula: META_PKG_NAME META_PKG_VERSION META_PKG_CATEGORY + arrays META_PKG_DEPENDS etc.
  local script="$1"
  local dump
  dump="$(meta_dump_sandbox "$script")" || die "meta: falha ao extrair metadata: $script"

  # Variáveis temporárias (no processo atual) vindas de declare -p
  local __HAS_BUILD=0 __HAS_INSTALL=0
  local PKG_NAME="" PKG_VERSION="" PKG_CATEGORY=""
  local -a PKG_DEPENDS=() PKG_SOURCES=() PKG_PATCHES=()

  # shellcheck disable=SC1090
  eval "$dump"

  # Exporta para nomes "META_*" para evitar colisão com ambiente
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
  # valida contrato mínimo: sources + build/install
  local script="$1"
  [[ "${#META_PKG_SOURCES[@]}" -gt 0 ]] || die "meta: PKG_SOURCES vazio/ausente em $script"
  [[ "$META_HAS_BUILD" == "1" ]] || die "meta: build() ausente em $script"
  [[ "$META_HAS_INSTALL" == "1" ]] || die "meta: install() ausente em $script"
}

###############################################################################
# Dependências: parsing mais robusto
# Aceita:
#   - legado: "nome-versao" (divide no ÚLTIMO '-' se sufixo começa com dígito)
#   - "nome@versao"
#   - "nome>=versao", "nome<=versao", "nome=versao"
# Retorna por stdout: "name|op|ver"
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
    # legado: split no último '-' somente se o sufixo começa com dígito
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

# compara versões: sort -V (Linux coreutils)
ver_cmp_ok() {
  # uso: ver_cmp_ok installed op required
  local inst="$1" op="$2" req="$3"
  [[ -z "$op" || -z "$req" ]] && return 0
  if [[ "$op" == "=" ]]; then
    [[ "$inst" == "$req" ]]
  elif [[ "$op" == ">=" ]]; then
    [[ "$(printf '%s\n' "$inst" "$req" | sort -V | head -n1)" == "$req" ]]
  elif [[ "$op" == "<=" ]]; then
    [[ "$(printf '%s\n' "$inst" "$req" | sort -V | head -n1)" == "$inst" ]]
  else
    return 1
  fi
}

###############################################################################
# Resolução de dependências com detecção de ciclo (DFS)
###############################################################################
declare -A DEP_VISIT=() # 0=unseen,1=visiting,2=done
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

  # metadata via sandbox (sem poluir processo principal)
  meta_load_from_script "$script"

  local deps=("${META_PKG_DEPENDS[@]:-}")
  local d
  for d in "${deps[@]:-}"; do
    local dn dop dv
    IFS='|' read -r dn dop dv <<<"$(parse_dep "$d")"
    [[ -n "$dn" ]] || die "Dependência inválida ($script): $d"

    # Para build determinístico, exigimos versão no dep
    if [[ -z "$dv" ]]; then
      die "Dependência sem versão não suportada no build: $d (em $script)"
    fi

    # (>= <= =) — para o grafo, pegamos a versão mínima/alvo do script correspondente.
    # Implementação atual: exige existir script EXATO dn-dv.
    # Se você quiser ">=X" buscar a maior disponível >=X, eu te passo uma função adicional.
    local dep_script; dep_script="$(find_any_category_script "$dn" "$dv")" || die "Dependência não encontrada nos scripts: $dn-$dv"
    local dep_cat; dep_cat="$(category_from_script "$dep_script")"

    resolve_deps_dfs "$dep_cat" "$dn" "$dv"
  done

  DEP_VISIT["$key"]=2
  DEP_ORDER+=("$category|$pkg|$ver")
}

###############################################################################
# Download com progresso + cache
###############################################################################
cache_key_for_url() {
  local url="$1"
  printf '%s' "$url" | sha256sum | awk '{print $1}'
}

filename_from_url() {
  local url="$1"
  local base="${url##*/}"
  base="${base%%\?*}"
  [[ -n "$base" && "$base" != "$url" ]] || base="source"
  echo "$(sanitize "$base")"
}

download_one() {
  local url="$1"
  local out="$2"

  run mkdir -p "$(dirname "$out")"
  [[ -f "$out" ]] && return 0

  # Git
  if [[ "$url" =~ ^git\+ ]]; then
    have git || die "git ausente para baixar: $url"
    local real="${url#git+}"
    spin_start "Clonando (git) ${real}"
    run rm -rf "$out.tmp"
    run git clone --depth 1 "$real" "$out.tmp"
    run mv "$out.tmp" "$out"
    spin_stop 0
    return 0
  fi

  if [[ "$url" =~ \.git$ ]] || [[ "$url" =~ ^git:// ]] ; then
    have git || die "git ausente para baixar: $url"
    spin_start "Clonando (git) ${url}"
    run rm -rf "$out.tmp"
    run git clone --depth 1 "$url" "$out.tmp"
    run mv "$out.tmp" "$out"
    spin_stop 0
    return 0
  fi

  # HTTP/HTTPS/FTP
  if have curl; then
    info "Baixando: $url"
    run curl -L --fail --retry 3 --retry-delay 1 --progress-bar -o "$out.tmp" "$url"
    run mv "$out.tmp" "$out"
    return 0
  elif have wget; then
    info "Baixando: $url"
    run wget --tries=3 --progress=bar:force:noscroll -O "$out.tmp" "$url"
    run mv "$out.tmp" "$out"
    return 0
  else
    die "Sem curl/wget para baixar: $url"
  fi
}

###############################################################################
# Checksums: verificação + cache
###############################################################################
sum_cache_path() {
  local algo="$1" hex="$2"
  echo "$SUM_CACHE/${algo}/$hex"
}

verify_checksum() {
  local file="$1" algo="$2" expected="$3"
  run mkdir -p "$SUM_CACHE/$algo"

  local got=""
  case "$algo" in
    sha256) got="$(sha256sum "$file" | awk '{print $1}')" ;;
    md5)    got="$(md5sum "$file"    | awk '{print $1}')" ;;
    *) die "Algoritmo inválido: $algo (use sha256 ou md5)" ;;
  esac

  if [[ "$got" != "$expected" ]]; then
    die "Checksum inválido para $(basename "$file"): esperado=$expected obtido=$got"
  fi

  local cached; cached="$(sum_cache_path "$algo" "$expected")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '%s  %s\n' "$got" "$file" >"$cached"
  else
    info "Checksum ok (dry-run): $(basename "$file")"
  fi
}

###############################################################################
# Hooks externos (opcional) + hooks do script
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
# Patches: baixar + aplicar
# Formato:
#   PKG_PATCHES=( "url|sha256|<hex>|<strip>|<cwd_rel>" ... )
# strip default: 1 ; cwd_rel default: "." (workdir)
###############################################################################
apply_patches() {
  local work="$1"
  if ((${#PKG_PATCHES[@]:-0})); then
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
  fi
}

###############################################################################
# Tar safety: valida lista antes de extrair
###############################################################################
normalize_tar_list() {
  # remove ./ e linhas vazias
  sed -e 's#^\./##' -e '/^$/d'
}

validate_tar_list() {
  local list_file="$1"
  local bad=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # não aceitar absolutos / traversal / caracteres de controle
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

  # shellcheck disable=SC1090
  source "$script"

  : "${PKG_NAME:=$name}"
  : "${PKG_VERSION:=$ver}"
  : "${PKG_SOURCES:?PKG_SOURCES não definido em $script}"
  if ! declare -F build >/dev/null 2>&1; then die "Função build() ausente em $script"; fi
  if ! declare -F install >/dev/null 2>&1; then die "Função install() ausente em $script"; fi

  export ADM_WORKDIR="$work"
  export ADM_STAGEDIR="$stage"
  export DESTDIR="$stage"

  run_hook_external "pre_fetch"
  run_hook_function "pre_fetch"

  # Fetch sources
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

  # Patches: baixar + aplicar
  apply_patches "$work"

  run_hook_external "pre_build"
  run_hook_function "pre_build"

  info "Construindo: $PKG_NAME-$PKG_VERSION ($category)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Executaria build() em $work (dry-run)"
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

  # Empacotar tar.zst
  local pkgfile="$BIN_CACHE/${id}.tar.zst"
  info "Empacotando: $(basename "$pkgfile")"
  run rm -f "$pkgfile"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Criaria pacote: $pkgfile (dry-run)"
  else
    ( cd "$stage" && tar --numeric-owner --xattrs --acls -cf - . ) \
      | zstd -T0 -19 --long=31 -o "$pkgfile"
  fi

  # registrar build
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
# Instalação do cache (com validação de tar) + deps
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

  # Metadata via sandbox (SEM source no processo principal)
  local script; script="$(find_build_script "$category" "$name" "$ver")" || die "Script não encontrado: $category/$name-$ver"
  meta_load_from_script "$script"
  # deps do script -> ids do grafo (exigimos versão, consistente com seu resolve_deps_dfs atual)
  local -a dep_ids=()
  local d
  for d in "${META_PKG_DEPENDS[@]:-}"; do
    local dn dop dv
    IFS='|' read -r dn dop dv <<<"$(parse_dep "$d")"
    [[ -n "$dn" ]] || die "Dependência inválida ($script): $d"
    [[ -n "$dv" ]] || die "Dependência sem versão não suportada no install: $d (em $script)"
    dep_ids+=("$(pkg_id "$dn" "$dv")")
  done

  # instala deps antes
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
    info "DRY-RUN: registraria files.txt + extrairia em / + manifest.info + revdeps"
    return 0
  fi

  : >"$files_list"

  # lista e extrai
  zstd -dc "$pkgfile" | tar -tf - >"$files_list"
  zstd -dc "$pkgfile" | tar --xattrs --acls -xpf - -C /

  # manifest.info (armazenar deps como IDs para o revdeps funcionar de forma determinística)
  {
    echo "name=$name"
    echo "version=$ver"
    echo "category=$category"
    echo "installed_at=$(ts)"
    echo "pkgfile=$pkgfile"
    echo "deps=${dep_ids[*]:-}"
    echo "script=$script"
  } >"$mdir/manifest.info"

  # registra reverse-deps: para cada dep -> este pacote depende dele
  if ((${#dep_ids[@]})); then
    revdeps_register_install "$id" "${dep_ids[@]}"
  fi

  info "Instalado: $id"
}

cmd_remove() {
  need_root
  local name="$1" ver="$2"

  if [[ "$REMOVE_DEEP" -eq 1 ]]; then
    remove_deep "$name" "$ver"
  else
    remove_pkg "$name" "$ver"
  fi
}

###############################################################################
# Remove (mais seguro): por padrão NÃO remove diretórios; use --prune-dirs
###############################################################################
remove_pkg() {
  need_root
  local name="$1" ver="$2"
  local id; id="$(pkg_id "$name" "$ver")"
  local mdir="$INST_DB/$id"
  [[ -d "$mdir" ]] || die "Não instalado: $id"

  # bloqueia se alguém depende dele (via REV_DB)
  local dependents=()
  while IFS= read -r x; do
    [[ -n "$x" ]] || continue
    dependents+=("$x")
  done < <(revdeps_list "$id" || true)

  if ((${#dependents[@]})); then
    die "Remoção bloqueada: pacotes dependem de $id: ${dependents[*]} (use: adm remove --deep para remover em cascata)"
  fi

  local files="$mdir/files.txt"
  [[ -f "$files" ]] || die "Manifesto de arquivos ausente: $files"

  if ! need_confirm "Confirmar remoção de $id?"; then
    warn "Remoção cancelada: $id"
    return 0
  fi

  info "Removendo: $id"

  # deps (ids) para limpar reverse-deps
  local -a deps_ids=()
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    deps_ids+=("$dep")
  done < <(revdeps_from_manifest "$id" || true)

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "DRY-RUN: removeria arquivos do files.txt e limparia manifest + revdeps"
    return 0
  fi

  # remove arquivos (ordem reversa ajuda em diretórios)
  tac "$files" | while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    local abs="/$rel"
    if [[ -e "$abs" || -L "$abs" ]]; then
      rm -f "$abs" 2>/dev/null || true
      rmdir --ignore-fail-on-non-empty -p "$(dirname "$abs")" 2>/dev/null || true
    fi
  done

  # atualiza reverse-deps: este pacote deixa de depender de deps_ids
  if ((${#deps_ids[@]})); then
    revdeps_unregister_remove "$id" "${deps_ids[@]}"
  fi

  rm -rf "$mdir"

  info "Removido: $id"
}

is_orphan_pkgid() {
  # órfão = instalado e ninguém depende dele (reverse-deps vazio)
  local id="$1"
  [[ -d "$INST_DB/$id" ]] || return 1
  local dependents
  dependents="$(revdeps_list "$id" || true)"
  [[ -z "${dependents//[[:space:]]/}" ]]
}

remove_pkgid() {
  # remove via name/ver
  local id="$1"
  local n="${id%-*}"
  local v="${id##*-}"
  remove_pkg "$n" "$v"
}

remove_deep() {
  need_root
  local name="$1" ver="$2"
  local root_id; root_id="$(pkg_id "$name" "$ver")"

  # fila de possíveis órfãos após remover root:
  # estratégia: após remover um pacote, os deps dele podem virar órfãos.
  local queue=()
  local seen=()
  declare -A SEEN=()

  # coletar deps do root antes de remover
  local initial_deps=()
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && initial_deps+=("$dep")
  done < <(revdeps_from_manifest "$root_id" || true)

  remove_pkg "$name" "$ver"

  queue=("${initial_deps[@]:-}")

  while ((${#queue[@]})); do
    local id="${queue[0]}"
    queue=("${queue[@]:1}")

    [[ -n "$id" ]] || continue
    [[ -n "${SEEN[$id]:-}" ]] && continue
    SEEN["$id"]=1

    # só remove se órfão
    if is_orphan_pkgid "$id"; then
      # antes de remover, capturar deps dele para continuar cascata
      local deps=()
      while IFS= read -r dep; do
        [[ -n "$dep" ]] && deps+=("$dep")
      done < <(revdeps_from_manifest "$id" || true)

      info "remove --deep: removendo órfão: $id"
      remove_pkgid "$id"

      # deps dele podem virar órfãos
      queue+=("${deps[@]:-}")
    fi
  done
}

###############################################################################
# Search / Info (read-only)
###############################################################################
cmd_search() {
  local needle="${1:-}"
  [[ -n "$needle" ]] || die "Use: adm search <termo>"

  local found=0
  while IFS= read -r s; do
    local cat; cat="$(category_from_script "$s")"
    local base; base="$(basename "$s" .sh)"
    local name="${base%-*}"
    local ver="${base##*-}"

    # busca literal (evita regex injection)
    if [[ "$base" == *"$needle"* || "$name" == *"$needle"* || "$cat" == *"$needle"* ]]; then
      local mark="[   ]"
      if is_installed "$name" "$ver"; then mark="[ ✔ ]"; fi
      printf '%b\n' "${mark} ${C_BOLD}${name}${C_RESET}-${ver} ${C_DIM}(${cat})${C_RESET}"
      found=1
    fi
  done < <(list_all_build_scripts)

  [[ "$found" -eq 1 ]] || warn "Nada encontrado para: $needle"
}

cmd_info() {
  local category="$1" name="$2" ver="$3"
  local script; script="$(find_build_script "$category" "$name" "$ver")" || die "Script não encontrado: $category/$name-$ver"
  # shellcheck disable=SC1090
  source "$script"

  local mark="[   ]"
  if is_installed "$name" "$ver"; then mark="[ ✔ ]"; fi

  printf '%b\n' "${mark} ${C_BOLD}${name}${C_RESET}-${ver} ${C_DIM}(${category})${C_RESET}"
  printf '%b\n' "Script: ${script}"
  printf '%b\n' "Dependências: ${PKG_DEPENDS[*]:-(nenhuma)}"
  printf '%b\n' "Sources:"
  local x
  for x in "${PKG_SOURCES[@]:-}"; do
    printf '  - %s\n' "$x"
  done
  if ((${#PKG_PATCHES[@]:-0})); then
    printf '%b\n' "Patches:"
    for x in "${PKG_PATCHES[@]:-}"; do
      printf '  - %s\n' "$x"
    done
  fi

  if is_installed "$name" "$ver"; then
    local mdir; mdir="$(installed_manifest_dir "$name" "$ver")"
    printf '%b\n' "Instalado em: $(grep -E '^installed_at=' "$mdir/manifest.info" | cut -d= -f2- || true)"
  fi
}

###############################################################################
# Sync (scripts repo)
###############################################################################
cmd_sync() {
  [[ -n "$SYNC_REPO_URL" ]] || die "Defina SYNC_REPO_URL (ex: export SYNC_REPO_URL=git@... )"
  have git || die "git ausente para sync"

  if [[ ! -d "$PKG_SCRIPTS_DIR/.git" ]]; then
    info "Clonando repo de scripts em: $PKG_SCRIPTS_DIR"
    run rm -rf "$PKG_SCRIPTS_DIR"
    run mkdir -p "$(dirname "$PKG_SCRIPTS_DIR")"
    run git clone -b "$SYNC_BRANCH" "$SYNC_REPO_URL" "$PKG_SCRIPTS_DIR"
  else
    info "Atualizando repo de scripts: $PKG_SCRIPTS_DIR"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "git fetch/pull em $PKG_SCRIPTS_DIR (dry-run)"
    else
      ( cd "$PKG_SCRIPTS_DIR" && git fetch --all --prune && git checkout "$SYNC_BRANCH" && git pull --ff-only )
    fi
  fi
  info "Sync concluído."
}

###############################################################################
# Clean inteligente
###############################################################################
cmd_clean() {
  need_root
  info "Clean inteligente"

  # 1) remove temporários antigos (>7 dias)
  run find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 -print -exec rm -rf {} + 2>/dev/null || true

  # 2) remove binários antigos não instalados (>30 dias)
  find "$BIN_CACHE" -type f -name '*.tar.zst' -mtime +30 | while IFS= read -r f; do
    local base; base="$(basename "$f" .tar.zst)"
    local m="$INST_DB/$base"
    if [[ ! -d "$m" ]]; then
      run rm -f "$f" || true
    fi
  done

  # 3) remove checksums cache órfão (>90 dias)
  run find "$SUM_CACHE" -type f -mtime +90 -exec rm -f {} + 2>/dev/null || true

  info "Clean concluído."
}

###############################################################################
# Upgrade (major inclusive)
# uso:
#   adm upgrade <programa>
#   adm upgrade --all
# flags:
#   --keep-old   não remove a versão antiga
###############################################################################
latest_script_for_name() {
  local name="$1"
  local best_ver=""
  local best_path=""

  local s
  while IFS= read -r s; do
    local base; base="$(basename "$s" .sh)"
    local n="${base%-*}"
    local v="${base##*-}"
    [[ "$n" == "$name" ]] || continue

    if [[ -z "$best_ver" ]]; then
      best_ver="$v"; best_path="$s"
    else
      # se v > best_ver
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
    if [[ "$id" == "$name-"* ]]; then
      echo "${id#"$name-"}"
    fi
  done
}

cmd_upgrade_one() {
  local name="$1"

  local latest_path; latest_path="$(latest_script_for_name "$name")" || die "Nenhum script encontrado para: $name"
  local latest_cat; latest_cat="$(category_from_script "$latest_path")"
  local latest_base; latest_base="$(basename "$latest_path" .sh)"
  local latest_ver="${latest_base##*-}"

  # se não instalado: oferecer install
  local cur_ver=""
  cur_ver="$(installed_versions_for_name "$name" | sort -V | tail -n1 || true)"

  if [[ -z "$cur_ver" ]]; then
    info "Não instalado: $name. Instalando última versão disponível: $latest_ver"
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
    return 0
  fi

  # compara versões
  if [[ "$(printf '%s\n' "$cur_ver" "$latest_ver" | sort -V | tail -n1)" == "$cur_ver" && "$cur_ver" == "$latest_ver" ]]; then
    info "$name já está na versão mais recente: $cur_ver"
    return 0
  fi

  info "Upgrade: $name $cur_ver -> $latest_ver"

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

  if [[ "$UPGRADE_KEEP_OLD" -eq 0 ]]; then
    remove_pkg "$name" "$cur_ver"
  else
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
      local n="${id%-*}"
      cmd_upgrade_one "$n"
    done
  else
    local name="${1:-}"
    [[ -n "$name" ]] || die "Use: adm upgrade <programa> ou adm upgrade --all"
    cmd_upgrade_one "$name"
  fi
}

###############################################################################
# Doctor: verificação + (--fix) correção conservadora
###############################################################################
doctor_reinstall_or_rebuild() {
  local id="$1"
  local name="${id%-*}"
  local ver="${id##*-}"
  local mdir="$INST_DB/$id"
  local mf="$mdir/manifest.info"
  local cat
  cat="$(grep -E '^category=' "$mf" | cut -d= -f2- || true)"

  # 1) tenta reinstalar do cache (mais seguro)
  local pkgfile="$BIN_CACHE/$id.tar.zst"
  if [[ -f "$pkgfile" ]]; then
    info "Doctor fix: reinstalando do cache: $id"
    install_pkg_from_cache "$cat" "$name" "$ver"
    return 0
  fi

  # 2) fallback: rebuild + install se houver script
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
    if [[ -f "$BIN_CACHE/${bid}.tar.zst" ]]; then
      info "Cache binário já existe, pulando build: $bid"
    else
      build_pkg "$c" "$n" "$v"
    fi
  done
  install_pkg_from_cache "$cat" "$name" "$ver"
}

cmd_doctor() {
  need_root
  info "Doctor: analisando integridade"
  local issues=0

  # 0) revdeps: validação rápida
  local stale=0
  local f
  for f in "$REV_DB"/*.rdeps; do
    [[ -f "$f" ]] || continue
    while IFS= read -r depper; do
      [[ -n "$depper" ]] || continue
      if [[ ! -d "$INST_DB/$depper" ]]; then
        warn "revdeps órfão: $(basename "$f") referencia pacote inexistente: $depper"
        stale=1
      fi
    done <"$f"
  done

  if [[ "$stale" -eq 1 ]]; then
    ((issues++))
    if [[ "$DOCTOR_FIX" -eq 1 ]]; then
      warn "Doctor fix: reconstruindo banco de reverse-deps (REV_DB)"
      revdeps_rebuild_index
    else
      warn "Doctor: banco reverse-deps inconsistente. Sugestão: adm doctor --fix (reconstrói REV_DB)."
    fi
  fi

  # 1) manifestos sem files.txt/manifest.info
  local d
  for d in "$INST_DB"/*; do
    [[ -d "$d" ]] || continue
    if [[ ! -f "$d/files.txt" || ! -f "$d/manifest.info" ]]; then
      warn "Manifesto incompleto: $(basename "$d")"
      ((issues++))
    fi
  done

  # 2) arquivos ausentes vs manifesto
  for d in "$INST_DB"/*; do
    [[ -d "$d" ]] || continue
    local id; id="$(basename "$d")"
    local fl="$d/files.txt"
    [[ -f "$fl" ]] || continue

    local missing=0
    while IFS= read -r rel; do
      [[ -z "$rel" ]] && continue
      local abs="/$rel"
      if [[ ! -e "$abs" && ! -L "$abs" ]]; then
        ((missing++))
      fi
    done <"$fl"

    if ((missing>0)); then
      warn "$id: $missing arquivos ausentes (sugestão: rebuild + reinstall)"
      ((issues++))
      # correção automática continua conservadora (rebuild+reinstall você já vinha seguindo)
    fi
  done

  # 3) deps inconsistentes: dep não instalada
  local mf
  for mf in "$INST_DB"/*/manifest.info; do
    [[ -f "$mf" ]] || continue
    local id; id="$(basename "$(dirname "$mf")")"
    local deps; deps="$(grep -E '^deps=' "$mf" | cut -d= -f2- || true)"

    for dep in $deps; do
      [[ -z "$dep" ]] && continue
      if [[ ! -d "$INST_DB/$dep" ]]; then
        warn "$id depende de $dep, mas $dep não está instalado"
        ((issues++))

        if [[ "$DOCTOR_FIX" -eq 1 ]]; then
          # tenta instalar a dep (se existir script)
          local dn="${dep%-*}"
          local dv="${dep##*-}"
          local dep_script
          if dep_script="$(find_any_category_script "$dn" "$dv" 2>/dev/null)"; then
            local dep_cat; dep_cat="$(category_from_script "$dep_script")"
            # se não houver binário, builda
            if [[ ! -f "$BIN_CACHE/${dep}.tar.zst" ]]; then
              DEP_VISIT=(); DEP_ORDER=()
              resolve_deps_dfs "$dep_cat" "$dn" "$dv"
              local item
              for item in "${DEP_ORDER[@]}"; do
                IFS='|' read -r c n v <<<"$item"
                local bid; bid="$(pkg_id "$n" "$v")"
                [[ -f "$BIN_CACHE/${bid}.tar.zst" ]] || build_pkg "$c" "$n" "$v"
              done
            fi
            install_pkg_from_cache "$dep_cat" "$dn" "$dv"
          else
            warn "Doctor fix: sem script para dep ausente: $dep"
          fi
        fi
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
# Lint (valida scripts de build)
###############################################################################
lint_script() {
  local script="$1"
  local rel="${script#"$PKG_SCRIPTS_DIR"/}"

  # 1) sintaxe bash
  if ! bash -n "$script" 2>/dev/null; then
    err "lint: bash -n falhou: $rel"
    bash -n "$script" || true
    return 1
  fi

  # 2) shellcheck (opcional)
  if have shellcheck; then
    if ! shellcheck -x "$script" >/dev/null 2>&1; then
      warn "lint: shellcheck alertas em: $rel"
      shellcheck -x "$script" || true
    fi
  fi

  # 3) heurística anti “efeitos colaterais no topo”
  # permite: shebang, comentários, blank, assignments/export/declare/readonly, function defs e chaves
  local bad_lines
  bad_lines="$(awk '
    BEGIN{bad=0}
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
    err "lint: comandos no topo do script detectados (isso quebra segurança/metadata): $rel"
    printf '%s\n' "$bad_lines" | head -n 20
    return 1
  fi

  # 4) valida presença de PKG_SOURCES e funções build/install
  # (ainda precisa source; lint assume que não há topo executável por heurística acima)
  local out
  out="$(bash -c "
    set -e
    source '$script'
    declare -p PKG_SOURCES >/dev/null 2>&1 || { echo 'ERR:PKG_SOURCES'; exit 10; }
    declare -F build >/dev/null 2>&1 || { echo 'ERR:build'; exit 11; }
    declare -F install >/dev/null 2>&1 || { echo 'ERR:install'; exit 12; }
    # valida formato de sources/patches
    for s in \"\${PKG_SOURCES[@]}\"; do
      IFS='|' read -r u a h <<<\"\$s\"
      [[ -n \"\$u\" && -n \"\$a\" && -n \"\$h\" ]] || { echo \"ERR:PKG_SOURCES_FMT:\$s\"; exit 13; }
      [[ \"\$a\" == sha256 || \"\$a\" == md5 ]] || { echo \"ERR:PKG_SOURCES_ALGO:\$s\"; exit 14; }
    done
    if declare -p PKG_PATCHES >/dev/null 2>&1; then
      for p in \"\${PKG_PATCHES[@]}\"; do
        IFS='|' read -r u a h x y <<<\"\$p\"
        [[ -n \"\$u\" && -n \"\$a\" && -n \"\$h\" ]] || { echo \"ERR:PKG_PATCHES_FMT:\$p\"; exit 15; }
        [[ \"\$a\" == sha256 || \"\$a\" == md5 ]] || { echo \"ERR:PKG_PATCHES_ALGO:\$p\"; exit 16; }
      done
    fi
    echo OK
  " 2>/dev/null || true)"

  if [[ "$out" != "OK" ]]; then
    err "lint: falhou validação de metadata/funções em: $rel ($out)"
    return 1
  fi

  info "lint ok: $rel"
  return 0
}

cmd_lint() {
  local failures=0
  if [[ "$LINT_ALL" -eq 1 ]]; then
    info "Lint: verificando todos os scripts em $PKG_SCRIPTS_DIR"
    local s
    while IFS= read -r s; do
      lint_script "$s" || failures=$((failures+1))
    done < <(list_all_build_scripts)
  else
    # lint específico
    local category="${1:-}"
    local name="${2:-}"
    local ver="${3:-}"
    [[ -n "$category" && -n "$name" && -n "$ver" ]] || die "Use: adm lint --all  OU  adm lint <categoria> <programa> <versao>"
    local script; script="$(find_build_script "$category" "$name" "$ver")" || die "Script não encontrado: $category/$name-$ver"
    lint_script "$script" || failures=$((failures+1))
  fi

  if ((failures>0)); then
    die "Lint falhou: $failures erro(s)."
  fi
  info "Lint concluído sem erros."
}

###############################################################################
# Parse de flags globais + flags por comando
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
    *)
      ;;
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
  adm [--dry-run|-n] remove [--prune-dirs] <programa> <versao>
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
# Main
###############################################################################
main() {
  check_tools
  lock_global

  # flags globais
  local args
  args="$(parse_global_flags "$@")"
  # shellcheck disable=SC2206
  set -- $args

  local cmd="${1:-}"
  shift || true

  # flags específicas do comando (remove/doctor/upgrade/lint etc.)
  local rest
  rest="$(parse_cmd_flags "$cmd" "$@")"
  # shellcheck disable=SC2206
  set -- $rest

  case "$cmd" in
    sync)   cmd_sync "$@" ;;
    search) cmd_search "$@" ;;
    info)
      [[ $# -eq 3 ]] || die "Use: adm info <categoria> <programa> <versao>"
      cmd_info "$@"
      ;;
    lint)
      cmd_lint "$@"
      ;;
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
    install)
      [[ $# -eq 3 ]] || die "Use: adm install <categoria> <programa> <versao>"
      install_pkg_from_cache "$@"
      ;;
    remove)
      [[ $# -eq 2 ]] || die "Use: adm remove [--deep] [--prune-dirs] <programa> <versao>"
      cmd_remove "$@"
      ;;
    upgrade)
      cmd_upgrade "$@"
      ;;
    clean)
      cmd_clean
      ;;
    doctor)
      cmd_doctor
      ;;
    ""|help|-h|--help)
      usage
      ;;
    *)
      die "Comando desconhecido: $cmd (use: adm help)"
      ;;
  esac
}

main "$@"
