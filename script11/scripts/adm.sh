#!/usr/bin/env bash
# adm - Minimal, clean, source-based package/build manager for Linux-from-scratch style systems.
# Features:
# - Build scripts in /var/lib/adm/packages/<categoria>/<programa>/{build,files,patch}
# - Multi-source fetch: https/http/ftp/file/git/github/gitlab (git is just git URL)
# - Cache sources with checksum validation (sha256 or md5, declared in build script)
# - Automatic patch application from package patch/ directory (and/or declared patches)
# - Hooks (pre/post stages) declared in build script
# - Build in clean temp dir, install into DESTDIR, then package into tar.zst (fallback tar.xz)
# - Binary package cache, install/uninstall via manifest, upgrade is atomic-ish (new build succeeds first)
# - Dependency resolution with cycle detection, world rebuild
# - Full logs + registry, resumable via checkpoints
#
# Usage examples:
#   adm sync
#   adm search busybox
#   adm info core/busybox
#   adm build core/busybox
#   adm install core/busybox
#   adm upgrade core/busybox
#   adm remove core/busybox
#   adm world
#   adm clean --all
#
# Build script interface:
#   A package lives at: /var/lib/adm/packages/<cat>/<name>/
#     build        (required)  - shell fragment defining metadata + functions
#     patch/       (optional)  - *.patch applied automatically (sorted)
#     files/       (optional)  - file tree copied to DESTDIR with ownership/permissions (best-effort)
#
# In build script, define:
#   PKG_NAME="busybox"
#   PKG_CAT="core"
#   PKG_VER="1.36.1"
#   PKG_DESC="BusyBox provides many common UNIX utilities in a single small executable."
#   PKG_URL="https://busybox.net"
#   PKG_LICENSE="GPL-2.0"
#   PKG_DEPS=( "core/musl" "core/linux-headers" )
#   SOURCES=( "https://example.org/foo.tar.xz" "git+https://github.com/org/repo.git#tag=v1.2.3" )
#   # Checksums: specify exactly one of SHA256SUMS or MD5SUMS (array aligned to SOURCES, only for non-git)
#   SHA256SUMS=( "abcd..." "" )
#   # Hooks (optional): define any of the functions below:
#   #   hook_pre_fetch, hook_post_fetch, hook_pre_extract, hook_post_extract,
#   #   hook_pre_patch, hook_post_patch, hook_pre_configure, hook_post_configure,
#   #   hook_pre_build, hook_post_build, hook_pre_install, hook_post_install,
#   #   hook_pre_package, hook_post_package
#   # Required build functions:
#   do_configure(){ ... }
#   do_build(){ ... }
#   do_install(){ ... }   # must install into "$DESTDIR"
#
# Notes:
# - This script aims to be robust and clean; it cannot guarantee covering every upstream build system nuance.
# - Run as root only for install/remove if your rootfs needs it; build can be as unprivileged user if paths allow.

set -Eeuo pipefail

########################################
# Globals / Defaults
########################################
ADM_VERSION="0.7.0"

ADM_ROOT="/var/lib/adm"
PKGROOT="${ADM_ROOT}/packages"
CACHEDIR="${ADM_ROOT}/cache"              # sources + git mirrors + built packages
SRC_CACHE="${CACHEDIR}/sources"
GIT_CACHE="${CACHEDIR}/git"
BIN_CACHE="${CACHEDIR}/binpkgs"
WORKROOT="${ADM_ROOT}/work"               # temp build dirs
DBROOT="${ADM_ROOT}/db"                   # registry: installed, manifests, logs metadata
LOGROOT="${ADM_ROOT}/logs"                # build logs
CONFROOT="${ADM_ROOT}/conf"               # config
WORLD_FILE="${CONFROOT}/world"            # list of "cat/name" that form your system set

REPO_URL_DEFAULT=""   # set in /var/lib/adm/conf/adm.conf or via env ADM_REPO_URL
REPO_BRANCH_DEFAULT="main"
REPO_PATH_DEFAULT="${PKGROOT}"

NPROC_DEFAULT="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
JOBS="${JOBS:-$NPROC_DEFAULT}"
MAKEFLAGS_DEFAULT="-j${JOBS}"

COLOR="${COLOR:-1}"

umask 022

########################################
# UI / Logging
########################################
ts(){ date +"%Y-%m-%d %H:%M:%S"; }

c_reset=""; c_dim=""; c_red=""; c_grn=""; c_yel=""; c_blu=""
if [[ "${COLOR}" == "1" ]] && [[ -t 1 ]]; then
  c_reset=$'\033[0m'
  c_dim=$'\033[2m'
  c_red=$'\033[31m'
  c_grn=$'\033[32m'
  c_yel=$'\033[33m'
  c_blu=$'\033[34m'
fi

log(){  echo "${c_dim}[$(ts)]${c_reset} $*"; }
ok(){   echo "${c_grn}[$(ts)] OK${c_reset}  $*"; }
warn(){ echo "${c_yel}[$(ts)] WARN${c_reset} $*" >&2; }
die(){  echo "${c_red}[$(ts)] ERRO${c_reset} $*" >&2; exit 1; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Comando ausente: $1"; }

ensure_dirs(){
  mkdir -p \
    "${PKGROOT}" "${SRC_CACHE}" "${GIT_CACHE}" "${BIN_CACHE}" "${WORKROOT}" \
    "${DBROOT}/installed" "${DBROOT}/manifests" "${DBROOT}/meta" "${LOGROOT}" "${CONFROOT}"
  [[ -f "${WORLD_FILE}" ]] || : > "${WORLD_FILE}"
}

load_conf(){
  local cf="${CONFROOT}/adm.conf"
  if [[ -f "${cf}" ]]; then
    # shellcheck disable=SC1090
    source "${cf}"
  fi
  ADM_REPO_URL="${ADM_REPO_URL:-${REPO_URL_DEFAULT}}"
  ADM_REPO_BRANCH="${ADM_REPO_BRANCH:-${REPO_BRANCH_DEFAULT}}"
  ADM_REPO_PATH="${ADM_REPO_PATH:-${REPO_PATH_DEFAULT}}"
}

########################################
# Helpers: pkg id, paths
########################################
norm_pkgid(){
  # Accept "cat/name" or "name" (search resolves), return "cat/name"
  local in="$1"
  if [[ "$in" == */* ]]; then
    echo "$in"
    return 0
  fi
  # resolve first match by name
  local hit
  hit="$(find "${PKGROOT}" -mindepth 2 -maxdepth 2 -type d -name "$in" 2>/dev/null | head -n1 || true)"
  [[ -n "${hit}" ]] || die "Pacote não encontrado por nome: $in"
  echo "$(basename "$(dirname "$hit")")/$(basename "$hit")"
}

pkg_dir(){ echo "${PKGROOT}/$1"; }
pkg_buildfile(){ echo "$(pkg_dir "$1")/build"; }
pkg_patchdir(){ echo "$(pkg_dir "$1")/patch"; }
pkg_filesdir(){ echo "$(pkg_dir "$1")/files"; }

installed_marker(){ echo "${DBROOT}/installed/$1"; }        # file contains version string
manifest_path(){ echo "${DBROOT}/manifests/$1.manifest"; }  # list of installed files
meta_path(){ echo "${DBROOT}/meta/$1.meta"; }               # key=value info

is_installed(){ [[ -f "$(installed_marker "$1")" ]]; }

installed_version(){
  local m; m="$(installed_marker "$1")"
  [[ -f "$m" ]] && cat "$m" || true
}

status_mark(){
  # show [ ✔️] if installed
  if is_installed "$1"; then
    printf "[ ✔️]"
  else
    printf "[   ]"
  fi
}

########################################
# Build script loader + validation
########################################
reset_pkg_vars(){
  PKG_NAME=""; PKG_CAT=""; PKG_VER=""; PKG_DESC=""; PKG_URL=""; PKG_LICENSE=""
  PKG_DEPS=()
  SOURCES=()
  SHA256SUMS=()
  MD5SUMS=()
  # optional:
  PKG_EPOCH=""
  PKG_PROVIDES=()
}

require_pkg_buildfile(){
  local pkgid="$1"
  local bf; bf="$(pkg_buildfile "$pkgid")"
  [[ -f "$bf" ]] || die "Build script ausente: ${bf}"
}

load_pkg(){
  local pkgid="$1"
  require_pkg_buildfile "$pkgid"
  reset_pkg_vars
  # shellcheck disable=SC1090
  source "$(pkg_buildfile "$pkgid")"

  [[ -n "${PKG_NAME}" ]] || die "PKG_NAME não definido em $(pkg_buildfile "$pkgid")"
  [[ -n "${PKG_CAT}"  ]] || PKG_CAT="${pkgid%%/*}"
  [[ -n "${PKG_VER}"  ]] || die "PKG_VER não definido em $(pkg_buildfile "$pkgid")"

  # checksum policy: allow none for git-only packages; else require one array matching non-git sources
  local have_sha=0 have_md5=0
  [[ ${#SHA256SUMS[@]} -gt 0 ]] && have_sha=1
  [[ ${#MD5SUMS[@]} -gt 0 ]] && have_md5=1
  if (( have_sha && have_md5 )); then
    die "Defina apenas um: SHA256SUMS ou MD5SUMS (não ambos) para ${pkgid}"
  fi

  # required build functions
  declare -F do_configure >/dev/null 2>&1 || die "Função obrigatória ausente: do_configure (em ${pkgid})"
  declare -F do_build     >/dev/null 2>&1 || die "Função obrigatória ausente: do_build (em ${pkgid})"
  declare -F do_install   >/dev/null 2>&1 || die "Função obrigatória ausente: do_install (em ${pkgid})"
}

call_hook(){
  local fn="$1"
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn"
  fi
}

########################################
# Source fetching + verification
########################################
is_git_source(){
  # "git+URL#ref=..." or "git+URL#tag=..." etc
  [[ "$1" == git+* ]]
}

src_filename_from_url(){
  local url="$1"
  # strip query and fragments
  url="${url%%\#*}"
  url="${url%%\?*}"
  echo "${url##*/}"
}

verify_one_checksum(){
  local algo="$1" file="$2" expected="$3"
  [[ -n "$expected" ]] || return 0
  case "$algo" in
    sha256)
      need_cmd sha256sum
      echo "${expected}  ${file}" | sha256sum -c - >/dev/null
      ;;
    md5)
      need_cmd md5sum
      echo "${expected}  ${file}" | md5sum -c - >/dev/null
      ;;
    *)
      die "Algoritmo desconhecido: $algo"
      ;;
  esac
}

fetch_http_like(){
  local url="$1" out="$2"
  need_cmd curl
  mkdir -p "$(dirname "$out")"

  if [[ -f "$out" ]]; then
    return 0
  fi

  curl -L --fail --retry 5 --retry-delay 2 -o "${out}.part" "$url"
  mv -f "${out}.part" "$out"
}

fetch_git(){
  local spec="$1" outdir="$2"
  need_cmd git
  mkdir -p "$(dirname "$outdir")"

  # spec: git+<url>#key=val&key=val
  local raw="${spec#git+}"
  local url="${raw%%\#*}"
  local frag=""
  [[ "$raw" == *"#"* ]] && frag="${raw#*#}"

  # parse ref: tag=..., branch=..., ref=..., commit=...
  local ref=""
  local commit=""
  IFS='&' read -r -a kvs <<< "$frag"
  for kv in "${kvs[@]}"; do
    [[ -z "$kv" ]] && continue
    case "$kv" in
      tag=*)    ref="${kv#tag=}" ;;
      branch=*) ref="${kv#branch=}" ;;
      ref=*)    ref="${kv#ref=}" ;;
      commit=*) commit="${kv#commit=}" ;;
    esac
  done

  # Use a bare mirror cache for speed and offline-ish re-use
  local mirror="${GIT_CACHE}/$(echo -n "$url" | sed 's/[^a-zA-Z0-9._-]/_/g').mirror.git"
  if [[ ! -d "$mirror" ]]; then
    git clone --mirror "$url" "$mirror"
  else
    git -C "$mirror" fetch --prune --tags
  fi

  rm -rf "$outdir"
  git clone "$mirror" "$outdir"

  if [[ -n "$commit" ]]; then
    git -C "$outdir" checkout -q "$commit"
  elif [[ -n "$ref" ]]; then
    # try tag or branch
    git -C "$outdir" checkout -q "$ref" 2>/dev/null || git -C "$outdir" checkout -q "tags/$ref" 2>/dev/null || true
  fi

  # detach for reproducibility
  git -C "$outdir" rev-parse --verify HEAD >/dev/null
}

fetch_sources(){
  local pkgid="$1"
  call_hook hook_pre_fetch

  mkdir -p "${SRC_CACHE}"
  local algo=""
  if [[ ${#SHA256SUMS[@]} -gt 0 ]]; then algo="sha256"; fi
  if [[ ${#MD5SUMS[@]} -gt 0 ]]; then algo="md5"; fi

  local non_git_idx=0
  local i=0
  for s in "${SOURCES[@]}"; do
    if is_git_source "$s"; then
      # git sources are fetched during extract stage into work tree
      i=$((i+1))
      continue
    fi
    local fn; fn="$(src_filename_from_url "$s")"
    local out="${SRC_CACHE}/${fn}"

    # Cache logic: if file exists and checksum matches, keep it; else re-download
    if [[ -f "$out" ]] && [[ -n "$algo" ]]; then
      local expected=""
      if [[ "$algo" == "sha256" ]]; then expected="${SHA256SUMS[$non_git_idx]:-}"; fi
      if [[ "$algo" == "md5"   ]]; then expected="${MD5SUMS[$non_git_idx]:-}"; fi
      if [[ -n "$expected" ]]; then
        if verify_one_checksum "$algo" "$out" "$expected" 2>/dev/null; then
          ok "Cache ok: $fn"
        else
          warn "Checksum falhou (cache). Rebaixando: $fn"
          rm -f "$out"
          fetch_http_like "$s" "$out"
          verify_one_checksum "$algo" "$out" "$expected" || die "Checksum falhou após download: $fn"
        fi
      else
        # no expected checksum for this source; keep if exists
        ok "Cache existente (sem checksum declarado): $fn"
      fi
    else
      fetch_http_like "$s" "$out"
      if [[ -n "$algo" ]]; then
        local expected=""
        if [[ "$algo" == "sha256" ]]; then expected="${SHA256SUMS[$non_git_idx]:-}"; fi
        if [[ "$algo" == "md5"   ]]; then expected="${MD5SUMS[$non_git_idx]:-}"; fi
        [[ -n "$expected" ]] && verify_one_checksum "$algo" "$out" "$expected" || true
      fi
    fi
    non_git_idx=$((non_git_idx+1))
    i=$((i+1))
  done

  call_hook hook_post_fetch
}

########################################
# Extract + patch + files overlay
########################################
extract_sources_into(){
  local pkgid="$1" workdir="$2"
  call_hook hook_pre_extract

  mkdir -p "$workdir/src"
  local non_git_idx=0

  for s in "${SOURCES[@]}"; do
    if is_git_source "$s"; then
      local gitdir="$workdir/src/git-$non_git_idx"
      log "Clonando git: ${s}"
      fetch_git "$s" "$gitdir"
      non_git_idx=$((non_git_idx+1))
      continue
    fi

    local fn; fn="$(src_filename_from_url "$s")"
    local path="${SRC_CACHE}/${fn}"
    [[ -f "$path" ]] || die "Source ausente no cache (era esperado): $path"
    log "Extraindo: $fn"

    # Extract into workdir/src; support common formats
    case "$fn" in
      *.tar.gz|*.tgz)      tar -xzf "$path" -C "$workdir/src" ;;
      *.tar.bz2|*.tbz2)    tar -xjf "$path" -C "$workdir/src" ;;
      *.tar.xz|*.txz)      tar -xJf "$path" -C "$workdir/src" ;;
      *.tar.zst|*.tzst)    need_cmd zstd; tar --use-compress-program=zstd -xf "$path" -C "$workdir/src" ;;
      *.tar)               tar -xf "$path" -C "$workdir/src" ;;
      *.zip)               need_cmd unzip; unzip -q "$path" -d "$workdir/src" ;;
      *)
        die "Formato de source não suportado: $fn"
        ;;
    esac
  done

  call_hook hook_post_extract
}

pick_srctop(){
  local workdir="$1"
  # If only one directory exists under src, use it; else use src itself.
  local src="$workdir/src"
  local dirs
  mapfile -t dirs < <(find "$src" -mindepth 1 -maxdepth 1 -type d | sort)
  if [[ ${#dirs[@]} -eq 1 ]]; then
    echo "${dirs[0]}"
  else
    echo "$src"
  fi
}

apply_patches(){
  local pkgid="$1" srctop="$2"
  call_hook hook_pre_patch
  local pd; pd="$(pkg_patchdir "$pkgid")"
  if [[ -d "$pd" ]]; then
    local patches
    mapfile -t patches < <(find "$pd" -maxdepth 1 -type f -name "*.patch" -o -name "*.diff" | sort)
    if [[ ${#patches[@]} -gt 0 ]]; then
      for p in "${patches[@]}"; do
        log "Aplicando patch: $(basename "$p")"
        patch -p1 -d "$srctop" < "$p"
      done
    fi
  fi
  call_hook hook_post_patch
}

copy_files_overlay(){
  local pkgid="$1" destdir="$2"
  local fd; fd="$(pkg_filesdir "$pkgid")"
  [[ -d "$fd" ]] || return 0

  log "Copiando overlay files/ para DESTDIR"
  # Preserve modes and times best-effort; ownership depends on running user (usually root for real rootfs)
  # Use tar pipeline to preserve perms/links better than cp -a in edge cases.
  ( cd "$fd" && tar -cpf - . ) | ( cd "$destdir" && tar -xpf - )
}

########################################
# Packaging and manifests
########################################
pkg_id_with_ver(){
  echo "${PKG_CAT}/${PKG_NAME}-${PKG_VER}"
}

pkgfile_name(){
  # cat__name__ver.tar.zst or tar.xz
  echo "${PKG_CAT}__${PKG_NAME}__${PKG_VER}"
}

make_manifest(){
  local destdir="$1" out="$2"
  ( cd "$destdir" && find . -type f -o -type l -o -type d | sort ) > "$out"
}

package_destdir(){
  local pkgid="$1" destdir="$2" outdir="$3"
  call_hook hook_pre_package
  mkdir -p "$outdir"

  local base; base="$(pkgfile_name)"
  local outzst="${outdir}/${base}.tar.zst"
  local outxz="${outdir}/${base}.tar.xz"

  # Always include a manifest inside package root as .adm-manifest for later verification
  local mf_tmp="${destdir}/.adm-manifest"
  make_manifest "$destdir" "$mf_tmp"

  if command -v zstd >/dev/null 2>&1; then
    log "Empacotando (zstd): $(basename "$outzst")"
    ( cd "$destdir" && tar --numeric-owner -cpf - . ) | zstd -19 -T0 -q -o "$outzst"
    echo "$outzst"
  else
    warn "zstd não disponível; fallback para xz"
    need_cmd xz
    log "Empacotando (xz): $(basename "$outxz")"
    ( cd "$destdir" && tar --numeric-owner -cpf - . ) | xz -9e -T0 -c > "$outxz"
    echo "$outxz"
  fi

  call_hook hook_post_package
}

install_pkgfile(){
  local pkgfile="$1" root="${ROOT:-/}"
  [[ -f "$pkgfile" ]] || die "Pacote binário não encontrado: $pkgfile"

  # Extract to root
  if [[ "$pkgfile" == *.tar.zst ]]; then
    need_cmd zstd
    zstd -dc "$pkgfile" | tar -xpf - -C "$root"
  elif [[ "$pkgfile" == *.tar.xz ]]; then
    tar -xJpf "$pkgfile" -C "$root"
  else
    die "Formato de binpkg não suportado: $pkgfile"
  fi
}

########################################
# Dependency resolution with cycle detect
########################################
# We'll do DFS topo sort on pkg graph.
declare -A _vis _temp
declare -a _order

deps_of(){
  local pkgid="$1"
  load_pkg "$pkgid" >/dev/null 2>&1 || load_pkg "$pkgid"
  printf "%s\n" "${PKG_DEPS[@]:-}"
}

dfs_visit(){
  local pkgid="$1"
  [[ -n "${_vis[$pkgid]:-}" ]] && return 0
  if [[ -n "${_temp[$pkgid]:-}" ]]; then
    die "Ciclo de dependências detectado envolvendo: $pkgid"
  fi
  _temp[$pkgid]=1

  local d
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    # allow deps specified as "name" too
    local depid; depid="$(norm_pkgid "$d")"
    dfs_visit "$depid"
  done < <(deps_of "$pkgid" || true)

  unset _temp[$pkgid]
  _vis[$pkgid]=1
  _order+=("$pkgid")
}

resolve_deps(){
  local pkgid="$1"
  _order=()
  _vis=()
  _temp=()
  dfs_visit "$pkgid"
  # order includes pkgid last; return list
  printf "%s\n" "${_order[@]}"
}

########################################
# Build pipeline (resumable)
########################################
checkpoint_file(){
  local pkgid="$1"
  echo "${WORKROOT}/.${pkgid//\//_}.checkpoint"
}

set_checkpoint(){
  local pkgid="$1" stage="$2"
  echo "$stage" > "$(checkpoint_file "$pkgid")"
}

get_checkpoint(){
  local pkgid="$1"
  local f; f="$(checkpoint_file "$pkgid")"
  [[ -f "$f" ]] && cat "$f" || echo ""
}

clear_checkpoint(){
  rm -f "$(checkpoint_file "$1")"
}

run_stage(){
  local pkgid="$1" stage="$2" cmd="$3" logfile="$4"
  log "==> ${pkgid}: ${stage}"
  set_checkpoint "$pkgid" "$stage"
  ( set -Eeuo pipefail; eval "$cmd" ) > >(tee -a "$logfile") 2> >(tee -a "$logfile" >&2)
}

build_one(){
  local pkgid="$1"
  pkgid="$(norm_pkgid "$pkgid")"

  local bf; bf="$(pkg_buildfile "$pkgid")"
  [[ -f "$bf" ]] || die "Build script não encontrado: $bf"

  # Prepare work dir
  local work="${WORKROOT}/${pkgid//\//_}"
  local dest="${work}/destdir"
  local logfile="${LOGROOT}/${pkgid//\//_}__$(date +%Y%m%d_%H%M%S).log"

  mkdir -p "$work" "$dest"
  : > "$logfile"

  # Export build environment
  export MAKEFLAGS="${MAKEFLAGS:-$MAKEFLAGS_DEFAULT}"
  export JOBS="${JOBS}"
  export ROOT="${ROOT:-/}"          # install root for install/remove (default /)
  export WORKDIR="$work"
  export DESTDIR="$dest"
  export SRCDIR="" SRCTOP="" PKGID="$pkgid"
  export PATH="/usr/bin:/bin:${PATH}"

  # Load package metadata/functions
  load_pkg "$pkgid"

  ok "Iniciando build: ${PKG_CAT}/${PKG_NAME}-${PKG_VER}"
  log "Log: $logfile"

  # Resume logic
  local cp; cp="$(get_checkpoint "$pkgid")"
  [[ -n "$cp" ]] && warn "Retomando do estágio: $cp"

  # Pipeline:
  # fetch -> extract -> patch -> configure -> build -> install -> files overlay -> package
  local stage

  stage="fetch"
  if [[ "$cp" == "" || "$cp" == "$stage" ]]; then
    run_stage "$pkgid" "$stage" "fetch_sources '$pkgid'" "$logfile"
  fi

  stage="extract"
  if [[ "$cp" == "" || "$cp" == "$stage" ]]; then
    run_stage "$pkgid" "$stage" "extract_sources_into '$pkgid' '$work'" "$logfile"
  fi

  # determine srctop after extract
  SRCTOP="$(pick_srctop "$work")"
  export SRCTOP

  stage="patch"
  if [[ "$cp" == "" || "$cp" == "$stage" ]]; then
    run_stage "$pkgid" "$stage" "apply_patches '$pkgid' '$SRCTOP'" "$logfile"
  fi

  stage="configure"
  if [[ "$cp" == "" || "$cp" == "$stage" ]]; then
    run_stage "$pkgid" "$stage" "call_hook hook_pre_configure; do_configure; call_hook hook_post_configure" "$logfile"
  fi

  stage="build"
  if [[ "$cp" == "" || "$cp" == "$stage" ]]; then
    run_stage "$pkgid" "$stage" "call_hook hook_pre_build; do_build; call_hook hook_post_build" "$logfile"
  fi

  stage="install"
  if [[ "$cp" == "" || "$cp" == "$stage" ]]; then
    run_stage "$pkgid" "$stage" "rm -rf '$dest' && mkdir -p '$dest'; call_hook hook_pre_install; do_install; call_hook hook_post_install" "$logfile"
  fi

  stage="files"
  if [[ "$cp" == "" || "$cp" == "$stage" ]]; then
    run_stage "$pkgid" "$stage" "copy_files_overlay '$pkgid' '$dest'" "$logfile"
  fi

  stage="package"
  if [[ "$cp" == "" || "$cp" == "$stage" ]]; then
    local pkgfile=""
    run_stage "$pkgid" "$stage" "pkgfile=\$(package_destdir '$pkgid' '$dest' '${BIN_CACHE}'); echo \"PKGFILE=\$pkgfile\" >> '$logfile'" "$logfile"
  fi

  clear_checkpoint "$pkgid"
  ok "Build concluído: ${PKG_CAT}/${PKG_NAME}-${PKG_VER}"
  ok "Binpkg cache: ${BIN_CACHE}/$(pkgfile_name).tar.(zst|xz)"
}

build_with_deps(){
  local pkgid="$1"
  pkgid="$(norm_pkgid "$pkgid")"
  local list
  mapfile -t list < <(resolve_deps "$pkgid")
  local p
  for p in "${list[@]}"; do
    build_one "$p"
  done
}

########################################
# Install / Remove / Upgrade
########################################
write_meta(){
  local pkgid="$1"
  local mf="$2"
  local mp; mp="$(meta_path "$pkgid")"
  {
    echo "PKGID=$pkgid"
    echo "NAME=$PKG_NAME"
    echo "CAT=$PKG_CAT"
    echo "VER=$PKG_VER"
    echo "DESC=${PKG_DESC}"
    echo "URL=${PKG_URL}"
    echo "LICENSE=${PKG_LICENSE}"
    echo "BUILDTIME=$(ts)"
    echo "MANIFEST=$mf"
  } > "$mp"
}

install_pkg(){
  local pkgid="$1"
  pkgid="$(norm_pkgid "$pkgid")"
  load_pkg "$pkgid"

  local base; base="$(pkgfile_name)"
  local pkgfile=""
  if [[ -f "${BIN_CACHE}/${base}.tar.zst" ]]; then
    pkgfile="${BIN_CACHE}/${base}.tar.zst"
  elif [[ -f "${BIN_CACHE}/${base}.tar.xz" ]]; then
    pkgfile="${BIN_CACHE}/${base}.tar.xz"
  else
    warn "Binpkg não encontrado no cache; construindo antes de instalar..."
    build_one "$pkgid"
    if [[ -f "${BIN_CACHE}/${base}.tar.zst" ]]; then
      pkgfile="${BIN_CACHE}/${base}.tar.zst"
    elif [[ -f "${BIN_CACHE}/${base}.tar.xz" ]]; then
      pkgfile="${BIN_CACHE}/${base}.tar.xz"
    else
      die "Falha ao localizar binpkg após build: ${base}.tar.(zst|xz)"
    fi
  fi

  # Extract manifest from package (it contains .adm-manifest)
  local tmp="${WORKROOT}/._install_extract_${pkgid//\//_}_$$"
  rm -rf "$tmp"; mkdir -p "$tmp"
  if [[ "$pkgfile" == *.tar.zst ]]; then
    need_cmd zstd
    zstd -dc "$pkgfile" | tar -xpf - -C "$tmp" ./.adm-manifest >/dev/null 2>&1 || true
  else
    tar -xJpf "$pkgfile" -C "$tmp" ./.adm-manifest >/dev/null 2>&1 || true
  fi
  [[ -f "$tmp/.adm-manifest" ]] || warn "Manifest interno não encontrado; será gerado pós-instalação (menos ideal)."

  # Install to ROOT
  log "Instalando em ROOT=${ROOT:-/}: $(basename "$pkgfile")"
  install_pkgfile "$pkgfile" "${ROOT:-/}"

  # Write manifest: prefer internal; else generate by scanning ROOT paths is not safe; fallback is internal only.
  local mf; mf="$(manifest_path "$pkgid")"
  if [[ -f "$tmp/.adm-manifest" ]]; then
    # convert . in manifest to absolute paths relative to ROOT
    sed 's|^\.$|/|; s|^\./|/|' "$tmp/.adm-manifest" | sed 's|^/$|/|' | sort -u > "$mf"
  else
    warn "Sem manifest interno; uninstall pode ser impreciso. Recomendado corrigir o build para empacotar .adm-manifest."
    : > "$mf"
  fi
  rm -rf "$tmp"

  echo "${PKG_VER}" > "$(installed_marker "$pkgid")"
  write_meta "$pkgid" "$mf"

  ok "Instalado: $pkgid $(status_mark "$pkgid")"
}

remove_pkg(){
  local pkgid="$1"
  pkgid="$(norm_pkgid "$pkgid")"
  is_installed "$pkgid" || die "Pacote não está instalado: $pkgid"

  local mf; mf="$(manifest_path "$pkgid")"
  [[ -f "$mf" ]] || die "Manifest ausente para uninstall: $mf"

  local root="${ROOT:-/}"
  log "Removendo (ROOT=${root}): $pkgid"

  # Safety: never remove critical roots
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == "/" ]] && continue
    [[ "$line" == "/."* ]] && continue
    # Delete files/links first; dirs later
    if [[ -f "${root}${line}" || -L "${root}${line}" ]]; then
      rm -f -- "${root}${line}" || true
    fi
  done < "$mf"

  # Remove dirs in reverse depth order (only if empty)
  tac "$mf" | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == "/" ]] && continue
    if [[ -d "${root}${line}" ]]; then
      rmdir --ignore-fail-on-non-empty -p "${root}${line}" 2>/dev/null || true
    fi
  done

  rm -f "$(installed_marker "$pkgid")" "$(manifest_path "$pkgid")" "$(meta_path "$pkgid")"
  ok "Removido: $pkgid"
}

upgrade_pkg(){
  local pkgid="$1"
  pkgid="$(norm_pkgid "$pkgid")"
  local was_installed=0
  is_installed "$pkgid" && was_installed=1
  local oldver=""; oldver="$(installed_version "$pkgid")"

  # Build succeeds first
  build_one "$pkgid"

  # Install new
  install_pkg "$pkgid"

  # Only remove old after new installed is OK: we already replaced files by extracting.
  # If you want "remove old then install new", that is unsafe. The safe approach is: build ok, then install.
  # Cleanup old metadata is implicit because we overwrite markers/manifests.
  if (( was_installed )); then
    ok "Upgrade concluído: $pkgid (${oldver} -> ${PKG_VER})"
  else
    ok "Instalado (não havia versão anterior): $pkgid"
  fi
}

########################################
# Search / Info / List
########################################
list_pkgs(){
  find "${PKGROOT}" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | \
    awk -F/ '{print $(NF-1) "/" $NF}' | sort
}

search_pkgs(){
  local q="$1"
  list_pkgs | grep -i -- "$q" || true
}

show_info(){
  local pkgid="$1"
  pkgid="$(norm_pkgid "$pkgid")"
  load_pkg "$pkgid" >/dev/null 2>&1 || true
  local inst; inst="$(status_mark "$pkgid")"
  echo "Pacote: ${pkgid} ${inst}"
  if [[ -f "$(installed_marker "$pkgid")" ]]; then
    echo "Instalado: sim"
    echo "Versão instalada: $(installed_version "$pkgid")"
  else
    echo "Instalado: não"
  fi
  if [[ -n "${PKG_NAME:-}" ]]; then
    echo "Nome: ${PKG_NAME}"
    echo "Categoria: ${PKG_CAT}"
    echo "Versão: ${PKG_VER}"
    echo "Descrição: ${PKG_DESC:-}"
    echo "URL: ${PKG_URL:-}"
    echo "Licença: ${PKG_LICENSE:-}"
    echo "Deps: ${PKG_DEPS[*]:-}"
    echo "Sources: ${SOURCES[*]:-}"
  else
    echo "Aviso: não consegui carregar metadados do build script (verifique build)."
  fi
}

show_search(){
  local q="$1"
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    printf "%-40s %s\n" "$p" "$(status_mark "$p")"
  done < <(search_pkgs "$q")
}

show_list_installed(){
  local f
  find "${DBROOT}/installed" -type f -maxdepth 1 2>/dev/null | sort | while IFS= read -r f; do
    local pkgid; pkgid="$(basename "$f")"
    printf "%-40s %s  (ver=%s)\n" "$pkgid" "$(status_mark "$pkgid")" "$(cat "$f")"
  done
}

########################################
# Sync from repo into PKGROOT
########################################
sync_repo(){
  [[ -n "${ADM_REPO_URL}" ]] || die "ADM_REPO_URL não definido. Configure em ${CONFROOT}/adm.conf: ADM_REPO_URL=\"...\""
  need_cmd git

  mkdir -p "${CACHEDIR}"
  local repodir="${CACHEDIR}/repo"
  if [[ ! -d "$repodir/.git" ]]; then
    log "Clonando repo: ${ADM_REPO_URL}"
    git clone --branch "${ADM_REPO_BRANCH}" "${ADM_REPO_URL}" "$repodir"
  else
    log "Atualizando repo: ${ADM_REPO_URL}"
    git -C "$repodir" fetch --prune
    git -C "$repodir" checkout -q "${ADM_REPO_BRANCH}"
    git -C "$repodir" pull --ff-only
  fi

  # Sync packages into PKGROOT
  # Expect repo layout includes "packages/<cat>/<name>/..."
  local src="${repodir}/packages"
  [[ -d "$src" ]] || die "Repo não contém diretório packages/ na raiz: $src"
  log "Sincronizando scripts de build para: ${PKGROOT}"
  rsync -a --delete "${src}/" "${PKGROOT}/"
  ok "Sync concluído."
}

########################################
# Clean / Garbage collection
########################################
clean(){
  local mode="${1:-}"
  case "$mode" in
    --work)   rm -rf "${WORKROOT:?}/"*; ok "Work limpo: ${WORKROOT}" ;;
    --logs)   rm -rf "${LOGROOT:?}/"*; ok "Logs limpos: ${LOGROOT}" ;;
    --src)    rm -rf "${SRC_CACHE:?}/"*; ok "Cache de sources limpo: ${SRC_CACHE}" ;;
    --bin)    rm -rf "${BIN_CACHE:?}/"*; ok "Cache de binpkgs limpo: ${BIN_CACHE}" ;;
    --all|"")
      rm -rf "${WORKROOT:?}/"* "${LOGROOT:?}/"*
      ok "Work+Logs limpos."
      ;;
    *)
      die "Modo de limpeza inválido. Use: clean [--work|--logs|--src|--bin|--all]"
      ;;
  esac
}

########################################
# World rebuild (correct deps order)
########################################
world(){
  local pkgs=()
  mapfile -t pkgs < <(grep -vE '^\s*#|^\s*$' "${WORLD_FILE}" | sed 's/^\s*//; s/\s*$//' )
  [[ ${#pkgs[@]} -gt 0 ]] || die "WORLD vazio. Edite ${WORLD_FILE} e adicione linhas 'cat/name'."

  # Build + install each, with deps
  local p
  for p in "${pkgs[@]}"; do
    local pkgid; pkgid="$(norm_pkgid "$p")"
    local order
    mapfile -t order < <(resolve_deps "$pkgid")

    local x
    for x in "${order[@]}"; do
      build_one "$x"
      install_pkg "$x"
    done
  done

  ok "World concluído."
}

########################################
# CLI
########################################
usage(){
  cat <<EOF
adm ${ADM_VERSION}

Comandos:
  adm sync
  adm list
  adm installed
  adm search <termo>
  adm info <cat/name|name>
  adm build <cat/name|name>        (somente este pacote)
  adm build-deps <cat/name|name>   (com dependências, em ordem)
  adm install <cat/name|name>
  adm remove <cat/name|name>
  adm upgrade <cat/name|name>
  adm world                        (rebuild+install conjunto do arquivo world)
  adm clean [--work|--logs|--src|--bin|--all]

Configuração:
  Edite: ${CONFROOT}/adm.conf
    ADM_REPO_URL="https://.../seu-repo.git"
    ADM_REPO_BRANCH="main"

Layout de pacotes:
  ${PKGROOT}/<categoria>/<programa>/
    build
    patch/*.patch
    files/...

EOF
}

main(){
  ensure_dirs
  load_conf

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    sync)        sync_repo ;;
    list)        list_pkgs ;;
    installed)   show_list_installed ;;
    search)      [[ $# -ge 1 ]] || die "Uso: adm search <termo>"; show_search "$1" ;;
    info)        [[ $# -ge 1 ]] || die "Uso: adm info <cat/name|name>"; show_info "$1" ;;
    build)       [[ $# -ge 1 ]] || die "Uso: adm build <cat/name|name>"; build_one "$1" ;;
    build-deps)  [[ $# -ge 1 ]] || die "Uso: adm build-deps <cat/name|name>"; build_with_deps "$1" ;;
    install)     [[ $# -ge 1 ]] || die "Uso: adm install <cat/name|name>"; install_pkg "$1" ;;
    remove)      [[ $# -ge 1 ]] || die "Uso: adm remove <cat/name|name>"; remove_pkg "$1" ;;
    upgrade)     [[ $# -ge 1 ]] || die "Uso: adm upgrade <cat/name|name>"; upgrade_pkg "$1" ;;
    world)       world ;;
    clean)       clean "${1:-}" ;;
    -h|--help|help|"") usage ;;
    *) die "Comando desconhecido: $cmd (use --help)" ;;
  esac
}

main "$@"
