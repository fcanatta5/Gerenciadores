#!/usr/bin/env bash
# adm.sh - ADM: source-based package manager for custom Linux-from-scratch style systems
# Root default: /opt/adm
# Requirements: bash 4+, coreutils, findutils, tar, rsync, curl, patch, (sha256sum/md5sum as needed), git (for repos)
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# ----------------- global config -----------------
ADM_ROOT="${ADM_ROOT:-/opt/adm}"

ADM_BIN="$ADM_ROOT/bin"
ADM_REPOS="$ADM_ROOT/repos"
ADM_PKGS="$ADM_ROOT/pkgs"                 # local overlay
ADM_CACHE="$ADM_ROOT/cache"
ADM_SRC_CACHE="$ADM_CACHE/sources"
ADM_BIN_CACHE="$ADM_CACHE/bin"
ADM_BUILD_ROOT="$ADM_CACHE/build"
ADM_DB="$ADM_ROOT/db"
ADM_LOG="$ADM_ROOT/logs"
ADM_STATE="$ADM_ROOT/state"
ADM_LOCK="$ADM_ROOT/lock"

ADM_ROOTFS_BASE="$ADM_ROOT/rootfs"
ADM_PROFILES="$ADM_ROOT/profiles"

ADM_JOBS="${ADM_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
ADM_FETCH_JOBS="${ADM_FETCH_JOBS:-4}"
ADM_COLOR="${ADM_COLOR:-1}"
ADM_RESUME_DEFAULT="${ADM_RESUME_DEFAULT:-1}"

# ----------------- UI -----------------
if [[ "${ADM_COLOR}" == "1" && -t 2 ]]; then
  _bold=$'\033[1m'; _dim=$'\033[2m'; _rst=$'\033[0m'
  _red=$'\033[31m'; _grn=$'\033[32m'; _ylw=$'\033[33m'; _blu=$'\033[34m'; _mag=$'\033[35m'; _cyn=$'\033[36m'
else
  _bold=""; _dim=""; _rst=""
  _red=""; _grn=""; _ylw=""; _blu=""; _mag=""; _cyn=""
fi

NOW() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

die()  { echo "${_red}${_bold}ERRO${_rst}: $*" >&2; exit 1; }
warn() { echo "${_ylw}${_bold}AVISO${_rst}: $*" >&2; }
info() { echo "${_cyn}${_bold}INFO${_rst}: $*" >&2; }
ok()   { echo "${_grn}${_bold}OK${_rst}: $*" >&2; }

pkgline() {
  local n="$1" v="${2:-}"
  if [[ -n "$v" ]]; then
    echo "${_bold}${_mag}${n}-${v}${_rst}"
  else
    echo "${_bold}${_mag}${n}${_rst}"
  fi
}

# ----------------- logging & error handling -----------------
LOG_FILE=""
log_init() {
  local rootfs="$1" profile="$2" pkg="$3" ver="$4"
  mkdir -p "$ADM_LOG/$rootfs/$profile"
  LOG_FILE="$ADM_LOG/$rootfs/$profile/${pkg}-${ver}-$(date +%Y%m%d_%H%M%S).log"
  : >"$LOG_FILE"
}

log() { [[ -n "${LOG_FILE:-}" ]] && echo "[$(NOW)] $*" >>"$LOG_FILE"; }

run() {
  # Run command; log stdout+stderr; on failure print concise error and exit.
  log "+ $*"
  if ! "$@" >>"$LOG_FILE" 2>&1; then
    echo "${_red}${_bold}FALHA${_rst}: comando retornou erro. Veja o log: ${_bold}${LOG_FILE:-"(sem log)"}${_rst}" >&2
    echo "  Comando: $*" >&2
    exit 1
  fi
}

on_err() {
  local ec=$?
  echo "${_red}${_bold}FALHA${_rst}: erro inesperado (exit=$ec). Log: ${_bold}${LOG_FILE:-"(sem log)"}${_rst}" >&2
  exit "$ec"
}
trap on_err ERR

need() { command -v "$1" >/dev/null 2>&1 || die "Dependência ausente: $1"; }

# ----------------- layout / locking -----------------
ensure_layout() {
  mkdir -p \
    "$ADM_BIN" "$ADM_REPOS" "$ADM_PKGS" \
    "$ADM_SRC_CACHE" "$ADM_BIN_CACHE" "$ADM_BUILD_ROOT" \
    "$ADM_DB" "$ADM_LOG" "$ADM_STATE" "$ADM_LOCK" \
    "$ADM_ROOTFS_BASE" "$ADM_PROFILES"
}

lock_acquire() {
  ensure_layout
  local name="${1:-global}"
  local lockdir="$ADM_LOCK/$name"
  if mkdir "$lockdir" 2>/dev/null; then
    echo "$$" >"$lockdir/pid"
    trap "rm -rf '$lockdir' 2>/dev/null || true" EXIT
  else
    local pid="?"
    pid="$(cat "$lockdir/pid" 2>/dev/null || echo '?')"
    die "Lock ocupado ($name). PID: $pid"
  fi
}

# ----------------- state: current context -----------------
state_set_current() {
  printf '%s\n' "$1" >"$ADM_STATE/current.rootfs"
  printf '%s\n' "$2" >"$ADM_STATE/current.libc"
  printf '%s\n' "$3" >"$ADM_STATE/current.profile"
}
state_get_current() {
  local r l p
  r="$(cat "$ADM_STATE/current.rootfs" 2>/dev/null || true)"
  l="$(cat "$ADM_STATE/current.libc" 2>/dev/null || true)"
  p="$(cat "$ADM_STATE/current.profile" 2>/dev/null || true)"
  [[ -n "$r" && -n "$l" && -n "$p" ]] || return 1
  printf '%s\n' "$r" "$l" "$p"
}

require_rootfs() {
  local rootfs="$1"
  [[ -n "$rootfs" ]] || die "Rootfs não informado."
  [[ -d "$ADM_ROOTFS_BASE/$rootfs" ]] || die "Rootfs inexistente: $ADM_ROOTFS_BASE/$rootfs (use: adm rootfs-create <nome>)"
}

profile_path() {
  local rootfs="$1" libc="$2" prof="$3"
  echo "$ADM_PROFILES/$rootfs/$libc/$prof.env"
}

load_profile() {
  local rootfs="$1" libc="$2" prof="$3"
  local pfile; pfile="$(profile_path "$rootfs" "$libc" "$prof")"
  [[ -f "$pfile" ]] || die "Profile não encontrado: $pfile"
  # shellcheck disable=SC1090
  source "$pfile"
  [[ "${ADM_PROFILE_KIND:-}" == "$libc" ]] || die "Profile inválido: ADM_PROFILE_KIND não confere (esperado $libc)"
}

# ----------------- recipes -----------------
# Recipe (bash) must define:
#   PKG_NAME, PKG_VERSION, PKG_DESC
# Optional:
#   PKG_HOMEPAGE, PKG_LICENSE
# Sources (choose one style):
#   A) PKG_SRC_URL="..." and optional PKG_SRC_SHA256 / PKG_SRC_MD5
#   B) PKG_SRC_URLS=( "url1" "url2" ) and optional PKG_SRC_SHA256S=(..), PKG_SRC_MD5S=(..)
#   C) PKG_SOURCES=( "url|sha256|md5" ... )   # recommended for multiple
# Dependencies:
#   PKG_DEPS=( ... )        # runtime deps (also built before)
#   PKG_BUILD_DEPS=( ... )  # build-only deps (built before)
# Hooks (optional functions):
#   pre_fetch post_fetch pre_patch post_patch pre_configure post_configure pre_build post_build pre_install post_install
#   pre_remove post_remove
# Build functions (optional; defaults provided):
#   pkg_unpack (default: tar -xf)
#   pkg_configure (default: ./configure --prefix=...)
#   pkg_build (default: make -j)
#   pkg_install (default: make DESTDIR= install)
# Notes:
#   Use $ADM_ROOTFS (rootfs path), $DESTDIR, $ADM_TOOLS_PREFIX (when profile kind=tools)

find_recipe() {
  local name="$1"
  local f
  if [[ -f "$ADM_PKGS/$name/recipe.sh" ]]; then
    echo "$ADM_PKGS/$name/recipe.sh"; return 0
  fi
  while IFS= read -r -d '' f; do
    echo "$f"; return 0
  done < <(find "$ADM_REPOS" -mindepth 3 -maxdepth 3 -type f -path "*/pkgs/$name/recipe.sh" -print0 2>/dev/null || true)
  return 1
}

# Reset vars and functions between recipes to prevent leakage
_reset_recipe_env() {
  unset PKG_NAME PKG_VERSION PKG_DESC PKG_HOMEPAGE PKG_LICENSE
  unset PKG_SRC_URL PKG_SRC_SHA256 PKG_SRC_MD5 PKG_PATCHES_DIR
  unset PKG_SRC_URLS PKG_SRC_SHA256S PKG_SRC_MD5S PKG_SOURCES
  unset PKG_DEPS PKG_BUILD_DEPS
  for fn in \
    pre_fetch post_fetch pre_patch post_patch pre_configure post_configure pre_build post_build pre_install post_install \
    pre_remove post_remove \
    pkg_unpack pkg_configure pkg_build pkg_install; do
    unset -f "$fn" 2>/dev/null || true
  done
}

load_recipe() {
  local recipe="$1"
  [[ -f "$recipe" ]] || die "Recipe inexistente: $recipe"
  _reset_recipe_env
  # shellcheck disable=SC1090
  source "$recipe"

  [[ -n "${PKG_NAME:-}" && -n "${PKG_VERSION:-}" && -n "${PKG_DESC:-}" ]] || die "Recipe inválido: faltam PKG_NAME/PKG_VERSION/PKG_DESC"

  local have_sources=0
  [[ -n "${PKG_SRC_URL:-}" ]] && have_sources=1
  [[ "${#PKG_SRC_URLS[@]:-0}" -gt 0 ]] && have_sources=1
  [[ "${#PKG_SOURCES[@]:-0}" -gt 0 ]] && have_sources=1
  [[ "$have_sources" -eq 1 ]] || die "Recipe inválido: defina fontes (PKG_SRC_URL / PKG_SRC_URLS / PKG_SOURCES)."

  local rdir; rdir="$(cd "$(dirname "$recipe")" && pwd -P)"
  if [[ -z "${PKG_PATCHES_DIR:-}" ]]; then
    PKG_PATCHES_DIR="$rdir/patches"
  fi

  # safe defaults
  if ! declare -F pkg_unpack >/dev/null 2>&1; then
    pkg_unpack() { run tar -xf "$1" -C "$2"; }
  fi
  if ! declare -F pkg_configure >/dev/null 2>&1; then
    pkg_configure() { [[ -x "./configure" ]] && run ./configure --prefix="${ADM_PREFIX:-/usr}" || true; }
  fi
  if ! declare -F pkg_build >/dev/null 2>&1; then
    pkg_build() { run make -j"${MAKEJOBS:-$ADM_JOBS}"; }
  fi
  if ! declare -F pkg_install >/dev/null 2>&1; then
    pkg_install() { run make DESTDIR="$DESTDIR" install; }
  fi
}

call_hook() {
  local fn="$1"
  if declare -F "$fn" >/dev/null 2>&1; then
    log "hook: $fn"
    "$fn"
  fi
}

# ----------------- dependency graph (cycle detection) -----------------
# Outputs: global arrays PLAN_ORDER (topological order) and PLAN_WANTS (unique pkgs)
declare -a PLAN_ORDER=()
declare -A _dep_state=()   # 0=unseen,1=visiting,2=done
declare -A _dep_parent=()
declare -A PLAN_WANTS=()

_recipe_deps_of() {
  # echo deps (build deps then runtime deps)
  local pkg="$1"
  local recipe; recipe="$(find_recipe "$pkg")" || die "Pacote não encontrado: $pkg"
  load_recipe "$recipe"
  local d=()
  if [[ "${#PKG_BUILD_DEPS[@]:-0}" -gt 0 ]]; then d+=("${PKG_BUILD_DEPS[@]}"); fi
  if [[ "${#PKG_DEPS[@]:-0}" -gt 0 ]]; then d+=("${PKG_DEPS[@]}"); fi
  printf '%s\n' "${d[@]:-}"
}

_dep_dfs() {
  local pkg="$1"
  local st="${_dep_state[$pkg]:-0}"
  if [[ "$st" == "2" ]]; then return 0; fi
  if [[ "$st" == "1" ]]; then
    # cycle: reconstruct path
    local cycle=("$pkg")
    local cur="$pkg"
    while [[ -n "${_dep_parent[$cur]:-}" ]]; do
      cur="${_dep_parent[$cur]}"
      cycle+=("$cur")
      [[ "$cur" == "$pkg" ]] && break
    done
    die "Ciclo de dependência detectado: ${cycle[*]}"
  fi

  _dep_state["$pkg"]="1"
  local dep
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    _dep_parent["$dep"]="$pkg"
    _dep_dfs "$dep"
  done < <(_recipe_deps_of "$pkg" || true)

  _dep_state["$pkg"]="2"
  PLAN_ORDER+=("$pkg")
  PLAN_WANTS["$pkg"]=1
}

plan_resolve() {
  local pkgs=("$@")
  PLAN_ORDER=()
  _dep_state=()
  _dep_parent=()
  PLAN_WANTS=()

  local p
  for p in "${pkgs[@]}"; do
    [[ -n "$p" ]] || continue
    _dep_dfs "$p"
  done
  # PLAN_ORDER is deps-first already (postorder)
}

# ----------------- hashing helpers -----------------
_hash_sha256() { sha256sum "$1" | awk '{print $1}'; }
_hash_md5()    { md5sum "$1" | awk '{print $1}'; }

_verify_file_hashes() {
  local file="$1" want_sha="${2:-}" want_md5="${3:-}"
  local ok=1
  if [[ -n "$want_sha" ]]; then
    need sha256sum
    local got; got="$(_hash_sha256 "$file")"
    [[ "$got" == "$want_sha" ]] || ok=0
  fi
  if [[ -n "$want_md5" ]]; then
    need md5sum
    local got; got="$(_hash_md5 "$file")"
    [[ "$got" == "$want_md5" ]] || ok=0
  fi
  [[ "$ok" -eq 1 ]]
}

# ----------------- fetch (with cache + hash gating + parallel) -----------------
# Normalizes sources to lines: "url|sha256|md5"
_sources_normalized() {
  local out=()
  if [[ "${#PKG_SOURCES[@]:-0}" -gt 0 ]]; then
    out+=("${PKG_SOURCES[@]}")
  elif [[ -n "${PKG_SRC_URL:-}" ]]; then
    out+=("${PKG_SRC_URL}|${PKG_SRC_SHA256:-}|${PKG_SRC_MD5:-}")
  else
    local i
    for i in "${!PKG_SRC_URLS[@]}"; do
      out+=("${PKG_SRC_URLS[$i]}|${PKG_SRC_SHA256S[$i]:-}|${PKG_SRC_MD5S[$i]:-}")
    done
  fi
  printf '%s\n' "${out[@]}"
}

_fetch_one() {
  local spec="$1" outdir="$2"
  local url sha md5 file cachefile
  IFS='|' read -r url sha md5 <<<"$spec"
  [[ -n "$url" ]] || die "Fonte inválida (vazia)."
  file="${url##*/}"
  [[ -n "$file" ]] || die "URL inválida: $url"
  cachefile="$ADM_SRC_CACHE/$file"
  mkdir -p "$ADM_SRC_CACHE" "$outdir"

  if [[ -f "$cachefile" ]]; then
    if _verify_file_hashes "$cachefile" "$sha" "$md5"; then
      log "cache ok: $file"
    else
      warn "cache corrompido/inesperado: $file (rebaixando)"
      rm -f "$cachefile" 2>/dev/null || true
    fi
  fi

  if [[ ! -f "$cachefile" ]]; then
    need curl
    log "download: $url -> $cachefile"
    run curl -L --fail --retry 4 --connect-timeout 15 -o "$cachefile.part" "$url"
    run mv -f "$cachefile.part" "$cachefile"
    if [[ -n "$sha" || -n "$md5" ]]; then
      _verify_file_hashes "$cachefile" "$sha" "$md5" || die "Hash não confere para $file"
    else
      warn "Sem hash definido para $file (recomendado sha256/md5)."
    fi
  fi

  run cp -f "$cachefile" "$outdir/$file"
}

fetch_sources() {
  local outdir="$1"
  mkdir -p "$outdir"
  local specs=()
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    specs+=("$s")
  done < <(_sources_normalized)

  [[ "${#specs[@]}" -gt 0 ]] || die "Nenhuma fonte para baixar."

  # parallel fetch of sources of one recipe
  if [[ "${#specs[@]}" -gt 1 && "${ADM_FETCH_JOBS}" -gt 1 ]]; then
    local pids=() i=0
    for s in "${specs[@]}"; do
      ( _fetch_one "$s" "$outdir" ) &
      pids+=("$!")
      ((i++))
      if (( i % ADM_FETCH_JOBS == 0 )); then
        for pid in "${pids[@]}"; do wait "$pid"; done
        pids=()
      fi
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
  else
    local s
    for s in "${specs[@]}"; do
      _fetch_one "$s" "$outdir"
    done
  fi
}

# ----------------- extract / patch -----------------
extract_sources() {
  # Extract the first archive found in srcdir to builddir, return detected top dir.
  local srcdir="$1" builddir="$2"
  mkdir -p "$builddir"
  local archive
  archive="$(ls -1 "$srcdir"/* 2>/dev/null | head -n1 || true)"
  [[ -f "$archive" ]] || die "Nenhum archive encontrado em $srcdir"
  info "extraindo: $(basename "$archive")"
  pkg_unpack "$archive" "$builddir"
  local top
  top="$(find "$builddir" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
  [[ -n "$top" ]] || die "Falha ao detectar diretório extraído em $builddir"
  echo "$top"
}

apply_patches() {
  local workdir="$1"
  [[ -d "$PKG_PATCHES_DIR" ]] || return 0
  need patch
  shopt -s nullglob
  local patches=("$PKG_PATCHES_DIR"/*.patch "$PKG_PATCHES_DIR"/*.diff)
  shopt -u nullglob
  [[ "${#patches[@]}" -gt 0 ]] || return 0
  info "aplicando patches: ${#patches[@]}"
  local p
  for p in "${patches[@]}"; do
    info "patch: $(basename "$p")"
    ( cd "$workdir" && run patch -p1 <"$p" )
  done
}

# ----------------- db / installed tracking -----------------
db_installed_dir() { local rootfs="$1" profile="$2"; echo "$ADM_DB/$rootfs/$profile/installed"; }
db_pkg_dir() { local rootfs="$1" profile="$2" pkg="$3"; echo "$(db_installed_dir "$rootfs" "$profile")/$pkg"; }

is_installed() {
  local rootfs="$1" profile="$2" pkg="$3"
  [[ -d "$(db_pkg_dir "$rootfs" "$profile" "$pkg")" ]]
}

installed_version() {
  local rootfs="$1" profile="$2" pkg="$3"
  cat "$(db_pkg_dir "$rootfs" "$profile" "$pkg")/version" 2>/dev/null || true
}

record_install() {
  local rootfs="$1" profile="$2" pkg="$3" ver="$4" manifest="$5" depsfile="$6" kind="$7" libc="$8"
  local d; d="$(db_pkg_dir "$rootfs" "$profile" "$pkg")"
  mkdir -p "$d"
  printf '%s\n' "$pkg" >"$d/name"
  printf '%s\n' "$ver" >"$d/version"
  printf '%s\n' "$(NOW)" >"$d/installed_at"
  printf '%s\n' "$profile" >"$d/profile"
  printf '%s\n' "$kind" >"$d/profile_kind"
  printf '%s\n' "$libc" >"$d/libc"
  cp -f "$manifest" "$d/manifest"
  cp -f "$depsfile" "$d/deps"
}

# reverse-deps (derived on demand)
dependents_of() {
  local rootfs="$1" profile="$2" target="$3"
  local instdir; instdir="$(db_installed_dir "$rootfs" "$profile")"
  [[ -d "$instdir" ]] || return 0
  local pkg
  for pkg in "$instdir"/*; do
    [[ -d "$pkg" ]] || continue
    if grep -qxF "$target" "$pkg/deps" 2>/dev/null; then
      basename "$pkg"
    fi
  done
}

# ----------------- resume markers -----------------
step_done() { [[ -f "$1/.step.$2" ]]; }
step_mark() { : >"$1/.step.$2"; }

# ----------------- build/install -----------------
build_and_install_one() {
  local rootfs="$1" libc="$2" profile="$3" pkg="$4" resume="${5:-$ADM_RESUME_DEFAULT}"
  require_rootfs "$rootfs"

  local recipe; recipe="$(find_recipe "$pkg")" || die "Pacote não encontrado: $pkg"
  load_profile "$rootfs" "$libc" "$profile"
  load_recipe "$recipe"

  log_init "$rootfs" "$profile" "$PKG_NAME" "$PKG_VERSION"
  info ">> $(pkgline "$PKG_NAME" "$PKG_VERSION")  rootfs=${_bold}$rootfs${_rst}  kind=${_bold}${ADM_PROFILE_KIND}${_rst}  profile=${_bold}$profile${_rst}"
  log "recipe: $recipe"

  local rootfs_dir="$ADM_ROOTFS_BASE/$rootfs"
  local kind="${ADM_PROFILE_KIND}"
  local pkg_build_id="${PKG_NAME}-${PKG_VERSION}-${rootfs}-${kind}-${profile}"
  local workbase="$ADM_BUILD_ROOT/$pkg_build_id"
  local srcwork="$workbase/src"
  local buildwork="$workbase/build"
  local destdir="$workbase/dest"
  local manifest="$workbase/manifest.txt"
  local depsfile="$workbase/deps.txt"

  if [[ "$resume" != "1" ]]; then
    rm -rf "$workbase"
  fi
  mkdir -p "$srcwork" "$buildwork" "$destdir"

  mkdir -p "$rootfs_dir"/{usr,bin,sbin,lib,lib64,etc,var,run,tmp,opt} 2>/dev/null || true
  mkdir -p "$rootfs_dir/tools" 2>/dev/null || true

  export ADM_ROOTFS="$rootfs_dir"
  export ADM_PROFILE="$profile"
  export ADM_PROFILE_KIND="$kind"
  export ADM_LIBC="$libc"
  export MAKEJOBS="${MAKEJOBS:-$ADM_JOBS}"

  if [[ "$kind" == "tools" ]]; then
    export ADM_TOOLS_PREFIX="/tools"
    export ADM_PREFIX="/tools"
  else
    export ADM_TOOLS_PREFIX="/tools"
    export ADM_PREFIX="/usr"
  fi

  : >"$depsfile"
  if [[ "${#PKG_BUILD_DEPS[@]:-0}" -gt 0 ]]; then printf '%s\n' "${PKG_BUILD_DEPS[@]}" >>"$depsfile"; fi
  if [[ "${#PKG_DEPS[@]:-0}" -gt 0 ]]; then printf '%s\n' "${PKG_DEPS[@]}" >>"$depsfile"; fi
  sort -u -o "$depsfile" "$depsfile" 2>/dev/null || true

  if ! step_done "$workbase" "fetch"; then
    call_hook pre_fetch
    fetch_sources "$srcwork"
    call_hook post_fetch
    step_mark "$workbase" "fetch"
  fi

  if ! step_done "$workbase" "extract"; then
    rm -rf "$buildwork"/* "$destdir"/* 2>/dev/null || true
    local workdir
    workdir="$(extract_sources "$srcwork" "$buildwork")"
    echo "$workdir" >"$workbase/workdir.path"
    step_mark "$workbase" "extract"
  fi

  local workdir
  workdir="$(cat "$workbase/workdir.path" 2>/dev/null || true)"
  [[ -n "$workdir" && -d "$workdir" ]] || die "Diretório de trabalho inválido (resume corrompido?): $workdir"

  if ! step_done "$workbase" "patch"; then
    call_hook pre_patch
    apply_patches "$workdir"
    call_hook post_patch
    step_mark "$workbase" "patch"
  fi

  if ! step_done "$workbase" "configure"; then
    call_hook pre_configure
    ( cd "$workdir" && pkg_configure )
    call_hook post_configure
    step_mark "$workbase" "configure"
  fi

  if ! step_done "$workbase" "build"; then
    call_hook pre_build
    ( cd "$workdir" && pkg_build )
    call_hook post_build
    step_mark "$workbase" "build"
  fi

  if ! step_done "$workbase" "stage"; then
    export DESTDIR="$destdir"
    rm -rf "$destdir"/* 2>/dev/null || true
    call_hook pre_install
    ( cd "$workdir" && pkg_install )
    call_hook post_install
    step_mark "$workbase" "stage"
  fi

  if ! step_done "$workbase" "manifest"; then
    need find
    ( cd "$destdir" && find . -type f -o -type l ) | sed 's|^\./||' >"$manifest"
    step_mark "$workbase" "manifest"
  fi

  if ! step_done "$workbase" "artifact"; then
    local bcache_dir="$ADM_BIN_CACHE/$PKG_NAME/$PKG_VERSION/$rootfs/$kind/$profile"
    mkdir -p "$bcache_dir"
    local artifact="$bcache_dir/${PKG_NAME}-${PKG_VERSION}.tar.zst"
    if command -v zstd >/dev/null 2>&1; then
      run tar -C "$destdir" -cf - . | zstd -T0 -q -o "$artifact"
    else
      artifact="$bcache_dir/${PKG_NAME}-${PKG_VERSION}.tar.gz"
      run tar -C "$destdir" -czf "$artifact" .
    fi
    info "artefato em cache: $artifact"
    step_mark "$workbase" "artifact"
  fi

  if ! step_done "$workbase" "install"; then
    need rsync
    info "instalando em rootfs: $rootfs_dir"
    run rsync -a --delete-after "$destdir"/ "$rootfs_dir"/
    step_mark "$workbase" "install"
  fi

  if ! step_done "$workbase" "record"; then
    record_install "$rootfs" "$profile" "$PKG_NAME" "$PKG_VERSION" "$manifest" "$depsfile" "$kind" "$libc"
    step_mark "$workbase" "record"
  fi

  ok "$(pkgline "$PKG_NAME" "$PKG_VERSION") instalado."
}

# ----------------- removal / autoremove (with hooks) -----------------
remove_pkg_one() {
  local rootfs="$1" libc="$2" profile="$3" pkg="$4" force="${5:-0}" autoremove="${6:-0}"
  require_rootfs "$rootfs"

  local d; d="$(db_pkg_dir "$rootfs" "$profile" "$pkg")"
  [[ -d "$d" ]] || die "Pacote não instalado: $pkg (rootfs=$rootfs profile=$profile)"
  local rootfs_dir="$ADM_ROOTFS_BASE/$rootfs"

  local deps; deps="$(cat "$d/deps" 2>/dev/null || true)"

  local dependents=()
  while IFS= read -r dep; do [[ -n "$dep" ]] && dependents+=("$dep"); done < <(dependents_of "$rootfs" "$profile" "$pkg" || true)
  if [[ "${#dependents[@]}" -gt 0 && "$force" != "1" ]]; then
    die "Não é possível remover '$pkg': requerido por: ${dependents[*]} (use --force para ignorar)"
  fi

  local recipe
  if recipe="$(find_recipe "$pkg" 2>/dev/null)"; then
    load_profile "$rootfs" "$libc" "$profile"
    load_recipe "$recipe"
    log_init "$rootfs" "$profile" "$PKG_NAME" "$PKG_VERSION"
    call_hook pre_remove
  else
    log_init "$rootfs" "$profile" "$pkg" "$(cat "$d/version" 2>/dev/null || echo '?')"
  fi

  local manifest="$d/manifest"
  [[ -f "$manifest" ]] || die "Manifest ausente no DB: $manifest"

  info "removendo $pkg de $rootfs ($profile)"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rm -f "$rootfs_dir/$f" 2>/dev/null || true
  done <"$manifest"

  rm -rf "$d" 2>/dev/null || true
  ok "removido $pkg."

  if declare -F post_remove >/dev/null 2>&1; then
    call_hook post_remove
  fi

  if [[ "$autoremove" == "1" ]]; then
    local dep
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      if is_installed "$rootfs" "$profile" "$dep"; then
        local deps_of_dep; deps_of_dep="$(dependents_of "$rootfs" "$profile" "$dep" | wc -l | tr -d ' ')"
        if [[ "$deps_of_dep" == "0" ]]; then
          info "autoremove: removendo dependência órfã: $dep"
          remove_pkg_one "$rootfs" "$libc" "$profile" "$dep" 0 1
        fi
      fi
    done <<<"$deps"
  fi
}

# ----------------- parallel planner/scheduler for installs -----------------
install_plan_execute() {
  local rootfs="$1" libc="$2" profile="$3" resume="$4" jobs="$5"
  shift 5
  local targets=("$@")

  plan_resolve "${targets[@]}"

  declare -A in_plan=()
  local p
  for p in "${PLAN_ORDER[@]}"; do in_plan["$p"]=1; done

  declare -A need_count=()
  declare -A dependents=()
  for p in "${PLAN_ORDER[@]}"; do
    local deps=()
    while IFS= read -r d; do [[ -n "$d" ]] && deps+=("$d"); done < <(_recipe_deps_of "$p" || true)
    local cnt=0 d
    for d in "${deps[@]}"; do
      [[ -n "${in_plan[$d]:-}" ]] || continue
      ((cnt++))
      dependents["$d"]+="${p} "
    done
    need_count["$p"]="$cnt"
  done

  declare -a queue=()
  for p in "${PLAN_ORDER[@]}"; do
    if [[ "${need_count[$p]:-0}" -eq 0 ]]; then queue+=("$p"); fi
  done

  declare -A pid_pkg=()
  local running=0

  _start_pkg() {
    local pkg="$1"
    ( build_and_install_one "$rootfs" "$libc" "$profile" "$pkg" "$resume" ) &
    local pid="$!"
    pid_pkg["$pid"]="$pkg"
    ((running++))
  }

  _finish_pkg() {
    local donepkg="$1"
    local depstr="${dependents[$donepkg]:-}"
    local dep
    for dep in $depstr; do
      local n="${need_count[$dep]:-0}"
      n=$((n-1))
      need_count["$dep"]="$n"
      if [[ "$n" -eq 0 ]]; then
        queue+=("$dep")
      fi
    done
  }

  while [[ "${#queue[@]}" -gt 0 || "$running" -gt 0 ]]; do
    while [[ "${#queue[@]}" -gt 0 && "$running" -lt "$jobs" ]]; do
      local next="${queue[0]}"
      queue=("${queue[@]:1}")

      local recipe; recipe="$(find_recipe "$next")"
      load_recipe "$recipe"
      if is_installed "$rootfs" "$profile" "$PKG_NAME"; then
        local iv; iv="$(installed_version "$rootfs" "$profile" "$PKG_NAME")"
        if [[ "$iv" == "$PKG_VERSION" ]]; then
          info "skip (já instalado): $(pkgline "$PKG_NAME" "$PKG_VERSION")"
          _finish_pkg "$PKG_NAME"
          continue
        fi
      fi

      _start_pkg "$next"
      info "rodando: $next (jobs $running/$jobs)"
    done

    if [[ "$running" -eq 0 ]]; then
      continue
    fi

    local pid
    local finished_any=0
    for pid in "${!pid_pkg[@]}"; do
      if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" || exit 1
        local donepkg="${pid_pkg[$pid]}"
        unset pid_pkg["$pid"] || true
        ((running--))
        _finish_pkg "$donepkg"
        finished_any=1
        break
      fi
    done
    if [[ "$finished_any" -eq 0 ]]; then
      sleep 0.1
    fi
  done
}

# ----------------- commands -----------------
cmd_init() {
  ensure_layout
  ok "layout criado em $ADM_ROOT"
  echo "Próximos passos:"
  echo "  1) adm rootfs-create <nome>"
  echo "  2) adm profile-create <rootfs> glibc <profile> [--target x86_64-linux-gnu]"
  echo "  3) adm profile-create <rootfs> musl  <profile> [--target x86_64-linux-musl]"
  echo "  4) adm profile-create <rootfs> tools <profile> --target <TRIPLE> --build <BUILD_TRIPLE>"
  echo "  5) adm use <rootfs> <glibc|musl|tools> <profile>"
}

cmd_rootfs_create() {
  ensure_layout
  local name="${1:-}"
  [[ -n "$name" ]] || die "Uso: adm rootfs-create <nome>"
  mkdir -p "$ADM_ROOTFS_BASE/$name"
  ok "rootfs criado: $ADM_ROOTFS_BASE/$name"
}

cmd_profile_create() {
  ensure_layout
  local rootfs="${1:-}" kind="${2:-}" prof="${3:-}"
  shift 3 || true
  [[ -n "$rootfs" && -n "$kind" && -n "$prof" ]] || die "Uso: adm profile-create <rootfs> <glibc|musl|tools> <nome> [opções]"
  require_rootfs "$rootfs"
  [[ "$kind" == "glibc" || "$kind" == "musl" || "$kind" == "tools" ]] || die "kind inválido: $kind"

  local build="" host="" target="" sysroot=""
  while [[ "${1:-}" ]]; do
    case "$1" in
      --build)  build="${2:-}"; shift 2 ;;
      --host)   host="${2:-}"; shift 2 ;;
      --target) target="${2:-}"; shift 2 ;;
      --sysroot) sysroot="${2:-}"; shift 2 ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done

  build="${build:-x86_64-pc-linux-gnu}"
  if [[ -z "$target" ]]; then
    case "$kind" in
      glibc) target="x86_64-linux-gnu" ;;
      musl)  target="x86_64-linux-musl" ;;
      tools) die "tools exige --target <TRIPLE>" ;;
    esac
  fi
  host="${host:-$target}"
  sysroot="${sysroot:-$ADM_ROOTFS_BASE/$rootfs}"

  local pdir="$ADM_PROFILES/$rootfs/$kind"
  mkdir -p "$pdir"
  local pfile="$pdir/$prof.env"
  [[ -f "$pfile" ]] && die "Profile já existe: $pfile"

  local tools_dir="$sysroot/tools"

  cat >"$pfile" <<EOF
# ADM profile
# rootfs=$rootfs
# kind=$kind
# name=$prof

export ADM_PROFILE_KIND="$kind"
export ADM_BUILD_TRIPLE="$build"
export ADM_HOST_TRIPLE="$host"
export ADM_TARGET_TRIPLE="$target"
export ADM_SYSROOT="$sysroot"
export ADM_TOOLS_DIR="$tools_dir"

# Toolchain selection (customize to your toolchain):
export CC="\${CC:-cc}"
export CXX="\${CXX:-c++}"
export AR="\${AR:-ar}"
export RANLIB="\${RANLIB:-ranlib}"
export STRIP="\${STRIP:-strip}"
export LD="\${LD:-ld}"

export CFLAGS="\${CFLAGS:--O2 -pipe}"
export CXXFLAGS="\${CXXFLAGS:--O2 -pipe}"
export LDFLAGS="\${LDFLAGS:-}"

export PKG_CONFIG_PATH="\${PKG_CONFIG_PATH:-/usr/lib/pkgconfig:/usr/share/pkgconfig}"

export ADM_TOOLS_PREFIX="/tools"

if [[ "\$ADM_PROFILE_KIND" == "tools" ]]; then
  export PATH="\$ADM_SYSROOT/tools/bin:\$PATH"
fi
EOF

  ok "profile criado: $pfile"
}

cmd_use() {
  ensure_layout
  local rootfs="${1:-}" kind="${2:-}" prof="${3:-}"
  [[ -n "$rootfs" && -n "$kind" && -n "$prof" ]] || die "Uso: adm use <rootfs> <glibc|musl|tools> <profile>"
  require_rootfs "$rootfs"
  [[ -f "$(profile_path "$rootfs" "$kind" "$prof")" ]] || die "Profile não encontrado."
  state_set_current "$rootfs" "$kind" "$prof"
  ok "contexto atual: rootfs=$rootfs kind=$kind profile=$prof"
}

cmd_context() {
  ensure_layout
  if state_get_current >/dev/null 2>&1; then
    local r l p
    read -r r <"$ADM_STATE/current.rootfs"
    read -r l <"$ADM_STATE/current.libc"
    read -r p <"$ADM_STATE/current.profile"
    echo "rootfs=$r kind=$l profile=$p"
  else
    echo "contexto não definido (use: adm use <rootfs> <glibc|musl|tools> <profile>)"
  fi
}

cmd_repo_add() {
  ensure_layout
  local name="${1:-}" url="${2:-}"
  [[ -n "$name" && -n "$url" ]] || die "Uso: adm repo-add <nome> <git_url>"
  need git
  [[ ! -d "$ADM_REPOS/$name/.git" ]] || die "Repo já existe: $ADM_REPOS/$name"
  git clone --depth 1 "$url" "$ADM_REPOS/$name" >>/dev/null 2>&1 || die "Falha ao clonar repo."
  ok "repo adicionado: $name"
}

cmd_search() {
  ensure_layout
  local q="${1:-}"
  [[ -n "$q" ]] || die "Uso: adm search <termo>"
  local f found=0
  while IFS= read -r -d '' f; do
    found=1
    echo "overlay: ${f%/recipe.sh}" | sed 's|.*/pkgs/||'
  done < <(find "$ADM_PKGS" -mindepth 2 -maxdepth 2 -type f -name recipe.sh -print0 2>/dev/null \
           | xargs -0 -I{} bash -c 'grep -qi -- "$0" "{}" && printf "%s\0" "{}"' "$q" 2>/dev/null || true)
  while IFS= read -r -d '' f; do
    found=1
    echo "repo: ${f%/recipe.sh}" | sed 's|.*/pkgs/||'
  done < <(find "$ADM_REPOS" -type f -path "*/pkgs/*/recipe.sh" -print0 2>/dev/null \
           | xargs -0 -I{} bash -c 'grep -qi -- "$0" "{}" && printf "%s\0" "{}"' "$q" 2>/dev/null || true)
  [[ "$found" -eq 1 ]] || info "nenhum resultado para: $q"
}

cmd_info() {
  ensure_layout
  local pkg="${1:-}"
  [[ -n "$pkg" ]] || die "Uso: adm info <pacote>"
  local recipe; recipe="$(find_recipe "$pkg")" || die "Pacote não encontrado: $pkg"
  load_recipe "$recipe"

  echo "$(pkgline "$PKG_NAME" "$PKG_VERSION")"
  echo "Descrição : $PKG_DESC"
  [[ -n "${PKG_HOMEPAGE:-}" ]] && echo "Homepage : $PKG_HOMEPAGE"
  [[ -n "${PKG_LICENSE:-}" ]] && echo "Licença  : $PKG_LICENSE"
  echo "Recipe   : $recipe"
  echo "Deps     : ${PKG_DEPS[*]:-}"
  echo "BuildDeps: ${PKG_BUILD_DEPS[*]:-}"
}

_cmd_get_ctx() {
  local rootfs kind profile
  if state_get_current >/dev/null 2>&1; then
    rootfs="$(cat "$ADM_STATE/current.rootfs")"
    kind="$(cat "$ADM_STATE/current.libc")"
    profile="$(cat "$ADM_STATE/current.profile")"
  else
    die "Contexto não definido. Use: adm use <rootfs> <glibc|musl|tools> <profile>"
  fi
  printf '%s\n' "$rootfs" "$kind" "$profile"
}

cmd_fetch() {
  ensure_layout
  local pkgs=("$@")
  [[ "${#pkgs[@]}" -gt 0 ]] || die "Uso: adm fetch <pkg1> [pkg2 ...]"
  plan_resolve "${pkgs[@]}"
  local p
  for p in "${PLAN_ORDER[@]}"; do
    local recipe; recipe="$(find_recipe "$p")" || die "Pacote não encontrado: $p"
    load_recipe "$recipe"
    log_init "fetch" "fetch" "$PKG_NAME" "$PKG_VERSION"
    info "fetch: $(pkgline "$PKG_NAME" "$PKG_VERSION")"
    fetch_sources "$ADM_BUILD_ROOT/fetch-${PKG_NAME}-${PKG_VERSION}" >/dev/null 2>&1 || true
  done
  ok "fetch concluído."
}

cmd_install() {
  ensure_layout
  lock_acquire "global"

  local resume="$ADM_RESUME_DEFAULT"
  local jobs="$ADM_JOBS"

  local args=()
  while [[ "${1:-}" ]]; do
    case "$1" in
      --no-resume) resume=0; shift ;;
      --resume) resume=1; shift ;;
      -j|--jobs) jobs="${2:-}"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [[ "${#args[@]}" -gt 0 ]] || die "Uso: adm install [--resume|--no-resume] [-j N] <pkg1> [pkg2 ...]"

  local rootfs kind profile
  read -r rootfs kind profile < <(_cmd_get_ctx)

  install_plan_execute "$rootfs" "$kind" "$profile" "$resume" "$jobs" "${args[@]}"
  ok "instalação concluída."
}

cmd_build() { cmd_install "$@"; }

cmd_deps() {
  ensure_layout
  local pkgs=("$@")
  [[ "${#pkgs[@]}" -gt 0 ]] || die "Uso: adm deps <pkg1> [pkg2 ...]"
  plan_resolve "${pkgs[@]}"
  printf '%s\n' "${PLAN_ORDER[@]}"
}

cmd_remove() {
  ensure_layout
  lock_acquire "global"

  local force=0 autoremove=0
  local pkg=""
  while [[ "${1:-}" ]]; do
    case "$1" in
      --force) force=1; shift ;;
      --autoremove) autoremove=1; shift ;;
      *) pkg="$1"; shift ;;
    esac
  done
  [[ -n "$pkg" ]] || die "Uso: adm remove [--force] [--autoremove] <pkg>"

  local rootfs kind profile
  read -r rootfs kind profile < <(_cmd_get_ctx)
  remove_pkg_one "$rootfs" "$kind" "$profile" "$pkg" "$force" "$autoremove"
}

cmd_list() {
  ensure_layout
  local rootfs kind profile
  read -r rootfs kind profile < <(_cmd_get_ctx)
  local d; d="$(db_installed_dir "$rootfs" "$profile")"
  [[ -d "$d" ]] || { info "nenhum pacote instalado."; return 0; }
  local p
  for p in "$d"/*; do
    [[ -d "$p" ]] || continue
    local n v
    n="$(cat "$p/name" 2>/dev/null || basename "$p")"
    v="$(cat "$p/version" 2>/dev/null || echo "?")"
    echo "$(pkgline "$n" "$v")"
  done
}

cmd_log() {
  ensure_layout
  local rootfs kind profile
  read -r rootfs kind profile < <(_cmd_get_ctx)
  local dir="$ADM_LOG/$rootfs/$profile"
  [[ -d "$dir" ]] || die "Sem logs para rootfs=$rootfs profile=$profile"
  ls -1t "$dir" | head -n 30 | sed "s|^|$dir/|"
}

cmd_clean() {
  ensure_layout
  local what="${1:-all}"
  case "$what" in
    build) rm -rf "$ADM_BUILD_ROOT"/*; ok "build dirs limpos." ;;
    sources) rm -rf "$ADM_SRC_CACHE"/*; ok "cache de sources limpo." ;;
    bin) rm -rf "$ADM_BIN_CACHE"/*; ok "cache de binários limpo." ;;
    logs) rm -rf "$ADM_LOG"/*; ok "logs limpos." ;;
    all) rm -rf "$ADM_BUILD_ROOT"/* "$ADM_LOG"/*; ok "build dirs e logs limpos." ;;
    *) die "Uso: adm clean [build|sources|bin|logs|all]" ;;
  esac
}

usage() {
  cat <<EOF
ADM (adm.sh) - source-based package manager
Root: $ADM_ROOT

Contexto:
  adm init
  adm rootfs-create <nome>
  adm profile-create <rootfs> <glibc|musl|tools> <nome> [--build TRIPLE] [--host TRIPLE] [--target TRIPLE] [--sysroot PATH]
  adm use <rootfs> <glibc|musl|tools> <profile>
  adm context

Repos/overlay:
  adm repo-add <nome> <git_url>

Operações:
  adm search <termo>
  adm info <pacote>
  adm deps <pkg1> [pkg2 ...]
  adm fetch <pkg1> [pkg2 ...]
  adm install [--resume|--no-resume] [-j N] <pkg1> [pkg2 ...]
  adm remove [--force] [--autoremove] <pkg>
  adm list
  adm log
  adm clean [build|sources|bin|logs|all]

Ambiente:
  ADM_ROOT=/opt/adm
  ADM_JOBS=$ADM_JOBS
  ADM_FETCH_JOBS=$ADM_FETCH_JOBS
  ADM_RESUME_DEFAULT=$ADM_RESUME_DEFAULT
EOF
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    init) cmd_init "$@" ;;
    rootfs-create) cmd_rootfs_create "$@" ;;
    profile-create) cmd_profile_create "$@" ;;
    use) cmd_use "$@" ;;
    context) cmd_context ;;
    repo-add) cmd_repo_add "$@" ;;
    search) cmd_search "$@" ;;
    info) cmd_info "$@" ;;
    deps) cmd_deps "$@" ;;
    fetch) cmd_fetch "$@" ;;
    build) cmd_build "$@" ;;
    install) cmd_install "$@" ;;
    remove) cmd_remove "$@" ;;
    list) cmd_list ;;
    log) cmd_log ;;
    clean) cmd_clean "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "Comando desconhecido: $cmd (use --help)" ;;
  esac
}

main "$@"
