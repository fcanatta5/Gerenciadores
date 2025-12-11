#!/usr/bin/env bash
#
# adm.sh - Simple source-based package manager for LFS-style systems
#
# Features:
# - Source and binary cache
# - Build scripts with hooks (pre/post build/install)
# - Separate rootfs per profile (e.g. glibc, musl, bootstrap)
# - Category-based recipes: $ADM_ROOT/packages/<category>/<name>-<version>.sh
# - Dependency management, reverse deps, cycle detection
# - Logging and basic sanity checks
#
set -euo pipefail

# Global defaults (can be overridden in /etc/adm.conf or $HOME/.adm.conf)
ADM_ROOT_DEFAULT="/opt/adm"

ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"
ADM_DB_DIR="${ADM_ROOT}/db"
ADM_SRC_CACHE="${ADM_ROOT}/sources"
ADM_BIN_CACHE="${ADM_ROOT}/binaries"
ADM_BUILD_DIR="${ADM_ROOT}/build"
ADM_LOG_DIR="${ADM_ROOT}/log"

# Diretório de receitas por categoria:
#   $ADM_ROOT/packages/<categoria>/<nome>-<versao>.sh
ADM_PKG_DIR="${ADM_ROOT}/packages"
# Compatibilidade: mantemos a variável, mas ela aponta para packages.
ADM_RECIPES_DIR="${ADM_PKG_DIR}"

ADM_PROFILE_DIR="${ADM_ROOT}/profiles"
ADM_CONFIG_SYS="/etc/adm.conf"
ADM_CONFIG_USER="${HOME:-/root}/.adm.conf"

ADM_CURRENT_PROFILE_FILE="${ADM_ROOT}/current_profile"

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

ensure_dir() {
  local d
  for d in "$@"; do
    [ -d "$d" ] || mkdir -p "$d"
  done
}

load_config() {
  # Load system and user config if present
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

# Aplica ambiente do profile atual (PATH, ROOTFS, env extra de env.sh)
apply_profile_env() {
  local profile rootfs path_prefix env_file
  profile="$(get_current_profile)"
  rootfs="$(get_rootfs_dir "$profile")"

  export ADM_CURRENT_PROFILE="$profile"
  export ADM_CURRENT_ROOTFS="$rootfs"

  # Toolchain + user bins do profile primeiro no PATH
  path_prefix="${rootfs}/tools/bin:${rootfs}/usr/bin:${rootfs}/bin"
  case ":${PATH:-}:" in
    *":${rootfs}/tools/bin:"*) ;; # já aplicado
    *)
      export PATH="${path_prefix}:${PATH:-}"
      ;;
  esac

  # Arquivo opcional de ambiente por profile:
  #   $ADM_ROOT/profiles/<profile>/env.sh
  env_file="${ADM_PROFILE_DIR}/${profile}/env.sh"
  if [ -f "$env_file" ]; then
    # shellcheck disable=SC1090
    . "$env_file"
  fi
}

# Sanitiza string para virar nome de variável
sanitize_var_key() {
  local s="$1"
  s="${s//[^A-Za-z0-9_]/_}"
  printf '%s' "$s"
}

# Trap unexpected errors for debug
on_error() {
  local exit_code=$?
  local last_cmd="${BASH_COMMAND:-unknown}"
  log "ERROR" "Unexpected error (code=$exit_code) in command: $last_cmd"
  exit "$exit_code"
}
trap on_error ERR

# -----------------------------------------------------------------------------
# Package DB helpers
# -----------------------------------------------------------------------------

# Meta files live in: $ADM_DB_DIR/<profile>/<pkg>.meta
# Aqui <pkg> é o PKG_NAME lógico (sem categoria, sem versão).
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
  eval "printf '%s' \"\${$field-}\""
}

pkg_list_installed() {
  local profile="$1"
  local d="${ADM_DB_DIR}/${profile}"
  [ -d "$d" ] || return 0
  local meta pkg
  for meta in "$d"/*.meta; do
    [ -e "$meta" ] || continue
    pkg="${meta##*/}"
    pkg="${pkg%.meta}"
    echo "$pkg"
  done
}

pkg_reverse_deps() {
  local profile="$1" target="$2"
  local d="${ADM_DB_DIR}/${profile}"
  [ -d "$d" ] || return 0
  local meta deps dname p
  for meta in "$d"/*.meta; do
    [ -e "$meta" ] || continue
    # shellcheck disable=SC1090
    . "$meta"
    deps="${DEPENDS:-}"
    for dname in $deps; do
      if [ "$dname" = "$target" ]; then
        p="${meta##*/}"
        p="${p%.meta}"
        echo "$p"
        break
      fi
    done
  done
}

# -----------------------------------------------------------------------------
# Recipe path helpers (categorias / packages)
# -----------------------------------------------------------------------------

# Converte um "spec" do usuário em (categoria, nome, versão).
# Exemplos de spec:
#   "bash"            -> ""         bash   ""
#   "core/bash"       -> "core"     bash   ""
#   "bash@5.2"        -> ""         bash   "5.2"
#   "core/bash@5.2"   -> "core"     bash   "5.2"
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

# Dado o caminho da receita, extrai (categoria, nome, versão)
# Path exemplo: /opt/adm/packages/core/bash-5.2.sh
recipe_parse_path() {
  local path="$1"
  local category base name ver
  category="$(basename "$(dirname "$path")")"
  base="${path##*/}"
  base="${base%.sh}"
  name="${base%-*}"
  ver="${base##*-}"
  printf '%s %s %s\n' "$category" "$name" "$ver"
}

# Localiza a melhor receita para um pacote (escolhe versão mais alta se não for especificada)
find_recipe() {
  local spec="$1"
  local category name version
  read -r category name version < <(parse_pkg_spec "$spec")

  local best_path="" best_ver="" best_cat=""
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
        best_path="$f"; best_ver="$v"; best_cat="$c"
      else
        if [ "$(printf '%s\n' "$best_ver" "$v" | sort -V | tail -n1)" = "$v" ] \
           && [ "$v" != "$best_ver" ]; then
          best_path="$f"; best_ver="$v"; best_cat="$c"
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
        best_path="$f"; best_ver="$v"; best_cat="$c"
      else
        if [ "$(printf '%s\n' "$best_ver" "$v" | sort -V | tail -n1)" = "$v" ] \
           && [ "$v" != "$best_ver" ]; then
          best_path="$f"; best_ver="$v"; best_cat="$c"
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
# Dependency resolution and cycle detection
# -----------------------------------------------------------------------------

# Resolve dependency closure using DFS with cycle detection.
# Prints packages in dependency order (deps first, target last).
resolve_deps_dfs() {
  local profile="$1" pkg="$2"
  local key
  key="$(sanitize_var_key "$pkg")"
  local visited_var="VISITED_${key}"
  local stack_var="STACK_${key}"

  eval "local visited_flag=\${$visited_var:-0}"
  if [ "$visited_flag" -eq 1 ]; then
    return 0
  fi

  eval "local in_stack_flag=\${$stack_var:-0}"
  if [ "$in_stack_flag" -eq 1 ]; then
    die 1 "Cycle detected in dependencies at package '$pkg'"
  fi

  eval "$stack_var=1"

  # Carrega receita apenas para ler PKG_DEPENDS
  load_recipe "$pkg"

  local deps="${PKG_DEPENDS:-}"
  local dep
  for dep in $deps; do
    resolve_deps_dfs "$profile" "$dep"
  done

  eval "$stack_var=0"
  eval "$visited_var=1"

  echo "$PKG_NAME"
}

resolve_dep_chain() {
  local profile="$1" pkg="$2"
  VISITED_="unused"
  resolve_deps_dfs "$profile" "$pkg" | awk '!/^\s*$/'
}

# -----------------------------------------------------------------------------
# Recipe loading and build helpers
# -----------------------------------------------------------------------------

load_recipe() {
  local spec="$1"
  local recipe
  recipe="$(find_recipe "$spec")" || die 1 "Recipe not found for package spec '$spec'"

  # Limpa variáveis de receita anteriores
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

# Download helper with cache
fetch_source() {
  local url="$1"
  local fname="$2"
  ensure_dir "$ADM_SRC_CACHE"
  local dst="${ADM_SRC_CACHE}/${fname}"
  if [ -f "$dst" ]; then
    log "INFO" "Using cached source: $dst"
  else
    if ! command -v curl >/dev/null 2>&1; then
      die 1 "curl not found, required to download sources"
    fi
    log "INFO" "Downloading source: $url -> $dst"
    curl -fL "$url" -o "$dst"
  fi
  echo "$dst"
}

# Generic packager: tar.xz of $build_root
create_binary_pkg() {
  local pkg="$1" version="$2" build_root="$3"
  ensure_dir "$ADM_BIN_CACHE"
  local out="${ADM_BIN_CACHE}/${pkg}-${version}.tar.xz"
  log "INFO" "Creating binary package: $out"
  ( cd "$build_root" && tar -cJf "$out" . )
  echo "$out"
}

# Install tarball into rootfs
install_binary_pkg() {
  local profile="$1" pkg="$2" version="$3" tarball="$4"
  local rootfs
  rootfs="$(get_rootfs_dir "$profile")"
  ensure_dir "$rootfs"
  log "INFO" "Installing $pkg-$version into rootfs: $rootfs"
  tar -xJf "$tarball" -C "$rootfs"
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
  log "INFO" "Recording manifest for $pkg from tarball"
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
    log "INFO" "Removing files from manifest for $pkg"
    local f d
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ -f "${rootfs}/${f}" ] || [ -L "${rootfs}/${f}" ]; then
        rm -f "${rootfs}/${f}"
      fi
    done < "$manifest"
    # Clean empty directories (best effort)
    if command -v tac >/dev/null 2>&1; then
      tac "$manifest" 2>/dev/null | while IFS= read -r f; do
        d="${rootfs}/${f%/*}"
        [ -d "$d" ] && rmdir "$d" 2>/dev/null || true
      done
    fi
  else
    log "WARN" "No manifest available for $pkg; skipping file removal"
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
  log "INFO" "Initialized adm root at $ADM_ROOT with profile '$profile'"
}

cmd_profile() {
  local action="${1:-}"
  case "$action" in
    list)
      ensure_dir "$ADM_PROFILE_DIR"
      local d p
      for d in "$ADM_PROFILE_DIR"/*; do
        [ -d "$d" ] || continue
        p="${d##*/}"
        if [ "$p" = "$(get_current_profile)" ]; then
          echo "* $p"
        else
          echo "  $p"
        fi
      done
      ;;
    set)
      local p="${2:-}"
      [ -n "$p" ] || die 1 "Usage: adm.sh profile set <name>"
      ensure_dir "${ADM_PROFILE_DIR}/${p}" "${ADM_DB_DIR}/${p}" "$(get_rootfs_dir "$p")"
      set_current_profile "$p"
      log "INFO" "Current profile set to '$p'"
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
  for pkg in $(pkg_list_installed "$profile"); do
    ver="$(pkg_field "$profile" "$pkg" VERSION || echo '?')"
    desc="$(pkg_field "$profile" "$pkg" DESC || echo '')"
    cat="$(pkg_field "$profile" "$pkg" CATEGORY || echo '')"
    printf '%-20s %-10s %-15s %s\n' "$pkg" "$ver" "$cat" "$desc"
  done
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
    # Match por nome ou categoria
    if printf '%s\n%s\n' "$n" "$c" | grep -qi -- "$pattern"; then
      echo "${c}/${n}-${v}"
      continue
    fi
    # Match por conteúdo da receita
    if grep -qi -- "$pattern" "$f"; then
      echo "${c}/${n}-${v}"
    fi
  done
  shopt -u nullglob
}

cmd_build() {
  local pkg="${1:-}"
  [ -n "$pkg" ] || die 1 "Usage: adm.sh build <pkg>"
  local profile
  profile="$(get_current_profile)"
  load_recipe "$pkg"

  local build_root="${ADM_BUILD_DIR}/${PKG_NAME}/rootfs"
  local build_work="${ADM_BUILD_DIR}/${PKG_NAME}/work"

  rm -rf "$build_root" "$build_work"
  ensure_dir "$build_root" "$build_work"

  PKG_BUILD_ROOT="$build_root"
  PKG_BUILD_WORK="$build_work"
  PKG_PROFILE="$profile"
  PKG_ROOTFS="$(get_rootfs_dir "$profile")"

  if type pre_build 2>/dev/null 1>&2; then
    log "INFO" "Running pre_build hook for $PKG_NAME"
    pre_build
  fi

  if type build 2>/dev/null 1>&2; then
    log "INFO" "Running build() for $PKG_NAME"
    build
  else
    die 1 "Recipe for '$PKG_NAME' does not define build()"
  fi

  if type post_build 2>/dev/null 1>&2; then
    log "INFO" "Running post_build hook for $PKG_NAME"
    post_build
  fi

  local tarball
  tarball="$(create_binary_pkg "$PKG_NAME" "$PKG_VERSION" "$build_root")"
  echo "$tarball"
}

cmd_install_one_from_tar() {
  local profile="$1" pkg="$2" version="$3" desc="$4" deps="$5" libc="$6" category="$7" tarball="$8"

  if type pre_install 2>/dev/null 1>&2; then
    log "INFO" "Running pre_install hook for $pkg"
    pre_install
  fi

  install_binary_pkg "$profile" "$pkg" "$version" "$tarball"
  record_manifest_from_tar "$profile" "$pkg" "$tarball"
  write_pkg_meta "$profile" "$pkg" "$version" "$desc" "$deps" "$libc" "$category"

  if type post_install 2>/dev/null 1>&2; then
    log "INFO" "Running post_install hook for $pkg"
    post_install
  fi
}

cmd_install() {
  local pkg="${1:-}"
  [ -n "$pkg" ] || die 1 "Usage: adm.sh install <pkg>"
  local profile
  profile="$(get_current_profile)"

  log "INFO" "Resolving dependencies for $pkg"
  local ordered dep
  ordered="$(resolve_dep_chain "$profile" "$pkg")"

  # First install all dependencies (excluding target)
  for dep in $ordered; do
    if [ "$dep" = "$pkg" ]; then
      continue
    fi
    if pkg_is_installed "$profile" "$dep"; then
      continue
    fi
    log "INFO" "Building dependency '$dep'"
    load_recipe "$dep"
    local dep_libc dep_tar dep_cat
    dep_libc="${PKG_LIBC:-$profile}"
    dep_cat="${PKG_CATEGORY:-uncategorized}"
    dep_tar="$(cmd_build "$dep")"
    cmd_install_one_from_tar "$profile" "$PKG_NAME" "$PKG_VERSION" "${PKG_DESC:-}" \
                              "${PKG_DEPENDS:-}" "$dep_libc" "$dep_cat" "$dep_tar"
  done

  # Now build + install target package
  log "INFO" "Building target package '$pkg'"
  load_recipe "$pkg"
  local libc pkg_tar cat
  libc="${PKG_LIBC:-$profile}"
  cat="${PKG_CATEGORY:-uncategorized}"
  pkg_tar="$(cmd_build "$pkg")"
  cmd_install_one_from_tar "$profile" "$PKG_NAME" "$PKG_VERSION" "${PKG_DESC:-}" \
                            "${PKG_DEPENDS:-}" "$libc" "$cat" "$pkg_tar"
}

cmd_remove() {
  local pkg="${1:-}"
  [ -n "$pkg" ] || die 1 "Usage: adm.sh remove <pkg>"
  local profile
  profile="$(get_current_profile)"
  if ! pkg_is_installed "$profile" "$pkg"; then
    die 1 "Package '$pkg' is not installed for profile '$profile'"
  fi

  local rdeps
  rdeps="$(pkg_reverse_deps "$profile" "$pkg" || true)"
  if [ -n "$rdeps" ]; then
    log "WARN" "Following packages depend on '$pkg':"
    echo "$rdeps"
    die 1 "Refusing to remove '$pkg' while reverse dependencies exist"
  fi

  log "INFO" "Removing package '$pkg' from profile '$profile'"
  remove_pkg_files "$profile" "$pkg"
}

cmd_update() {
  local pkg="${1:-}"
  [ -z "$pkg" ] && die 1 "Usage: adm.sh update <pkg>"
  local profile
  profile="$(get_current_profile)"
  if ! pkg_is_installed "$profile" "$pkg"; then
    die 1 "Package '$pkg' is not installed for profile '$profile'"
  fi
  log "INFO" "Updating package '$pkg'"
  # For simplicity, remove then reinstall.
  cmd_remove "$pkg"
  cmd_install "$pkg"
}

cmd_clean() {
  local what="${1:-all}"
  case "$what" in
    src|sources)
      rm -rf "$ADM_SRC_CACHE"/*
      log "INFO" "Source cache cleaned"
      ;;
    bin|binaries)
      rm -rf "$ADM_BIN_CACHE"/*
      log "INFO" "Binary cache cleaned"
      ;;
    build)
      rm -rf "$ADM_BUILD_DIR"/*
      log "INFO" "Build directory cleaned"
      ;;
    logs)
      rm -rf "$ADM_LOG_DIR"/*
      log "INFO" "Logs cleaned"
      ;;
    all)
      rm -rf "$ADM_SRC_CACHE"/* "$ADM_BIN_CACHE"/* "$ADM_BUILD_DIR"/* "$ADM_LOG_DIR"/*
      log "INFO" "All caches/build/logs cleaned"
      ;;
    *)
      die 1 "Unknown clean target '$what'"
      ;;
  esac
}

cmd_deps() {
  local pkg="${1:-}"
  [ -n "$pkg" ] || die 1 "Usage: adm.sh deps <pkg>"
  local profile
  profile="$(get_current_profile)"
  resolve_dep_chain "$profile" "$pkg"
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
  categoria/nome@v   (ex: core/bash@5.2)

Estrutura:
  ADM_ROOT           (default: ${ADM_ROOT_DEFAULT})
  Receitas:          \$ADM_ROOT/packages/<categoria>/<nome>-<versao>.sh
  DB de pacotes:     \$ADM_ROOT/db/<profile>/<PKG_NAME>.meta
  Rootfs do perfil:  \$ADM_ROOT/profiles/<profile>/rootfs
  Env do perfil:     \$ADM_ROOT/profiles/<profile>/env.sh (opcional)

Cada receita deve definir pelo menos:
  PKG_NAME, PKG_VERSION, PKG_DESC, PKG_DEPENDS (opcional),
  PKG_LIBC (opcional), PKG_CATEGORY (opcional – se omitido é inferido do path)

  build() {
    # Usa variáveis:
    #   \$PKG_BUILD_ROOT  -> DESTDIR temporário para empacotar
    #   \$PKG_BUILD_WORK  -> diretório de trabalho
    #   \$PKG_PROFILE     -> profile atual (glibc, musl, bootstrap, etc.)
    #   \$PKG_ROOTFS      -> rootfs final desse profile
    # Pode chamar fetch_source URL ARQUIVO para usar o cache de sources.
    # Exemplo típico:
    #   ./configure --prefix=/usr ...
    #   make
    #   make install DESTDIR="\$PKG_BUILD_ROOT"
  }

Hooks opcionais na receita:
  pre_build()  / post_build()
  pre_install()/ post_install()

Ambiente de profile:
  - PATH é automaticamente prefixado com:
      \$ADM_ROOT/profiles/<profile>/rootfs/tools/bin
      \$ADM_ROOT/profiles/<profile>/rootfs/usr/bin
      \$ADM_ROOT/profiles/<profile>/rootfs/bin
  - Se existir \$ADM_ROOT/profiles/<profile>/env.sh, ele é carregado
    automaticamente, permitindo exportar CC, CFLAGS, etc. por profile.
EOF
}

main() {
  init_logging
  load_config
  ensure_dir "$ADM_ROOT"

  local cmd="${1:-}"
  shift || true

  # Aplica o ambiente do profile antes de processar o comando
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
