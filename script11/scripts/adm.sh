#!/usr/bin/env bash
# adm.sh - Source-based package manager for Linux-from-scratch style systems
# Goal: clean builds in temporary dirs, cached sources, checksums, patches, hooks, binpkg cache,
# dependency resolution with cycle detection, safe-ish install/upgrade/remove with manifests,
# repo sync into /var/lib/adm/packages/<cat>/<name>/{build,files,patch}.
#
# Package layout:
#   /var/lib/adm/packages/<cat>/<name>/
#     build   (required)  - defines metadata + functions do_configure/do_build/do_install
#     patch/  (optional)  - *.patch/*.diff applied automatically
#     files/  (optional)  - overlay copied into DESTDIR
#
# Build script contract (build file):
#   PKG_NAME="busybox"
#   PKG_CAT="core"
#   PKG_VER="1.36.1"
#   PKG_DESC="..."
#   PKG_URL="..."
#   PKG_LICENSE="..."
#   PKG_DEPS=( "core/musl" "core/linux-headers" )     # runtime deps
#   PKG_BDEPS=( "core/meson" "core/ninja" )           # build deps (optional)
#   SOURCES=( "https://.../foo.tar.xz" "git+https://github.com/org/repo.git#commit=<sha>" )
#   SHA256SUMS=( "<sha256 for foo.tar.xz>" )          # for non-git only; OR MD5SUMS=()
#   # Optional: allow missing checksum for non-git (NOT recommended for toolchain)
#   ALLOW_NO_CHECKSUM=0
#   # Optional: conffiles for /etc preservation during install/upgrade
#   CONFFILES=( "/etc/fstab" "/etc/hostname" )
#   # Hooks (optional): hook_pre_fetch, hook_post_fetch, hook_pre_extract, hook_post_extract,
#   # hook_pre_patch, hook_post_patch, hook_pre_configure, hook_post_configure,
#   # hook_pre_build, hook_post_build, hook_pre_install, hook_post_install,
#   # hook_pre_package, hook_post_package
#   do_configure(){ ... }   # uses SRCTOP/WORKDIR, can do out-of-tree builds
#   do_build(){ ... }
#   do_install(){ ... }     # MUST install into DESTDIR (not real root)
#
# CLI:
#   adm sync
#   adm list | installed
#   adm search <term>
#   adm info <cat/name|name>
#   adm build <cat/name|name>        (only this pkg)
#   adm build-deps <cat/name|name>   (with deps)
#   adm install <cat/name|name>
#   adm upgrade <cat/name|name>
#   adm remove <cat/name|name>
#   adm world
#   adm clean [--work|--logs|--src|--bin|--all]
#
# Notes:
# - For "ROOT=/" installs, run as root.
# - Designed for your own distro tree, not a multi-user distro.

set -Eeuo pipefail

########################################
# Config / Paths
########################################
ADM_VERSION="1.0.0"

ADM_ROOT="${ADM_ROOT:-/var/lib/adm}"
PKGROOT="${ADM_ROOT}/packages"

CACHEDIR="${ADM_ROOT}/cache"
SRC_CACHE="${CACHEDIR}/sources"
GIT_CACHE="${CACHEDIR}/git"
BIN_CACHE="${CACHEDIR}/binpkgs"

WORKROOT="${ADM_ROOT}/work"
DBROOT="${ADM_ROOT}/db"
LOGROOT="${ADM_ROOT}/logs"
CONFROOT="${ADM_ROOT}/conf"
WORLD_FILE="${CONFROOT}/world"

OWNERS_DB="${DBROOT}/owners.db"  # "path<TAB>pkgid"

ROOT="${ROOT:-/}"

# Repo sync
ADM_REPO_URL="${ADM_REPO_URL:-}"
ADM_REPO_BRANCH="${ADM_REPO_BRANCH:-main}"

# Build
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
MAKEFLAGS="${MAKEFLAGS:--j${JOBS}}"

# Policy
ADM_PRESERVE_ETC="${ADM_PRESERVE_ETC:-1}"          # preserve /etc conffiles
ADM_STRICT_CHECKSUMS="${ADM_STRICT_CHECKSUMS:-1}"  # require checksums for non-git unless ALLOW_NO_CHECKSUM=1

# UI
COLOR="${COLOR:-1}"

########################################
# UI helpers
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
    "${PKGROOT}" "${SRC_CACHE}" "${GIT_CACHE}" "${BIN_CACHE}" \
    "${WORKROOT}" "${DBROOT}/installed" "${DBROOT}/manifests" "${DBROOT}/meta" \
    "${LOGROOT}" "${CONFROOT}"
  [[ -f "${WORLD_FILE}" ]] || : > "${WORLD_FILE}"
  [[ -f "${OWNERS_DB}" ]] || : > "${OWNERS_DB}"
}

load_conf(){
  local cf="${CONFROOT}/adm.conf"
  if [[ -f "${cf}" ]]; then
    # shellcheck disable=SC1090
    source "${cf}"
  fi
  ADM_REPO_URL="${ADM_REPO_URL:-${ADM_REPO_URL_DEFAULT:-}}"
  ADM_REPO_BRANCH="${ADM_REPO_BRANCH:-${ADM_REPO_BRANCH_DEFAULT:-main}}"
}

########################################
# Package id helpers
########################################
norm_pkgid(){
  local in="$1"
  if [[ "$in" == */* ]]; then
    echo "$in"
    return 0
  fi
  local hit
  hit="$(find "${PKGROOT}" -mindepth 2 -maxdepth 2 -type d -name "$in" 2>/dev/null | head -n1 || true)"
  [[ -n "${hit}" ]] || die "Pacote não encontrado: $in"
  echo "$(basename "$(dirname "$hit")")/$(basename "$hit")"
}

pkg_dir(){ echo "${PKGROOT}/$1"; }
pkg_buildfile(){ echo "$(pkg_dir "$1")/build"; }
pkg_patchdir(){ echo "$(pkg_dir "$1")/patch"; }
pkg_filesdir(){ echo "$(pkg_dir "$1")/files"; }

installed_marker(){ echo "${DBROOT}/installed/$1"; }
meta_path(){ echo "${DBROOT}/meta/$1.meta"; }
manifest_files_path(){ echo "${DBROOT}/manifests/$1.files"; }
manifest_dirs_path(){ echo "${DBROOT}/manifests/$1.dirs"; }

is_installed(){ [[ -f "$(installed_marker "$1")" ]]; }
installed_version(){ [[ -f "$(installed_marker "$1")" ]] && cat "$(installed_marker "$1")" || true; }

status_mark(){
  if is_installed "$1"; then printf "[ ✔️]"; else printf "[   ]"; fi
}

########################################
# Build script loading
########################################
reset_pkg_vars(){
  PKG_NAME=""; PKG_CAT=""; PKG_VER=""; PKG_DESC=""; PKG_URL=""; PKG_LICENSE=""
  PKG_DEPS=(); PKG_BDEPS=()
  SOURCES=()
  SHA256SUMS=(); MD5SUMS=()
  ALLOW_NO_CHECKSUM="${ALLOW_NO_CHECKSUM:-0}"
  CONFFILES=()
}

require_buildfile(){
  local pkgid="$1"
  local bf; bf="$(pkg_buildfile "$pkgid")"
  [[ -f "$bf" ]] || die "Build script ausente: $bf"
}

load_pkg(){
  local pkgid="$1"
  require_buildfile "$pkgid"
  reset_pkg_vars
  # shellcheck disable=SC1090
  source "$(pkg_buildfile "$pkgid")"

  [[ -n "${PKG_NAME}" ]] || die "PKG_NAME não definido em $(pkg_buildfile "$pkgid")"
  [[ -n "${PKG_CAT}"  ]] || PKG_CAT="${pkgid%%/*}"
  [[ -n "${PKG_VER}"  ]] || die "PKG_VER não definido em $(pkg_buildfile "$pkgid")"

  local have_sha=0 have_md5=0
  [[ ${#SHA256SUMS[@]} -gt 0 ]] && have_sha=1
  [[ ${#MD5SUMS[@]} -gt 0 ]] && have_md5=1
  if (( have_sha && have_md5 )); then
    die "Defina apenas um: SHA256SUMS ou MD5SUMS para ${pkgid}"
  fi

  declare -F do_configure >/dev/null 2>&1 || die "Função obrigatória ausente: do_configure (${pkgid})"
  declare -F do_build     >/dev/null 2>&1 || die "Função obrigatória ausente: do_build (${pkgid})"
  declare -F do_install   >/dev/null 2>&1 || die "Função obrigatória ausente: do_install (${pkgid})"
}

call_hook(){
  local fn="$1"
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn"
  fi
}

########################################
# Hash / Cache helpers
########################################
sha256_hex(){
  need_cmd sha256sum
  printf "%s" "$1" | sha256sum | awk '{print $1}'
}

is_git_source(){ [[ "$1" == git+* ]]; }

src_basename(){
  local url="$1"
  url="${url%%\#*}"
  url="${url%%\?*}"
  echo "${url##*/}"
}

src_cache_path_for(){
  # namespaced by pkgid/ver + hash(url) to avoid collisions
  local pkgid="$1" ver="$2" url="$3"
  local b; b="$(src_basename "$url")"
  local h; h="$(sha256_hex "$url")"
  echo "${SRC_CACHE}/${pkgid//\//_}/${ver}/${h}-${b}"
}

git_mirror_path_for(){
  local url="$1"
  local h; h="$(sha256_hex "$url")"
  echo "${GIT_CACHE}/${h}.mirror.git"
}

########################################
# Checksums
########################################
verify_checksum(){
  local algo="$1" file="$2" expected="$3"
  [[ -n "$expected" ]] || return 1
  case "$algo" in
    sha256) need_cmd sha256sum; echo "${expected}  ${file}" | sha256sum -c - >/dev/null ;;
    md5)    need_cmd md5sum;    echo "${expected}  ${file}" | md5sum -c - >/dev/null ;;
    *) die "Algoritmo checksum inválido: $algo" ;;
  esac
}

checksum_algo(){
  if [[ ${#SHA256SUMS[@]} -gt 0 ]]; then echo "sha256"; return 0; fi
  if [[ ${#MD5SUMS[@]} -gt 0 ]]; then echo "md5"; return 0; fi
  echo ""
}

########################################
# Fetch sources
########################################
fetch_http_like(){
  local url="$1" out="$2"
  need_cmd curl
  mkdir -p "$(dirname "$out")"
  if [[ -f "$out" ]]; then return 0; fi
  curl -L --fail --retry 5 --retry-delay 2 -o "${out}.part" "$url"
  mv -f "${out}.part" "$out"
}

parse_git_spec(){
  # input: git+URL#commit=...&tag=...&branch=...
  local spec="$1"
  local raw="${spec#git+}"
  local url="${raw%%\#*}"
  local frag=""
  [[ "$raw" == *"#"* ]] && frag="${raw#*#}"
  local commit="" ref=""
  IFS='&' read -r -a kvs <<< "$frag"
  for kv in "${kvs[@]}"; do
    [[ -z "$kv" ]] && continue
    case "$kv" in
      commit=*) commit="${kv#commit=}" ;;
      tag=*)    ref="${kv#tag=}" ;;
      branch=*) ref="${kv#branch=}" ;;
      ref=*)    ref="${kv#ref=}" ;;
    esac
  done
  printf "%s\n%s\n%s\n" "$url" "$commit" "$ref"
}

fetch_git_worktree(){
  local spec="$1" outdir="$2"
  need_cmd git

  local url commit ref
  url="$(parse_git_spec "$spec" | sed -n '1p')"
  commit="$(parse_git_spec "$spec" | sed -n '2p')"
  ref="$(parse_git_spec "$spec" | sed -n '3p')"

  # policy: strongly recommend pinned commit
  if [[ -z "$commit" ]]; then
    warn "Git source sem commit pinado. Recomenda-se: git+URL#commit=<sha> para reprodutibilidade."
  fi

  local mirror; mirror="$(git_mirror_path_for "$url")"
  mkdir -p "$(dirname "$mirror")"

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
    git -C "$outdir" checkout -q "$ref" 2>/dev/null || git -C "$outdir" checkout -q "tags/$ref" 2>/dev/null || true
  fi
  git -C "$outdir" rev-parse --verify HEAD >/dev/null
}

fetch_sources(){
  local pkgid="$1"
  call_hook hook_pre_fetch

  local algo; algo="$(checksum_algo)"
  local non_git_idx=0

  for s in "${SOURCES[@]}"; do
    if is_git_source "$s"; then
      continue
    fi

    local out; out="$(src_cache_path_for "$pkgid" "$PKG_VER" "$s")"
    local expected=""
    if [[ "$algo" == "sha256" ]]; then expected="${SHA256SUMS[$non_git_idx]:-}"; fi
    if [[ "$algo" == "md5"   ]]; then expected="${MD5SUMS[$non_git_idx]:-}"; fi

    if [[ "${ADM_STRICT_CHECKSUMS}" == "1" && "${ALLOW_NO_CHECKSUM:-0}" != "1" ]]; then
      [[ -n "$algo" && -n "$expected" ]] || die "Checksum obrigatório faltando para source[$non_git_idx] de ${pkgid}"
    fi

    if [[ -f "$out" ]]; then
      if [[ -n "$algo" && -n "$expected" ]]; then
        if verify_checksum "$algo" "$out" "$expected" 2>/dev/null; then
          ok "Cache ok: $(basename "$out")"
        else
          warn "Checksum falhou (cache). Rebaixando: $(basename "$out")"
          rm -f "$out"
          fetch_http_like "$s" "$out"
          [[ -n "$algo" && -n "$expected" ]] && verify_checksum "$algo" "$out" "$expected" || true
        fi
      else
        ok "Cache existente (sem checksum declarado): $(basename "$out")"
      fi
    else
      fetch_http_like "$s" "$out"
      [[ -n "$algo" && -n "$expected" ]] && verify_checksum "$algo" "$out" "$expected" || true
    fi

    non_git_idx=$((non_git_idx+1))
  done

  call_hook hook_post_fetch
}

########################################
# Extract / Patch / Overlay
########################################
extract_archive(){
  local file="$1" dst="$2"
  mkdir -p "$dst"
  local fn; fn="$(basename "$file")"
  case "$fn" in
    *.tar.gz|*.tgz)   tar -xzf "$file" -C "$dst" ;;
    *.tar.bz2|*.tbz2) tar -xjf "$file" -C "$dst" ;;
    *.tar.xz|*.txz)   tar -xJf "$file" -C "$dst" ;;
    *.tar.zst|*.tzst) need_cmd zstd; tar --use-compress-program=zstd -xf "$file" -C "$dst" ;;
    *.tar)            tar -xf "$file" -C "$dst" ;;
    *.zip)            need_cmd unzip; unzip -q "$file" -d "$dst" ;;
    *) die "Formato não suportado: $fn" ;;
  esac
}

extract_sources_into(){
  local pkgid="$1" workdir="$2"
  call_hook hook_pre_extract

  mkdir -p "$workdir/src"
  local non_git_idx=0
  for s in "${SOURCES[@]}"; do
    if is_git_source "$s"; then
      local gitdir="$workdir/src/git-${non_git_idx}"
      log "Clonando git -> $gitdir"
      fetch_git_worktree "$s" "$gitdir"
      non_git_idx=$((non_git_idx+1))
      continue
    fi

    local file; file="$(src_cache_path_for "$pkgid" "$PKG_VER" "$s")"
    [[ -f "$file" ]] || die "Source ausente no cache: $file"
    log "Extraindo: $(basename "$file")"
    extract_archive "$file" "$workdir/src"
  done

  call_hook hook_post_extract
}

pick_srctop(){
  local src="$1/src"
  local dirs=()
  while IFS= read -r d; do dirs+=("$d"); done < <(find "$src" -mindepth 1 -maxdepth 1 -type d | sort)
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
    local patches=()
    while IFS= read -r p; do patches+=("$p"); done < <(find "$pd" -maxdepth 1 -type f \( -name "*.patch" -o -name "*.diff" \) | sort)
    for p in "${patches[@]}"; do
      log "Patch: $(basename "$p")"
      patch -p1 -d "$srctop" < "$p"
    done
  fi

  call_hook hook_post_patch
}

copy_overlay_files(){
  local pkgid="$1" destdir="$2"
  local fd; fd="$(pkg_filesdir "$pkgid")"
  [[ -d "$fd" ]] || return 0
  log "Overlay files/ -> DESTDIR"
  ( cd "$fd" && tar -cpf - . ) | ( cd "$destdir" && tar -xpf - )
}

########################################
# Manifests / owners / collisions
########################################
make_manifests(){
  local destdir="$1" out_files="$2" out_dirs="$3"
  ( cd "$destdir" && find . \( -type f -o -type l \) -print | sort ) > "$out_files"
  ( cd "$destdir" && find . -type d -print | sort ) > "$out_dirs"
}

owners_db_has(){
  local path="$1"
  grep -F $'\t'"$path"$'\t' "${OWNERS_DB}" >/dev/null 2>&1
}

owners_db_owner(){
  local path="$1"
  awk -F'\t' -v p="$path" '$2==p {print $3; exit}' "${OWNERS_DB}" 2>/dev/null || true
}

owners_db_add_pkg(){
  local pkgid="$1" root="$2" mf_files="$3"
  # store absolute paths
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    local abs="${root}${rel#./}"
    abs="${abs%/}"
    # normalize: ensure starts with /
    abs="/${abs#/}"
    printf "%s\t%s\t%s\n" "$(ts)" "$abs" "$pkgid"
  done < "$mf_files" >> "${OWNERS_DB}"
}

owners_db_remove_pkg(){
  local pkgid="$1"
  # keep lines not matching pkgid
  local tmp="${OWNERS_DB}.tmp.$$"
  awk -F'\t' -v p="$pkgid" '$3!=p {print}' "${OWNERS_DB}" > "$tmp"
  mv -f "$tmp" "${OWNERS_DB}"
}

collision_check(){
  local pkgid="$1" root="$2" mf_files="$3"
  local collisions=0
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    local abs="${root}${rel#./}"
    abs="/${abs#/}"
    if owners_db_has "$abs"; then
      local owner; owner="$(owners_db_owner "$abs")"
      if [[ -n "$owner" && "$owner" != "$pkgid" ]]; then
        warn "Colisão de arquivo: $abs (dono: $owner) ao instalar $pkgid"
        collisions=$((collisions+1))
      fi
    fi
  done < "$mf_files"
  (( collisions == 0 )) || die "Colisões detectadas. Abortei instalação para proteger o sistema."
}

########################################
# Packaging
########################################
pkgfile_base(){ echo "${PKG_CAT}__${PKG_NAME}__${PKG_VER}"; }

package_destdir(){
  local pkgid="$1" destdir="$2" outdir="$3"
  call_hook hook_pre_package
  mkdir -p "$outdir"

  # embed manifests inside package root
  make_manifests "$destdir" "$destdir/.adm-manifest.files" "$destdir/.adm-manifest.dirs"

  local base; base="$(pkgfile_base)"
  local outzst="${outdir}/${base}.tar.zst"
  local outxz="${outdir}/${base}.tar.xz"

  if command -v zstd >/dev/null 2>&1; then
    log "Empacotando zstd: $(basename "$outzst")"
    ( cd "$destdir" && tar --numeric-owner -cpf - . ) | zstd -19 -T0 -q -o "$outzst"
    echo "$outzst"
  else
    warn "zstd ausente; fallback xz"
    need_cmd xz
    ( cd "$destdir" && tar --numeric-owner -cpf - . ) | xz -9e -T0 -c > "$outxz"
    echo "$outxz"
  fi
  call_hook hook_post_package
}

extract_pkg_to_staging(){
  local pkgfile="$1" staging="$2"
  rm -rf "$staging"
  mkdir -p "$staging"
  if [[ "$pkgfile" == *.tar.zst ]]; then
    need_cmd zstd
    zstd -dc "$pkgfile" | tar -xpf - -C "$staging"
  elif [[ "$pkgfile" == *.tar.xz ]]; then
    tar -xJpf "$pkgfile" -C "$staging"
  else
    die "Formato de binpkg não suportado: $pkgfile"
  fi
  [[ -f "$staging/.adm-manifest.files" ]] || die "Pacote sem manifest (files)."
  [[ -f "$staging/.adm-manifest.dirs"  ]] || die "Pacote sem manifest (dirs)."
}

########################################
# Conffiles handling (/etc preservation)
########################################
is_conffile(){
  local path="$1"
  local c
  for c in "${CONFFILES[@]:-}"; do
    [[ "$c" == "$path" ]] && return 0
  done
  return 1
}

install_staging_to_root(){
  local pkgid="$1" staging="$2" root="$3"
  # Install file-by-file to allow conffile preservation and avoid partial tar extraction to root
  # Directory creation first (skip "." and ".adm-*")
  while IFS= read -r d; do
    [[ "$d" == "." ]] && continue
    [[ "$d" == "./.adm-"* ]] && continue
    local rel="${d#./}"
    mkdir -p "${root}/${rel}"
  done < "$staging/.adm-manifest.dirs"

  # Files and symlinks
  while IFS= read -r f; do
    [[ "$f" == "./.adm-"* ]] && continue
    local rel="${f#./}"
    local dst="/${rel}"
    dst="${dst%/}"
    local abs="${root}${dst}"

    # conffile policy
    if [[ "${ADM_PRESERVE_ETC}" == "1" && "$dst" == /etc/* && is_conffile "$dst" ]]; then
      if [[ -e "$abs" ]]; then
        # if different, install as .adm-new
        if ! cmp -s "${staging}/${rel}" "$abs" 2>/dev/null; then
          warn "Preservando conffile existente: $dst (novo em ${dst}.adm-new)"
          cp -a -- "${staging}/${rel}" "${abs}.adm-new"
          continue
        else
          # same: overwrite OK
          :
        fi
      fi
    fi

    # ensure parent
    mkdir -p "$(dirname "$abs")"

    if [[ -L "${staging}/${rel}" ]]; then
      # replicate symlink
      rm -f "$abs"
      ln -s "$(readlink "${staging}/${rel}")" "$abs"
    else
      # regular file
      cp -a -- "${staging}/${rel}" "$abs"
    fi
  done < "$staging/.adm-manifest.files"
}

########################################
# Resume / stages (fixed)
########################################
# Stages in order:
STAGES=(fetch extract patch configure build install files package)

checkpoint_file(){ echo "${WORKROOT}/.${1//\//_}.checkpoint"; }

get_checkpoint(){
  local f; f="$(checkpoint_file "$1")"
  [[ -f "$f" ]] && cat "$f" || echo ""
}

set_checkpoint(){ echo "$2" > "$(checkpoint_file "$1")"; }
clear_checkpoint(){ rm -f "$(checkpoint_file "$1")"; }

stage_index(){
  local s="$1" i=0
  for x in "${STAGES[@]}"; do
    [[ "$x" == "$s" ]] && { echo "$i"; return 0; }
    i=$((i+1))
  done
  echo "-1"
}

run_stage(){
  local pkgid="$1" st="$2" logfile="$3"
  log "==> ${pkgid}: ${st}"
  set_checkpoint "$pkgid" "$st"
  # run in subshell with strict mode, append logs
  (
    set -Eeuo pipefail
    case "$st" in
      fetch)      call_hook hook_pre_fetch; fetch_sources "$pkgid"; call_hook hook_post_fetch ;;
      extract)    call_hook hook_pre_extract; extract_sources_into "$pkgid" "$WORKDIR"; call_hook hook_post_extract ;;
      patch)      call_hook hook_pre_patch; apply_patches "$pkgid" "$SRCTOP"; call_hook hook_post_patch ;;
      configure)  call_hook hook_pre_configure; do_configure; call_hook hook_post_configure ;;
      build)      call_hook hook_pre_build; do_build; call_hook hook_post_build ;;
      install)    call_hook hook_pre_install; do_install; call_hook hook_post_install ;;
      files)      copy_overlay_files "$pkgid" "$DESTDIR" ;;
      package)    PKGFILE="$(package_destdir "$pkgid" "$DESTDIR" "$BIN_CACHE")"; echo "PKGFILE=${PKGFILE}" ;;
      *)          die "Stage inválido: $st" ;;
    esac
  ) >>"$logfile" 2>&1
}

########################################
# Dependency resolution (cycle detect)
########################################
declare -A _vis _temp
declare -a _order

deps_of(){
  local pkgid="$1"
  load_pkg "$pkgid" >/dev/null 2>&1 || load_pkg "$pkgid"
  # Build deps + runtime deps to ensure build works
  printf "%s\n" "${PKG_BDEPS[@]:-}" "${PKG_DEPS[@]:-}"
}

dfs_visit(){
  local pkgid="$1"
  [[ -n "${_vis[$pkgid]:-}" ]] && return 0
  if [[ -n "${_temp[$pkgid]:-}" ]]; then
    die "Ciclo de dependências detectado em: $pkgid"
  fi
  _temp[$pkgid]=1

  local d
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    local depid; depid="$(norm_pkgid "$d")"
    dfs_visit "$depid"
  done < <(deps_of "$pkgid" || true)

  unset _temp[$pkgid]
  _vis[$pkgid]=1
  _order+=("$pkgid")
}

resolve_deps(){
  local pkgid="$1"
  _order=(); _vis=(); _temp=()
  dfs_visit "$pkgid"
  printf "%s\n" "${_order[@]}"
}

########################################
# Build pipeline
########################################
write_meta(){
  local pkgid="$1"
  local mp; mp="$(meta_path "$pkgid")"
  {
    echo "PKGID=$pkgid"
    echo "NAME=$PKG_NAME"
    echo "CAT=$PKG_CAT"
    echo "VER=$PKG_VER"
    echo "DESC=${PKG_DESC:-}"
    echo "URL=${PKG_URL:-}"
    echo "LICENSE=${PKG_LICENSE:-}"
    echo "BUILDTIME=$(ts)"
  } > "$mp"
}

build_one(){
  local pkgid; pkgid="$(norm_pkgid "$1")"
  require_buildfile "$pkgid"

  local work="${WORKROOT}/${pkgid//\//_}"
  local logfile="${LOGROOT}/${pkgid//\//_}__$(date +%Y%m%d_%H%M%S).log"
  rm -rf "$work"
  mkdir -p "$work"
  : > "$logfile"

  export PKGID="$pkgid"
  export WORKDIR="$work"
  export DESTDIR="$work/destdir"
  export SRCTOP="" SRCDIR=""
  mkdir -p "$DESTDIR"

  # load pkg definitions
  load_pkg "$pkgid"
  write_meta "$pkgid"

  ok "Build: ${PKG_CAT}/${PKG_NAME}-${PKG_VER}"
  log "Log: $logfile"

  # Determine resume point
  local cp; cp="$(get_checkpoint "$pkgid")"
  local start_idx=0
  if [[ -n "$cp" ]]; then
    local idx; idx="$(stage_index "$cp")"
    if [[ "$idx" -ge 0 ]]; then
      start_idx="$idx"
      warn "Retomando a partir do estágio: $cp"
    else
      warn "Checkpoint inválido encontrado; reiniciando pipeline."
      start_idx=0
    fi
  fi

  # Run ordered stages from start_idx onward
  local i
  for (( i=start_idx; i<${#STAGES[@]}; i++ )); do
    local st="${STAGES[$i]}"

    if [[ "$st" == "extract" ]]; then
      # extract sets SRCTOP
      run_stage "$pkgid" "$st" "$logfile"
      SRCTOP="$(pick_srctop "$WORKDIR")"
      export SRCTOP
      continue
    fi

    if [[ "$st" == "install" ]]; then
      # Ensure destdir clean
      rm -rf "$DESTDIR"
      mkdir -p "$DESTDIR"
    fi

    run_stage "$pkgid" "$st" "$logfile"
  done

  clear_checkpoint "$pkgid"
  ok "Build concluído: ${PKG_CAT}/${PKG_NAME}-${PKG_VER}"
}

build_with_deps(){
  local pkgid; pkgid="$(norm_pkgid "$1")"
  local list=()
  mapfile -t list < <(resolve_deps "$pkgid")
  local p
  for p in "${list[@]}"; do
    build_one "$p"
  done
}

########################################
# Install / Remove / Upgrade
########################################
find_binpkg(){
  local base; base="$(pkgfile_base)"
  if [[ -f "${BIN_CACHE}/${base}.tar.zst" ]]; then echo "${BIN_CACHE}/${base}.tar.zst"; return 0; fi
  if [[ -f "${BIN_CACHE}/${base}.tar.xz"  ]]; then echo "${BIN_CACHE}/${base}.tar.xz";  return 0; fi
  echo ""
}

install_pkg(){
  local pkgid; pkgid="$(norm_pkgid "$1")"
  load_pkg "$pkgid"

  local pkgfile; pkgfile="$(find_binpkg)"
  if [[ -z "$pkgfile" ]]; then
    warn "Binpkg ausente; build antes de instalar."
    build_one "$pkgid"
    pkgfile="$(find_binpkg)"
    [[ -n "$pkgfile" ]] || die "Binpkg não encontrado após build."
  fi

  local staging="${WORKROOT}/._staging_${pkgid//\//_}_$$"
  extract_pkg_to_staging "$pkgfile" "$staging"

  # collision check against owners db using staging manifest
  collision_check "$pkgid" "$ROOT" "$staging/.adm-manifest.files"

  # install to root with conffile policy
  install_staging_to_root "$pkgid" "$staging" "$ROOT"

  # write manifests to DB (absolute paths)
  local mf_files; mf_files="$(manifest_files_path "$pkgid")"
  local mf_dirs;  mf_dirs="$(manifest_dirs_path "$pkgid")"
  # store absolute-root-relative paths like "/usr/bin/..."
  sed 's|^\./|/|' "$staging/.adm-manifest.files" | sort -u > "$mf_files"
  sed 's|^\./|/|' "$staging/.adm-manifest.dirs"  | sort -u > "$mf_dirs"

  # update owners db
  owners_db_remove_pkg "$pkgid"
  owners_db_add_pkg "$pkgid" "" "$mf_files"  # stored with leading /

  # mark installed version
  echo "${PKG_VER}" > "$(installed_marker "$pkgid")"

  rm -rf "$staging"
  ok "Instalado: $pkgid $(status_mark "$pkgid")"
}

safe_dir_remove_allowed(){
  # protect critical shared roots
  local p="$1"
  case "$p" in
    /|/bin|/sbin|/usr|/usr/bin|/usr/sbin|/usr/lib|/usr/lib64|/lib|/lib64|/etc|/var|/var/lib|/home|/root|/tmp|/proc|/sys|/dev)
      return 1 ;;
    *)
      return 0 ;;
  esac
}

remove_pkg(){
  local pkgid; pkgid="$(norm_pkgid "$1")"
  is_installed "$pkgid" || die "Pacote não instalado: $pkgid"

  local mf_files; mf_files="$(manifest_files_path "$pkgid")"
  local mf_dirs;  mf_dirs="$(manifest_dirs_path "$pkgid")"
  [[ -f "$mf_files" ]] || die "Manifest files ausente: $mf_files"
  [[ -f "$mf_dirs"  ]] || die "Manifest dirs ausente: $mf_dirs"

  log "Removendo: $pkgid (ROOT=${ROOT})"

  # Remove files/symlinks
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ "$p" == "/.adm-"* ]] && continue
    if [[ -f "${ROOT}${p}" || -L "${ROOT}${p}" ]]; then
      rm -f -- "${ROOT}${p}" || true
    fi
  done < "$mf_files"

  # Remove dirs (only empty, no -p)
  tac "$mf_dirs" | while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    [[ "$d" == "/."* ]] && continue
    safe_dir_remove_allowed "$d" || continue
    if [[ -d "${ROOT}${d}" ]]; then
      rmdir --ignore-fail-on-non-empty "${ROOT}${d}" 2>/dev/null || true
    fi
  done

  # DB cleanup
  rm -f "$(installed_marker "$pkgid")" "$mf_files" "$mf_dirs" "$(meta_path "$pkgid")"
  owners_db_remove_pkg "$pkgid"

  ok "Removido: $pkgid"
}

upgrade_pkg(){
  local pkgid; pkgid="$(norm_pkgid "$1")"
  local oldver=""; oldver="$(installed_version "$pkgid")"
  build_one "$pkgid"
  install_pkg "$pkgid"
  if [[ -n "$oldver" ]]; then
    ok "Upgrade: $pkgid (${oldver} -> $(installed_version "$pkgid"))"
  else
    ok "Instalado: $pkgid"
  fi
}

########################################
# Repo sync
########################################
sync_repo(){
  [[ -n "${ADM_REPO_URL}" ]] || die "ADM_REPO_URL não definido. Configure em ${CONFROOT}/adm.conf."
  need_cmd git
  need_cmd rsync

  local repodir="${CACHEDIR}/repo"
  if [[ ! -d "$repodir/.git" ]]; then
    log "Clonando repo: ${ADM_REPO_URL}"
    git clone --branch "${ADM_REPO_BRANCH}" "${ADM_REPO_URL}" "$repodir"
  else
    log "Atualizando repo"
    git -C "$repodir" fetch --prune
    git -C "$repodir" checkout -q "${ADM_REPO_BRANCH}"
    git -C "$repodir" pull --ff-only
  fi

  local src="${repodir}/packages"
  [[ -d "$src" ]] || die "Repo não contém packages/ na raiz: $src"

  # safer sync: stage then swap
  local stage="${PKGROOT}.new.$$"
  rm -rf "$stage"
  mkdir -p "$stage"
  rsync -a --delete "${src}/" "${stage}/"
  rm -rf "${PKGROOT}.old.$$" 2>/dev/null || true
  mv -f "${PKGROOT}" "${PKGROOT}.old.$$" 2>/dev/null || true
  mv -f "$stage" "${PKGROOT}"
  rm -rf "${PKGROOT}.old.$$" 2>/dev/null || true

  ok "Sync concluído."
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

show_search(){
  local q="$1"
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    printf "%-45s %s\n" "$p" "$(status_mark "$p")"
  done < <(search_pkgs "$q")
}

show_info(){
  local pkgid; pkgid="$(norm_pkgid "$1")"
  local inst; inst="$(status_mark "$pkgid")"
  echo "Pacote: ${pkgid} ${inst}"
  if is_installed "$pkgid"; then
    echo "Instalado: sim"
    echo "Versão instalada: $(installed_version "$pkgid")"
  else
    echo "Instalado: não"
  fi

  # load build metadata
  load_pkg "$pkgid"
  echo "Nome: ${PKG_NAME}"
  echo "Categoria: ${PKG_CAT}"
  echo "Versão (build script): ${PKG_VER}"
  echo "Descrição: ${PKG_DESC:-}"
  echo "URL: ${PKG_URL:-}"
  echo "Licença: ${PKG_LICENSE:-}"
  echo "Build deps: ${PKG_BDEPS[*]:-}"
  echo "Deps: ${PKG_DEPS[*]:-}"
  echo "Sources: ${SOURCES[*]:-}"
}

show_installed(){
  local f
  find "${DBROOT}/installed" -maxdepth 1 -type f 2>/dev/null | sort | while IFS= read -r f; do
    local pkgid; pkgid="$(basename "$f")"
    printf "%-45s %s (ver=%s)\n" "$pkgid" "$(status_mark "$pkgid")" "$(cat "$f")"
  done
}

########################################
# World
########################################
world(){
  local pkgs=()
  mapfile -t pkgs < <(grep -vE '^\s*#|^\s*$' "${WORLD_FILE}" | sed 's/^\s*//; s/\s*$//')
  [[ ${#pkgs[@]} -gt 0 ]] || die "WORLD vazio. Edite ${WORLD_FILE}."

  local p
  for p in "${pkgs[@]}"; do
    local pkgid; pkgid="$(norm_pkgid "$p")"
    local order=()
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
# Clean
########################################
clean(){
  local mode="${1:---all}"
  case "$mode" in
    --work) rm -rf "${WORKROOT:?}/"*; ok "Work limpo" ;;
    --logs) rm -rf "${LOGROOT:?}/"*; ok "Logs limpos" ;;
    --src)  rm -rf "${SRC_CACHE:?}/"*; ok "Cache sources limpo" ;;
    --bin)  rm -rf "${BIN_CACHE:?}/"*; ok "Cache binpkgs limpo" ;;
    --all)  rm -rf "${WORKROOT:?}/"* "${LOGROOT:?}/"*; ok "Work+Logs limpos" ;;
    *) die "Uso: adm clean [--work|--logs|--src|--bin|--all]" ;;
  esac
}

########################################
# CLI
########################################
usage(){
  cat <<EOF
adm.sh ${ADM_VERSION}

Comandos:
  adm sync
  adm list
  adm installed
  adm search <termo>
  adm info <cat/name|name>
  adm build <cat/name|name>
  adm build-deps <cat/name|name>
  adm install <cat/name|name>
  adm upgrade <cat/name|name>
  adm remove <cat/name|name>
  adm world
  adm clean [--work|--logs|--src|--bin|--all]

Configuração:
  ${CONFROOT}/adm.conf:
    ADM_REPO_URL="https://.../repo.git"
    ADM_REPO_BRANCH="main"

EOF
}

main(){
  ensure_dirs
  load_conf

  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    sync)        sync_repo ;;
    list)        list_pkgs ;;
    installed)   show_installed ;;
    search)      [[ $# -ge 1 ]] || die "Uso: adm search <termo>"; show_search "$1" ;;
    info)        [[ $# -ge 1 ]] || die "Uso: adm info <cat/name|name>"; show_info "$1" ;;
    build)       [[ $# -ge 1 ]] || die "Uso: adm build <cat/name|name>"; build_one "$1" ;;
    build-deps)  [[ $# -ge 1 ]] || die "Uso: adm build-deps <cat/name|name>"; build_with_deps "$1" ;;
    install)     [[ $# -ge 1 ]] || die "Uso: adm install <cat/name|name>"; install_pkg "$1" ;;
    upgrade)     [[ $# -ge 1 ]] || die "Uso: adm upgrade <cat/name|name>"; upgrade_pkg "$1" ;;
    remove)      [[ $# -ge 1 ]] || die "Uso: adm remove <cat/name|name>"; remove_pkg "$1" ;;
    world)       world ;;
    clean)       clean "${1:---all}" ;;
    -h|--help|help) usage ;;
    *) die "Comando desconhecido: $cmd (use help)" ;;
  esac
}

main "$@"
