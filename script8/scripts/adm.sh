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

# ferramentas mínimas
REQUIRED_TOOLS=(bash tar zstd sha256sum md5sum find sed awk grep sort uniq xargs date mkdir rm cp ln readlink)
OPTIONAL_TOOLS=(curl wget git patch)

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
mkdir -p "$STATE_DIR" "$CACHE_DIR" "$LOG_DIR" "$SRC_CACHE" "$BIN_CACHE" "$SUM_CACHE" "$TMP_DIR" "$INST_DB" "$BUILD_DB"

log() { printf '%s %s\n' "$(ts)" "$*" >>"$LOG_FILE"; }
info() { printf '%b\n' "${C_CYAN}${C_BOLD}==>${C_RESET} $*"; log "INFO: $*"; }
warn() { printf '%b\n' "${C_YELLOW}${C_BOLD}WARN:${C_RESET} $*"; log "WARN: $*"; }
err()  { printf '%b\n' "${C_RED}${C_BOLD}ERRO:${C_RESET} $*"; log "ERRO: $*"; }
die()  { err "$*"; exit 1; }

# spinner simples (para etapas que não têm progresso nativo)
SPIN_PID=""
spin_start() {
  local msg="$1"
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
  local missing=()
  for t in "${OPTIONAL_TOOLS[@]}"; do
    have "$t" || missing+=("$t")
  done
  if ((${#missing[@]})); then
    warn "Ferramentas opcionais ausentes (algumas funções podem falhar): ${missing[*]}"
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

mark_installed() {
  local name="$1" ver="$2"
  local mdir; mdir="$(installed_manifest_dir "$name" "$ver")"
  mkdir -p "$mdir"
}

###############################################################################
# Descoberta de scripts de build
###############################################################################
# Formato de script esperado:
#   PKG_NAME="foo"
#   PKG_VERSION="1.2.3"
#   PKG_CATEGORY="base"     (opcional; se não, inferido do path)
#   PKG_DEPENDS=("bar-1.0" "baz-2.1")  (opcional; pode ser vazio)
#   PKG_SOURCES=( "url|sha256|<hex>" "url|md5|<hex>" ... )
#   PKG_PATCHES=( "patch_url_or_path|sha256|<hex>" ... ) (opcional)
#   Hooks opcionais: pre_fetch post_fetch pre_build post_build pre_install post_install
#   Funções obrigatórias (mínimo):
#     build() { ... }        # compila no workdir
#     install() { ... }      # instala em DESTDIR (staging)
#
# O script é "sourced" em ambiente controlado.

find_build_script() {
  local category="$1" name="$2" ver="$3"
  local script="$PKG_SCRIPTS_DIR/$category/${name}-${ver}.sh"
  [[ -f "$script" ]] || return 1
  echo "$script"
}

list_all_build_scripts() {
  find "$PKG_SCRIPTS_DIR" -type f -name '*.sh' 2>/dev/null | sort
}

###############################################################################
# Download com progresso + cache
###############################################################################
cache_key_for_url() {
  # chave baseada na URL para cache (sem depender do nome do arquivo remoto)
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

  mkdir -p "$(dirname "$out")"

  if [[ -f "$out" ]]; then
    return 0
  fi

  # Git
  if [[ "$url" =~ ^git\+ ]]; then
    have git || die "git ausente para baixar: $url"
    local real="${url#git+}"
    spin_start "Clonando (git) ${real}"
    git clone --depth 1 "$real" "$out.tmp"
    mv "$out.tmp" "$out"
    spin_stop 0
    return 0
  fi

  if [[ "$url" =~ \.git$ ]] || [[ "$url" =~ ^git:// ]] ; then
    have git || die "git ausente para baixar: $url"
    spin_start "Clonando (git) ${url}"
    git clone --depth 1 "$url" "$out.tmp"
    mv "$out.tmp" "$out"
    spin_stop 0
    return 0
  fi

  # HTTP/HTTPS/FTP
  if have curl; then
    info "Baixando: $url"
    # barra com porcentagem (curl faz)
    curl -L --fail --retry 3 --retry-delay 1 --progress-bar -o "$out.tmp" "$url"
    mv "$out.tmp" "$out"
    return 0
  elif have wget; then
    info "Baixando: $url"
    wget --tries=3 --progress=bar:force:noscroll -O "$out.tmp" "$url"
    mv "$out.tmp" "$out"
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

  mkdir -p "$SUM_CACHE/$algo"

  local cached; cached="$(sum_cache_path "$algo" "$expected")"
  if [[ -f "$cached" ]]; then
    # já validado antes; ainda assim conferimos que o arquivo atual bate
    :
  fi

  local got=""
  case "$algo" in
    sha256) got="$(sha256sum "$file" | awk '{print $1}')" ;;
    md5)    got="$(md5sum "$file"    | awk '{print $1}')" ;;
    *) die "Algoritmo inválido: $algo (use sha256 ou md5)" ;;
  esac

  if [[ "$got" != "$expected" ]]; then
    die "Checksum inválido para $(basename "$file"): esperado=$expected obtido=$got"
  fi

  # grava cache "este checksum foi validado"
  printf '%s  %s\n' "$got" "$file" >"$cached"
}

###############################################################################
# Hooks externos (opcional) + hooks do script
###############################################################################
run_hook_external() {
  local hook="$1"
  local hook_path="$HOOKS_DIR/$hook"
  if [[ -x "$hook_path" ]]; then
    info "Hook externo: $hook"
    "$hook_path" || die "Hook externo falhou: $hook"
  fi
}

run_hook_function() {
  local hook="$1"
  if declare -F "$hook" >/dev/null 2>&1; then
    info "Hook do pacote: $hook()"
    "$hook" || die "Hook do pacote falhou: $hook"
  fi
}

###############################################################################
# Resolução de dependências com detecção de ciclo
###############################################################################
# Dependências no formato "nome-versao" (ex: zlib-1.3.1)
dep_name() { echo "${1%-*}"; }
dep_ver()  { echo "${1##*-}"; }

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

  # carrega script para ler PKG_DEPENDS (sem executar build/install)
  local script; script="$(find_build_script "$category" "$pkg" "$ver")" || die "Script não encontrado: $category/$pkg-$ver"
  # shellcheck disable=SC1090
  source "$script"

  local deps=("${PKG_DEPENDS[@]:-}")
  for d in "${deps[@]:-}"; do
    local dn dv
    dn="$(dep_name "$d")"
    dv="$(dep_ver "$d")"
    # categoria do dep pode ser diferente; tentamos achar em qualquer categoria:
    local dep_script
    dep_script="$(find_any_category_script "$dn" "$dv")" || die "Dependência não encontrada nos scripts: $d"
    local dep_cat
    dep_cat="$(category_from_script "$dep_script")"
    resolve_deps_dfs "$dep_cat" "$dn" "$dv"
  done

  DEP_VISIT["$key"]=2
  DEP_ORDER+=("$category|$pkg|$ver")
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
  # .../packages/<cat>/name-ver.sh
  local dir; dir="$(dirname "$path")"
  basename "$dir"
}

###############################################################################
# Build pipeline
###############################################################################
build_pkg() {
  local category="$1" name="$2" ver="$3"
  local script; script="$(find_build_script "$category" "$name" "$ver")" || die "Script não encontrado: $category/$name-$ver"

  # sandbox de build
  local id; id="$(pkg_id "$name" "$ver")"
  local work="$TMP_DIR/work-$id"
  local stage="$TMP_DIR/stage-$id"
  local meta="$BUILD_DB/$id"
  rm -rf "$work" "$stage"
  mkdir -p "$work" "$stage" "$meta"

  # carrega script do pacote
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
  mkdir -p "$work/sources"
  local src_entry
  for src_entry in "${PKG_SOURCES[@]}"; do
    IFS='|' read -r url algo hex <<<"$src_entry"
    [[ -n "${url:-}" && -n "${algo:-}" && -n "${hex:-}" ]] || die "Entrada inválida em PKG_SOURCES: $src_entry"

    local key; key="$(cache_key_for_url "$url")"
    local fname; fname="$(filename_from_url "$url")"
    local target="$SRC_CACHE/${key}-${fname}"

    download_one "$url" "$target"
    verify_checksum "$target" "$algo" "$hex"
    ln -sf "$target" "$work/sources/$fname"
  done

  run_hook_external "post_fetch"
  run_hook_function "post_fetch"

  # Patches (opcional)
  if ((${#PKG_PATCHES[@]:-0})); then
    have patch || die "patch ausente para aplicar PKG_PATCHES"
    mkdir -p "$work/patches"
    for src_entry in "${PKG_PATCHES[@]}"; do
      IFS='|' read -r purl palgo phex <<<"$src_entry"
      [[ -n "${purl:-}" && -n "${palgo:-}" && -n "${phex:-}" ]] || die "Entrada inválida em PKG_PATCHES: $src_entry"

      local pkey; pkey="$(cache_key_for_url "$purl")"
      local pf; pf="$(filename_from_url "$purl")"
      local ptarget="$SRC_CACHE/${pkey}-${pf}"

      download_one "$purl" "$ptarget"
      verify_checksum "$ptarget" "$palgo" "$phex"
      cp -f "$ptarget" "$work/patches/$pf"
    done
  fi

  run_hook_external "pre_build"
  run_hook_function "pre_build"

  # Build
  info "Construindo: $PKG_NAME-$PKG_VERSION ($category)"
  ( cd "$work" && build )

  run_hook_external "post_build"
  run_hook_function "post_build"

  # Install into staging
  run_hook_external "pre_install"
  run_hook_function "pre_install"

  info "Instalando em staging: $stage"
  ( cd "$work" && install )

  run_hook_external "post_install"
  run_hook_function "post_install"

  # Empacotar tar.zst
  local pkgfile="$BIN_CACHE/${id}.tar.zst"
  info "Empacotando: $(basename "$pkgfile")"
  rm -f "$pkgfile"
  ( cd "$stage" && tar --numeric-owner --xattrs --acls -cf - . ) \
    | zstd -T0 -19 --long=31 -o "$pkgfile"

  # registrar build
  {
    echo "name=$PKG_NAME"
    echo "version=$PKG_VERSION"
    echo "category=$category"
    echo "built_at=$(ts)"
    echo "pkgfile=$pkgfile"
    echo "script=$script"
  } >"$meta/build.info"

  info "Build concluído: $id"
}

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

  # Carrega script para deps/metadata
  local script; script="$(find_build_script "$category" "$name" "$ver")" || die "Script não encontrado: $category/$name-$ver"
  # shellcheck disable=SC1090
  source "$script"
  local deps=("${PKG_DEPENDS[@]:-}")

  # instala deps antes (apenas se houver binário em cache ou script disponível)
  for d in "${deps[@]:-}"; do
    local dn dv
    dn="$(dep_name "$d")"
    dv="$(dep_ver "$d")"
    local dep_script; dep_script="$(find_any_category_script "$dn" "$dv")" || die "Dependência sem script: $d"
    local dep_cat; dep_cat="$(category_from_script "$dep_script")"

    if ! is_installed "$dn" "$dv"; then
      local dep_id; dep_id="$(pkg_id "$dn" "$dv")"
      if [[ -f "$BIN_CACHE/${dep_id}.tar.zst" ]]; then
        install_pkg_from_cache "$dep_cat" "$dn" "$dv"
      else
        # build + install
        build_pkg "$dep_cat" "$dn" "$dv"
        install_pkg_from_cache "$dep_cat" "$dn" "$dv"
      fi
    fi
  done

  info "Instalando do cache: $id"
  # extrai e registra manifesto (lista de arquivos)
  local mdir; mdir="$(installed_manifest_dir "$name" "$ver")"
  mkdir -p "$mdir"
  local files_list="$mdir/files.txt"
  : >"$files_list"

  # extrair para /
  # registrando arquivos (tar -t) antes e depois: aqui guardamos lista do tar.
  zstd -dc "$pkgfile" | tar -tf - >"$files_list"
  zstd -dc "$pkgfile" | tar --xattrs --acls -xpf - -C /

  # metadados
  {
    echo "name=$name"
    echo "version=$ver"
    echo "category=$category"
    echo "installed_at=$(ts)"
    echo "pkgfile=$pkgfile"
    echo "deps=${deps[*]:-}"
    echo "script=$script"
  } >"$mdir/manifest.info"

  info "Instalado: $id"
}

remove_pkg() {
  need_root
  local name="$1" ver="$2"
  local id; id="$(pkg_id "$name" "$ver")"
  local mdir; mdir="$(installed_manifest_dir "$name" "$ver")"
  [[ -d "$mdir" ]] || die "Não instalado: $id"

  # impede remoção se outro pacote depende dele (simples)
  local rdep=()
  local mf
  for mf in "$INST_DB"/*/manifest.info; do
    [[ -f "$mf" ]] || continue
    local deps
    deps="$(grep -E '^deps=' "$mf" | cut -d= -f2- || true)"
    if grep -qw "$id" <<<"$deps"; then
      rdep+=("$(basename "$(dirname "$mf")")")
    fi
  done
  if ((${#rdep[@]})); then
    die "Remoção bloqueada: pacotes dependem de $id: ${rdep[*]}"
  fi

  info "Removendo: $id"
  local files="$mdir/files.txt"
  [[ -f "$files" ]] || die "Manifesto de arquivos ausente: $files"

  # remover em ordem reversa para tentar limpar diretórios depois
  tac "$files" | while IFS= read -r f; do
    # caminhos no tar são relativos; instalamos em /
    local abs="/$f"
    # nunca remover raiz/vazios
    [[ "$abs" == "/" || -z "$f" ]] && continue
    if [[ -e "$abs" || -L "$abs" ]]; then
      rm -f "$abs" || true
    fi
  done

  # tentar remover diretórios vazios (apenas os que aparecem no manifesto)
  tac "$files" | while IFS= read -r f; do
    local abs="/$f"
    if [[ -d "$abs" ]]; then
      rmdir "$abs" 2>/dev/null || true
    fi
  done

  rm -rf "$mdir"
  info "Removido: $id"
}

###############################################################################
# Search / Info
###############################################################################
cmd_search() {
  local needle="${1:-}"
  [[ -n "$needle" ]] || die "Use: admpkg search <termo>"

  local found=0
  while IFS= read -r s; do
    local cat; cat="$(category_from_script "$s")"
    local base; base="$(basename "$s" .sh)"
    local name="${base%-*}"
    local ver="${base##*-}"

    if [[ "$base" =~ $needle ]] || [[ "$name" =~ $needle ]] || [[ "$cat" =~ $needle ]]; then
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
    printf '%b\n' "Instalado em: $(grep -E '^installed_at=' "$mdir/manifest.info" | cut -d= -f2-)"
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
    rm -rf "$PKG_SCRIPTS_DIR"
    mkdir -p "$(dirname "$PKG_SCRIPTS_DIR")"
    git clone -b "$SYNC_BRANCH" "$SYNC_REPO_URL" "$PKG_SCRIPTS_DIR"
  else
    info "Atualizando repo de scripts: $PKG_SCRIPTS_DIR"
    ( cd "$PKG_SCRIPTS_DIR" && git fetch --all --prune && git checkout "$SYNC_BRANCH" && git pull --ff-only )
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
  find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 -print -exec rm -rf {} + 2>/dev/null || true

  # 2) remove binários de versões não instaladas e sem build.info recente (>30 dias)
  find "$BIN_CACHE" -type f -name '*.tar.zst' -mtime +30 | while IFS= read -r f; do
    local base; base="$(basename "$f" .tar.zst)"
    local m="$INST_DB/$base"
    if [[ ! -d "$m" ]]; then
      rm -f "$f" || true
    fi
  done

  # 3) remove checksums cache órfão (opcional, conservador: >90 dias)
  find "$SUM_CACHE" -type f -mtime +90 -exec rm -f {} + 2>/dev/null || true

  info "Clean concluído."
}

###############################################################################
# Doctor: verificação e correção
###############################################################################
cmd_doctor() {
  need_root
  info "Doctor: analisando integridade"

  local issues=0

  # 1) manifestos sem files.txt
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
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local abs="/$f"
      if [[ ! -e "$abs" && ! -L "$abs" ]]; then
        ((missing++))
      fi
    done <"$fl"
    if ((missing>0)); then
      warn "$id: $missing arquivos ausentes (sugestão: rebuild + reinstall)"
      ((issues++))
    fi
  done

  # 3) deps inconsistentes (dependência não instalada)
  local mf
  for mf in "$INST_DB"/*/manifest.info; do
    [[ -f "$mf" ]] || continue
    local id; id="$(basename "$(dirname "$mf")")"
    local deps; deps="$(grep -E '^deps=' "$mf" | cut -d= -f2- || true)"
    for dep in $deps; do
      [[ -z "$dep" ]] && continue
      if [[ ! -d "$INST_DB/$dep" ]]; then
        warn "$id depende de $dep, mas $dep não está instalado (sugestão: instalar dep)"
        ((issues++))
      fi
    done
  done

  if ((issues==0)); then
    info "Doctor: nenhuma anomalia detectada."
    return 0
  fi

  warn "Doctor: $issues problema(s) identificado(s). Correção automática é conservadora."
  warn "A correção recomendada para arquivos ausentes é rebuild + reinstall do pacote."
}

###############################################################################
# Comando principal
###############################################################################
usage() {
  cat <<EOF
adm - gerenciador de pacotes (LFS-style)

Uso:
  adm sync
  adm search <termo>
  adm info <categoria> <programa> <versao>
  adm build <categoria> <programa> <versao>
  adm install <categoria> <programa> <versao>   (instala do cache; faz deps)
  adm remove <programa> <versao>
  adm clean
  adm doctor

Variáveis úteis (export):
  ADM_ROOT, PKG_SCRIPTS_DIR, STATE_DIR, CACHE_DIR, LOG_DIR
  SYNC_REPO_URL, SYNC_BRANCH
EOF
}

main() {
  check_tools
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    sync)   cmd_sync "$@" ;;
    search) cmd_search "$@" ;;
    info)   [[ $# -eq 3 ]] || die "Use: adm info <categoria> <programa> <versao>"
            cmd_info "$@" ;;
    build)  [[ $# -eq 3 ]] || die "Use: adm build <categoria> <programa> <versao>"
            # resolve deps e build em ordem
            DEP_VISIT=(); DEP_ORDER=()
            resolve_deps_dfs "$1" "$2" "$3"
            local item
            for item in "${DEP_ORDER[@]}"; do
              IFS='|' read -r c n v <<<"$item"
              local id; id="$(pkg_id "$n" "$v")"
              # se binário já existe, pula build para economizar
              if [[ -f "$BIN_CACHE/${id}.tar.zst" ]]; then
                info "Cache binário já existe, pulando build: $id"
              else
                build_pkg "$c" "$n" "$v"
              fi
            done
            ;;
    install) [[ $# -eq 3 ]] || die "Use: adm install <categoria> <programa> <versao>"
             install_pkg_from_cache "$@" ;;
    remove)  [[ $# -eq 2 ]] || die "Use: adm remove <programa> <versao>"
             remove_pkg "$@" ;;
    clean)   cmd_clean ;;
    doctor)  cmd_doctor ;;
    ""|help|-h|--help) usage ;;
    *) die "Comando desconhecido: $cmd (use: adm help)" ;;
  esac
}

main "$@"
