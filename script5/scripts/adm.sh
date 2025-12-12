#!/usr/bin/env bash
# adm.sh - Source-based package manager for LFS-like systems
#
# Contract (important):
# - Recipes live in:  $ADM_ROOT/packages/<category>/<name>-<version>.sh
# - Recipes must define: PKG_NAME, PKG_VERSION (and usually PKG_DESC/PKG_DEPENDS/PKG_CATEGORY)
# - Recipes must install into: DESTDIR="$PKG_BUILD_ROOT"
# - adm packs PKG_BUILD_ROOT -> binary tar.xz -> extracts into $PKG_ROOTFS (profile rootfs)
# - Profiles:
#     $ADM_ROOT/profiles/<profile>/rootfs
#     $ADM_ROOT/profiles/<profile>/env.sh (optional; auto-sourced)
#
set -euo pipefail
set -o errtrace

IFS=$' \t\n'

# -----------------------------------------------------------------------------
# Global defaults (can be overridden in /etc/adm.conf or $HOME/.adm.conf)
# -----------------------------------------------------------------------------

ADM_ROOT_DEFAULT="/opt/adm"

ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"
ADM_DB_DIR="${ADM_ROOT}/db"
ADM_SRC_CACHE="${ADM_ROOT}/sources"
ADM_BIN_CACHE="${ADM_ROOT}/binaries"
ADM_BUILD_DIR="${ADM_ROOT}/build"
ADM_LOG_DIR="${ADM_ROOT}/log"

ADM_PKG_DIR="${ADM_ROOT}/packages"
ADM_PROFILE_DIR="${ADM_ROOT}/profiles"

ADM_CONFIG_SYS="/etc/adm.conf"
ADM_CONFIG_USER="${HOME:-/root}/.adm.conf"

ADM_CURRENT_PROFILE_FILE="${ADM_ROOT}/current_profile"

# lock file (prevents concurrent installs/builds into same cache/rootfs)
ADM_LOCK_FILE="${ADM_ROOT}/adm.lock"

# behavior toggles
ADM_ALLOW_EMPTY_PKG="${ADM_ALLOW_EMPTY_PKG:-0}"  # set 1 to allow packaging empty PKG_BUILD_ROOT
ADM_TAR_EXTRACT_SAFETY="${ADM_TAR_EXTRACT_SAFETY:-1}" # 1: --no-same-owner/permissions on extract

umask 022

# Colors (safe fallback if not a TTY)
if [ -t 1 ]; then
  C_RED="\033[31m"
  C_GREEN="\033[32m"
  C_YELLOW="\033[33m"
  C_BLUE="\033[34m"
  C_RESET="\033[0m"
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_RESET=""
fi

# -----------------------------------------------------------------------------
# Utilities
# -----------------------------------------------------------------------------

log_file=""

init_logging() {
  mkdir -p "$ADM_LOG_DIR"
  local ts
  ts="$(date +%Y%m%d)"
  log_file="${ADM_LOG_DIR}/adm-${ts}.log"
  touch "$log_file"
}

log() {
  local level="$1"; shift || true
  local msg="$*"
  local ts
  ts="$(date +'%Y-%m-%d %H:%M:%S')"
  printf '%b[%s] (%s) %s%b\n' "$C_BLUE" "$ts" "$level" "$msg" "$C_RESET" >&2
  if [ -n "${log_file:-}" ]; then
    printf '[%s] (%s) %s\n' "$ts" "$level" "$msg" >> "$log_file"
  fi
}

die() {
  local code="${1:-1}"
  shift || true
  log "ERROR" "$*"
  exit "$code"
}

warn() {
  log "WARN" "$*"
}

info() {
  log "INFO" "$*"
}

ensure_dir() {
  local d
  for d in "$@"; do
    [ -d "$d" ] || mkdir -p "$d"
  done
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die 1 "Required command not found: $c"
  done
}

load_config() {
  if [ -f "$ADM_CONFIG_SYS" ]; then
    # shellcheck disable=SC1090
    . "$ADM_CONFIG_SYS"
  fi
  if [ -f "$ADM_CONFIG_USER" ]; then
    # shellcheck disable=SC1090
    . "$ADM_CONFIG_USER"
  fi
}

get_current_profile() {
  if [ -f "$ADM_CURRENT_PROFILE_FILE" ]; then
    cat "$ADM_CURRENT_PROFILE_FILE"
  else
    printf 'glibc'
  fi
}

set_current_profile() {
  local profile="$1"
  echo "$profile" > "$ADM_CURRENT_PROFILE_FILE"
}

get_rootfs_dir() {
  local profile="$1"
  printf '%s\n' "${ADM_PROFILE_DIR}/${profile}/rootfs"
}

# Acquire a filesystem lock (best-effort portability)
acquire_lock() {
  ensure_dir "$ADM_ROOT"
  exec 9>"$ADM_LOCK_FILE"
  if command -v flock >/dev/null 2>&1; then
    flock -n 9 || die 1 "Another adm instance is running (lock: $ADM_LOCK_FILE)"
  else
    # Fallback: mkdir lockdir (atomic on POSIX)
    local lockdir="${ADM_LOCK_FILE}.d"
    if ! mkdir "$lockdir" 2>/dev/null; then
      die 1 "Another adm instance is running (lockdir: $lockdir)"
    fi
    # Ensure cleanup on exit
    trap 'rmdir "'"$lockdir"'" 2>/dev/null || true' EXIT
  fi
}

# Apply profile environment (PATH, ROOTFS, env extra from env.sh)
apply_profile_env() {
  local profile rootfs env_file
  profile="$(get_current_profile)"
  rootfs="$(get_rootfs_dir "$profile")"

  export ADM_CURRENT_PROFILE="$profile"
  export ADM_CURRENT_ROOTFS="$rootfs"

  # Prefix PATH idempotently
  local prefix="${rootfs}/tools/bin:${rootfs}/usr/bin:${rootfs}/bin"
  case ":${PATH:-}:" in
    *":${rootfs}/tools/bin:"*) : ;;
    *)
      export PATH="${prefix}:${PATH:-}"
      ;;
  esac

  env_file="${ADM_PROFILE_DIR}/${profile}/env.sh"
  if [ -f "$env_file" ]; then
    # shellcheck disable=SC1090
    . "$env_file"
  fi
}

sanitize_var_key() {
  local s="$1"
  s="${s//[^A-Za-z0-9_]/_}"
  printf '%s' "$s"
}

on_error() {
  local exit_code=$?
  local last_cmd="${BASH_COMMAND:-unknown}"
  local line="${BASH_LINENO[0]:-?}"
  log "ERROR" "Unexpected error (code=$exit_code) at line $line: $last_cmd"
  exit "$exit_code"
}
trap on_error ERR

# -----------------------------------------------------------------------------
# Package DB helpers
# -----------------------------------------------------------------------------

pkg_meta_path() {
  local profile="$1" pkg="$2"
  printf '%s\n' "${ADM_DB_DIR}/${profile}/${pkg}.meta"
}

pkg_is_installed() {
  local profile="$1" pkg="$2"
  local meta
  meta="$(pkg_meta_path "$profile" "$pkg")"
  [ -f "$meta" ]
}

pkg_field() {
  local profile="$1" pkg="$2" field="$3"
  local meta
  meta="$(pkg_meta_path "$profile" "$pkg")"
  [ -f "$meta" ] || return 1
  # shellcheck disable=SC1090
  . "$meta"
  # field name is controlled by adm; still guard against empty
  [ -n "$field" ] || return 1
  eval "printf '%s' \"\${$field-}\""
}

pkg_list_installed() {
  local profile="$1"
  local d="${ADM_DB_DIR}/${profile}"
  [ -d "$d" ] || return 0
  local meta pkg
  shopt -s nullglob
  for meta in "$d"/*.meta; do
    [ -e "$meta" ] || continue
    pkg="${meta##*/}"
    pkg="${pkg%.meta}"
    printf '%s\n' "$pkg"
  done
  shopt -u nullglob
}

pkg_reverse_deps() {
  local profile="$1" target="$2"
  local d="${ADM_DB_DIR}/${profile}"
  [ -d "$d" ] || return 0
  local meta deps dname p
  shopt -s nullglob
  for meta in "$d"/*.meta; do
    [ -e "$meta" ] || continue
    # shellcheck disable=SC1090
    . "$meta"
    deps="${DEPENDS:-}"
    for dname in $deps; do
      if [ "$dname" = "$target" ]; then
        p="${meta##*/}"
        p="${p%.meta}"
        printf '%s\n' "$p"
        break
      fi
    done
  done
  shopt -u nullglob
}

# -----------------------------------------------------------------------------
# Recipe path helpers (categorias / packages)
# -----------------------------------------------------------------------------

# spec -> (category, name, version)
parse_pkg_spec() {
  local spec="$1"
  local category="" name version=""

  local tmp="${spec##*/}"
  if [ "$tmp" != "$spec" ]; then
    category="${spec%/*}"
    name="$tmp"
  else
    name="$spec"
  fi

  if [[ "$name" == *"@"* ]]; then
    version="${name##*@}"
    name="${name%@*}"
  fi

  printf '%s %s %s\n' "$category" "$name" "$version"
}

# path: $ADM_ROOT/packages/<cat>/<name>-<version>.sh
# robust split: first '-' where next char is a digit -> start of version
recipe_parse_path() {
  local path="$1"
  local category base name ver i ch next
  category="$(basename "$(dirname "$path")")"
  base="${path##*/}"
  base="${base%.sh}"

  name="$base"
  ver=""

  for ((i=0; i<${#base}; i++)); do
    ch="${base:i:1}"
    next="${base:i+1:1}"
    if [ "$ch" = "-" ] && [[ "$next" =~ [0-9] ]]; then
      name="${base:0:i}"
      ver="${base:i+1}"
      break
    fi
  done

  printf '%s %s %s\n' "$category" "$name" "$ver"
}

# find best recipe for spec
find_recipe() {
  local spec="$1"
  local category name version
  read -r category name version < <(parse_pkg_spec "$spec")

  local best_path="" best_ver=""
  local f c n v

  if [ -n "$category" ]; then
    local dir="${ADM_PKG_DIR}/${category}"
    [ -d "$dir" ] || die 1 "Category '$category' not found for package '$name'"
    shopt -s nullglob
    for f in "$dir"/*.sh; do
      read -r c n v < <(recipe_parse_path "$f")
      [ "$n" = "$name" ] || continue
      if [ -n "$version" ] && [ "$v" != "$version" ]; then
        continue
      fi
      if [ -z "$best_path" ]; then
        best_path="$f"; best_ver="$v"
      else
        if [ -n "$v" ] && [ "$(printf '%s\n' "$best_ver" "$v" | sort -V | tail -n1)" = "$v" ] \
           && [ "$v" != "$best_ver" ]; then
          best_path="$f"; best_ver="$v"
        fi
      fi
    done
    shopt -u nullglob
  else
    shopt -s nullglob
    for f in "$ADM_PKG_DIR"/*/*.sh; do
      read -r c n v < <(recipe_parse_path "$f")
      [ "$n" = "$name" ] || continue
      if [ -n "$version" ] && [ "$v" != "$version" ]; then
        continue
      fi
      if [ -z "$best_path" ]; then
        best_path="$f"; best_ver="$v"
      else
        if [ -n "$v" ] && [ "$(printf '%s\n' "$best_ver" "$v" | sort -V | tail -n1)" = "$v" ] \
           && [ "$v" != "$best_ver" ]; then
          best_path="$f"; best_ver="$v"
        fi
      fi
    done
    shopt -u nullglob
  fi

  if [ -z "$best_path" ]; then
    if [ -n "$category" ] && [ -n "$version" ]; then
      die 1 "Recipe not found for ${category}/${name}@${version}"
    elif [ -n "$category" ]; then
      die 1 "Recipe not found for ${category}/${name}"
    elif [ -n "$version" ]; then
      die 1 "Recipe not found for ${name}@${version}"
    else
      die 1 "Recipe not found for ${name}"
    fi
  fi

  printf '%s\n' "$best_path"
}

# -----------------------------------------------------------------------------
# Dependency resolution and cycle detection (no eval; robust)
# -----------------------------------------------------------------------------

# We track visited/stack by PKG_NAME (logical name), not by spec.
declare -A ADM_VISITED=()
declare -A ADM_STACK=()

resolve_deps_dfs() {
  local _profile="$1" spec="$2"   # _profile kept for future compatibility
  load_recipe "$spec"

  local key
  key="$(sanitize_var_key "$PKG_NAME")"

  if [ "${ADM_VISITED[$key]:-0}" = "1" ]; then
    return 0
  fi
  if [ "${ADM_STACK[$key]:-0}" = "1" ]; then
    die 1 "Cycle detected in dependencies at package '$PKG_NAME'"
  fi

  ADM_STACK["$key"]="1"

  local deps dep
  deps="${PKG_DEPENDS:-}"
  for dep in $deps; do
    resolve_deps_dfs "$_profile" "$dep"
  done

  ADM_STACK["$key"]="0"
  ADM_VISITED["$key"]="1"

  printf '%s\n' "$PKG_NAME"
}

resolve_dep_chain() {
  local profile="$1" spec="$2"
  # reset maps per resolution
  ADM_VISITED=()
  ADM_STACK=()
  resolve_deps_dfs "$profile" "$spec" | awk 'NF'
}

# -----------------------------------------------------------------------------
# Recipe loading and build helpers
# -----------------------------------------------------------------------------

load_recipe() {
  local spec="$1"
  local recipe
  recipe="$(find_recipe "$spec")" || die 1 "Recipe not found for '$spec'"

  unset PKG_NAME PKG_VERSION PKG_DESC PKG_DEPENDS PKG_LIBC PKG_CATEGORY || true
  unset -f pre_build post_build pre_install post_install build 2>/dev/null || true

  # shellcheck disable=SC1090
  . "$recipe"

  if [ -z "${PKG_NAME:-}" ] || [ -z "${PKG_VERSION:-}" ]; then
    die 1 "Recipe '$recipe' did not define PKG_NAME/PKG_VERSION"
  fi

  if [ -z "${PKG_CATEGORY:-}" ]; then
    PKG_CATEGORY="$(basename "$(dirname "$recipe")")"
  fi
}

# fetch_source(url, filename, [sha256])
fetch_source() {
  local url="$1"
  local fname="$2"
  local sha256="${3:-}"

  ensure_dir "$ADM_SRC_CACHE"
  local dst="${ADM_SRC_CACHE}/${fname}"

  if [ -f "$dst" ]; then
    info "Using cached source: $dst"
  else
    require_cmd curl
    info "Downloading source: $url -> $dst"
    curl -fL "$url" -o "$dst"
  fi

  if [ -n "$sha256" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      local got
      got="$(sha256sum "$dst" | awk '{print $1}')"
      [ "$got" = "$sha256" ] || die 1 "SHA256 mismatch for $dst (got=$got expected=$sha256)"
    else
      warn "sha256sum not available; cannot verify checksum for $dst"
    fi
  fi

  printf '%s\n' "$dst"
}

create_binary_pkg() {
  local pkg="$1" version="$2" build_root="$3"
  ensure_dir "$ADM_BIN_CACHE"

  if [ ! -d "$build_root" ]; then
    die 1 "Build root does not exist: $build_root"
  fi

  # fail on empty packages (common silent error in recipes)
  if [ "$ADM_ALLOW_EMPTY_PKG" != "1" ]; then
    if ! find "$build_root" -mindepth 1 -print -quit | grep -q .; then
      die 1 "Refusing to package empty build root for ${pkg}-${version}. Recipe likely forgot DESTDIR install."
    fi
  fi

  local out="${ADM_BIN_CACHE}/${pkg}-${version}.tar.xz"
  info "Creating binary package: $out"
  ( cd "$build_root" && tar -cJf "$out" . )
  printf '%s\n' "$out"
}

install_binary_pkg() {
  local profile="$1" _pkg="$2" _version="$3" tarball="$4"
  local rootfs
  rootfs="$(get_rootfs_dir "$profile")"
  ensure_dir "$rootfs"

  [ -f "$tarball" ] || die 1 "Tarball not found: $tarball"

  info "Installing ${_pkg}-${_version} into rootfs: $rootfs"
  if [ "$ADM_TAR_EXTRACT_SAFETY" = "1" ]; then
    tar -xJf "$tarball" -C "$rootfs" --no-same-owner --no-same-permissions
  else
    tar -xJf "$tarball" -C "$rootfs"
  fi
}

write_pkg_meta() {
  local profile="$1" pkg="$2" version="$3"
  local desc="$4" deps="$5"
  local libc="$6" category="$7"
  local rootfs
  rootfs="$(get_rootfs_dir "$profile")"
  ensure_dir "${ADM_DB_DIR}/${profile}"

  local meta
  meta="$(pkg_meta_path "$profile" "$pkg")"

  cat > "$meta" <<EOF
PKG_NAME="$pkg"
VERSION="$version"
DESC="$desc"
DEPENDS="$deps"
LIBC="$libc"
CATEGORY="${category:-uncategorized}"
ROOTFS="$rootfs"
INSTALL_DATE="$(date +'%Y-%m-%d %H:%M:%S')"
EOF
}

record_manifest_from_tar() {
  local profile="$1" pkg="$2" tarball="$3"
  local manifest="${ADM_DB_DIR}/${profile}/${pkg}.manifest"
  info "Recording manifest for $pkg from tarball"
  ensure_dir "${ADM_DB_DIR}/${profile}"
  tar -tJf "$tarball" | sed 's|^\./||' > "$manifest"
}

remove_pkg_files() {
  local profile="$1" pkg="$2"
  local meta
  meta="$(pkg_meta_path "$profile" "$pkg")"
  [ -f "$meta" ] || die 1 "Package '$pkg' not installed for profile '$profile'"

  # shellcheck disable=SC1090
  . "$meta"

  local rootfs="${ROOTFS:?}"
  local manifest="${ADM_DB_DIR}/${profile}/${pkg}.manifest"

  if [ -f "$manifest" ]; then
    info "Removing files from manifest for $pkg"
    local f d
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      # normalize possible leading ./ from old manifests
      f="${f#./}"
      if [ -f "${rootfs}/${f}" ] || [ -L "${rootfs}/${f}" ]; then
        rm -f "${rootfs}/${f}"
      fi
    done < "$manifest"

    # attempt to remove empty dirs (best effort)
    if command -v tac >/dev/null 2>&1; then
      tac "$manifest" 2>/dev/null | while IFS= read -r f; do
        [ -n "$f" ] || continue
        f="${f#./}"
        d="${rootfs}/${f%/*}"
        [ -d "$d" ] && rmdir "$d" 2>/dev/null || true
      done
    fi
  else
    warn "No manifest available for $pkg; skipping file removal"
  fi

  rm -f "$meta" "${ADM_DB_DIR}/${profile}/${pkg}.manifest"
}

# -----------------------------------------------------------------------------
# Core operations
# -----------------------------------------------------------------------------

cmd_init() {
  ensure_dir "$ADM_ROOT" "$ADM_DB_DIR" "$ADM_SRC_CACHE" "$ADM_BIN_CACHE" \
             "$ADM_BUILD_DIR" "$ADM_LOG_DIR" "$ADM_PROFILE_DIR" "$ADM_PKG_DIR"

  if [ ! -f "$ADM_CURRENT_PROFILE_FILE" ]; then
    set_current_profile "glibc"
  fi

  local profile
  profile="$(get_current_profile)"
  ensure_dir "${ADM_DB_DIR}/${profile}" "$(get_rootfs_dir "$profile")"
  info "Initialized adm root at $ADM_ROOT with profile '$profile'"
}

cmd_profile() {
  local action="${1:-}"
  case "$action" in
    list)
      ensure_dir "$ADM_PROFILE_DIR"
      local found=0
      local d p
      shopt -s nullglob
      for d in "$ADM_PROFILE_DIR"/*; do
        [ -d "$d" ] || continue
        found=1
        p="${d##*/}"
        if [ "$p" = "$(get_current_profile)" ]; then
          echo "* $p"
        else
          echo "  $p"
        fi
      done
      shopt -u nullglob
      [ "$found" -eq 1 ] || echo "(no profiles found)"
      ;;
    set)
      local p="${2:-}"
      [ -n "$p" ] || die 1 "Usage: adm.sh profile set <name>"
      ensure_dir "${ADM_PROFILE_DIR}/${p}" "${ADM_DB_DIR}/${p}" "$(get_rootfs_dir "$p")"
      set_current_profile "$p"
      info "Current profile set to '$p'"
      ;;
    show|"")
      echo "$(get_current_profile)"
      ;;
    *)
      die 1 "Unknown profile action '$action'"
      ;;
  esac
}

cmd_list() {
  local profile
  profile="$(get_current_profile)"

  local pkg ver desc cat
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    ver="$(pkg_field "$profile" "$pkg" VERSION || echo '?')"
    desc="$(pkg_field "$profile" "$pkg" DESC || echo '')"
    cat="$(pkg_field "$profile" "$pkg" CATEGORY || echo '')"
    printf '%-20s %-10s %-15s %s\n' "$pkg" "$ver" "$cat" "$desc"
  done < <(pkg_list_installed "$profile")
}

cmd_info() {
  local pkg="${1:-}"
  [ -n "$pkg" ] || die 1 "Usage: adm.sh info <pkg>"
  local profile
  profile="$(get_current_profile)"
  if ! pkg_is_installed "$profile" "$pkg"; then
    echo "Package '$pkg' is not installed for profile '$profile'"
    return 1
  fi
  local meta
  meta="$(pkg_meta_path "$profile" "$pkg")"
  cat "$meta"
  echo
  echo "Reverse dependencies:"
  pkg_reverse_deps "$profile" "$pkg" || true
}

cmd_search() {
  local pattern="${1:-}"
  [ -n "$pattern" ] || die 1 "Usage: adm.sh search <pattern>"
  ensure_dir "$ADM_PKG_DIR"

  local f c n v
  shopt -s nullglob
  for f in "$ADM_PKG_DIR"/*/*.sh; do
    read -r c n v < <(recipe_parse_path "$f")
    if printf '%s\n%s\n' "$n" "$c" | grep -qi -- "$pattern"; then
      echo "${c}/${n}-${v}"
      continue
    fi
    if grep -qi -- "$pattern" "$f"; then
      echo "${c}/${n}-${v}"
    fi
  done
  shopt -u nullglob
}

cmd_build() {
  local spec="${1:-}"
  [ -n "$spec" ] || die 1 "Usage: adm.sh build <pkg-spec>"

  acquire_lock

  local profile
  profile="$(get_current_profile)"
  load_recipe "$spec"

  local build_root="${ADM_BUILD_DIR}/${PKG_NAME}-${PKG_VERSION}/rootfs"
  local build_work="${ADM_BUILD_DIR}/${PKG_NAME}-${PKG_VERSION}/work"

  rm -rf "$build_root" "$build_work"
  ensure_dir "$build_root" "$build_work"

  export PKG_BUILD_ROOT="$build_root"
  export PKG_BUILD_WORK="$build_work"
  export PKG_PROFILE="$profile"
  export PKG_ROOTFS
  PKG_ROOTFS="$(get_rootfs_dir "$profile")"
  export PKG_ROOTFS

  if type pre_build >/dev/null 2>&1; then
    info "Running pre_build hook for $PKG_NAME"
    pre_build
  fi

  if type build >/dev/null 2>&1; then
    info "Running build() for $PKG_NAME"
    build
  else
    die 1 "Recipe for '$PKG_NAME' does not define build()"
  fi

  if type post_build >/dev/null 2>&1; then
    info "Running post_build hook for $PKG_NAME"
    post_build
  fi

  local tarball
  tarball="$(create_binary_pkg "$PKG_NAME" "$PKG_VERSION" "$build_root")"
  printf '%s\n' "$tarball"
}

cmd_install_one_from_tar() {
  local profile="$1" pkg="$2" version="$3" desc="$4" deps="$5" libc="$6" category="$7" tarball="$8"

  # Hooks belong to the recipe currently loaded
  if type pre_install >/dev/null 2>&1; then
    info "Running pre_install hook for $pkg"
    pre_install
  fi

  install_binary_pkg "$profile" "$pkg" "$version" "$tarball"
  record_manifest_from_tar "$profile" "$pkg" "$tarball"
  write_pkg_meta "$profile" "$pkg" "$version" "$desc" "$deps" "$libc" "$category"

  if type post_install >/dev/null 2>&1; then
    info "Running post_install hook for $pkg"
    post_install
  fi
}

cmd_install() {
  local spec="${1:-}"
  [ -n "$spec" ] || die 1 "Usage: adm.sh install <pkg-spec>"

  acquire_lock

  local profile
  profile="$(get_current_profile)"

  # Load target recipe to identify logical PKG_NAME
  load_recipe "$spec"
  local target_name="$PKG_NAME"

  info "Resolving dependencies for $spec"
  local ordered dep
  ordered="$(resolve_dep_chain "$profile" "$spec")"

  # Install deps (excluding target)
  for dep in $ordered; do
    if [ "$dep" = "$target_name" ]; then
      continue
    fi
    if pkg_is_installed "$profile" "$dep"; then
      continue
    fi

    info "Building dependency '$dep'"
    load_recipe "$dep"

    local dep_libc dep_cat dep_tar
    dep_libc="${PKG_LIBC:-$profile}"
    dep_cat="${PKG_CATEGORY:-uncategorized}"
    dep_tar="$(cmd_build "$dep")"

    cmd_install_one_from_tar "$profile" "$PKG_NAME" "$PKG_VERSION" "${PKG_DESC:-}" \
                             "${PKG_DEPENDS:-}" "$dep_libc" "$dep_cat" "$dep_tar"
  done

  # Install target using original spec (category/version)
  info "Building target package '$spec'"
  load_recipe "$spec"

  local libc cat pkg_tar
  libc="${PKG_LIBC:-$profile}"
  cat="${PKG_CATEGORY:-uncategorized}"
  pkg_tar="$(cmd_build "$spec")"

  cmd_install_one_from_tar "$profile" "$PKG_NAME" "$PKG_VERSION" "${PKG_DESC:-}" \
                           "${PKG_DEPENDS:-}" "$libc" "$cat" "$pkg_tar"
}

cmd_remove() {
  local pkg="${1:-}"
  [ -n "$pkg" ] || die 1 "Usage: adm.sh remove <pkg>"
  acquire_lock

  local profile
  profile="$(get_current_profile)"
  if ! pkg_is_installed "$profile" "$pkg"; then
    die 1 "Package '$pkg' is not installed for profile '$profile'"
  fi

  local rdeps
  rdeps="$(pkg_reverse_deps "$profile" "$pkg" || true)"
  if [ -n "$rdeps" ]; then
    warn "Following packages depend on '$pkg':"
    echo "$rdeps"
    die 1 "Refusing to remove '$pkg' while reverse dependencies exist"
  fi

  info "Removing package '$pkg' from profile '$profile'"
  remove_pkg_files "$profile" "$pkg"
}

cmd_update() {
  local pkg="${1:-}"
  [ -n "$pkg" ] || die 1 "Usage: adm.sh update <pkg>"
  acquire_lock

  local profile
  profile="$(get_current_profile)"
  if ! pkg_is_installed "$profile" "$pkg"; then
    die 1 "Package '$pkg' is not installed for profile '$profile'"
  fi

  info "Updating package '$pkg'"
  cmd_remove "$pkg"
  cmd_install "$pkg"
}

cmd_clean() {
  local what="${1:-all}"

  # Prevent "rm: cannot remove '/path/*': No such file or directory" under set -e
  shopt -s nullglob

  case "$what" in
    src|sources)
      rm -rf "$ADM_SRC_CACHE"/*
      info "Source cache cleaned"
      ;;
    bin|binaries)
      rm -rf "$ADM_BIN_CACHE"/*
      info "Binary cache cleaned"
      ;;
    build)
      rm -rf "$ADM_BUILD_DIR"/*
      info "Build directory cleaned"
      ;;
    logs)
      rm -rf "$ADM_LOG_DIR"/*
      info "Logs cleaned"
      ;;
    all)
      rm -rf "$ADM_SRC_CACHE"/* "$ADM_BIN_CACHE"/* "$ADM_BUILD_DIR"/* "$ADM_LOG_DIR"/*
      info "All caches/build/logs cleaned"
      ;;
    *)
      shopt -u nullglob
      die 1 "Unknown clean target '$what'"
      ;;
  esac

  shopt -u nullglob
}

cmd_deps() {
  local spec="${1:-}"
  [ -n "$spec" ] || die 1 "Usage: adm.sh deps <pkg-spec>"
  local profile
  profile="$(get_current_profile)"
  resolve_dep_chain "$profile" "$spec"
}

cmd_rdeps() {
  local pkg="${1:-}"
  [ -n "$pkg" ] || die 1 "Usage: adm.sh rdeps <pkg>"
  local profile
  profile="$(get_current_profile)"
  pkg_reverse_deps "$profile" "$pkg"
}

cmd_rootfs() {
  local profile
  profile="$(get_current_profile)"
  get_rootfs_dir "$profile"
}

usage() {
  cat <<EOF
adm.sh - Gerenciador simples de pacotes para LFS-like com categorias e perfis

Uso:
  adm.sh init                          # inicializa diretórios básicos
  adm.sh profile [show|list|set <p>]   # gerenciar perfis (glibc, musl, bootstrap, etc.)
  adm.sh list                          # lista pacotes instalados no profile atual
  adm.sh info <pkg>                    # informações de um pacote instalado
  adm.sh search <pattern>              # procura receitas por nome/categoria/conteúdo
  adm.sh build <pkg-spec>              # constrói binário a partir do source
  adm.sh install <pkg-spec>            # resolve deps, constrói e instala
  adm.sh remove <pkg>                  # remove um pacote (se não tiver rdeps)
  adm.sh update <pkg>                  # recompila e reinstala um pacote
  adm.sh deps <pkg-spec>               # mostra cadeia de dependências
  adm.sh rdeps <pkg>                   # mostra dependências reversas
  adm.sh clean [src|bin|build|logs|all]
  adm.sh rootfs                        # mostra rootfs do profile atual

Pkg-spec:
  nome               (ex: bash)
  categoria/nome     (ex: core/bash)
  nome@versao        (ex: bash@5.2)
  categoria/nome@v   (ex: toolchain/gcc-bootstrap@15.2.0)

Estrutura:
  ADM_ROOT           (default: ${ADM_ROOT_DEFAULT})
  Receitas:          \$ADM_ROOT/packages/<categoria>/<nome>-<versao>.sh
  DB de pacotes:     \$ADM_ROOT/db/<profile>/<PKG_NAME>.meta
  Rootfs do perfil:  \$ADM_ROOT/profiles/<profile>/rootfs
  Env do perfil:     \$ADM_ROOT/profiles/<profile>/env.sh (opcional)

Contrato das receitas:
  - Definem: PKG_NAME, PKG_VERSION (PKG_DESC/PKG_DEPENDS/PKG_CATEGORY recomendados)
  - Devem instalar em: DESTDIR="\$PKG_BUILD_ROOT"
  - Prefix dentro do pacote é definido pela receita (ex.: --prefix=/tools, /usr, etc.)
  - Hooks opcionais: pre_build/post_build/pre_install/post_install
EOF
}

main() {
  init_logging
  load_config
  ensure_dir "$ADM_ROOT"

  local cmd="${1:-}"
  shift || true

  # Apply profile env (PATH + env.sh). If profile dirs don't exist yet, it's fine.
  apply_profile_env

  case "$cmd" in
    init)      cmd_init "$@" ;;
    profile)   cmd_profile "$@" ;;
    list)      cmd_list "$@" ;;
    info)      cmd_info "$@" ;;
    search)    cmd_search "$@" ;;
    build)     cmd_build "$@" ;;
    install)   cmd_install "$@" ;;
    remove)    cmd_remove "$@" ;;
    update)    cmd_update "$@" ;;
    clean)     cmd_clean "$@" ;;
    deps)      cmd_deps "$@" ;;
    rdeps)     cmd_rdeps "$@" ;;
    rootfs)    cmd_rootfs "$@" ;;
    ""|-h|--help|help)
      usage
      ;;
    *)
      die 1 "Comando desconhecido '$cmd'. Use --help para ajuda."
      ;;
  esac
}

main "$@"
