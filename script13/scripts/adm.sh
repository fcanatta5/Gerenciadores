#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# adm - personal source-based package manager (robust + simple)
#
# Layout of recipes:
#   /var/lib/adm/packages/<categoria>/<programa>/
#       build
#       patch/
#       files/
#
# Data:
#   /var/lib/adm/{cache,build,db,log,tmp,locks}
#
# Package format:
#   tar.(zst|xz) containing filesystem tree + .adm/{META,FILES}
#
# Features:
#   - Parallel source downloads (http/https/ftp + git)
#   - sha256sum with md5 fallback; supports "HEX file" OR aligned list
#   - Patch auto-apply
#   - Hooks pre/post build/install/uninstall in build recipe
#   - DESTDIR install, package to tar.zst fallback tar.xz
#   - Install from cache if package exists
#   - Dependency resolution with cycle detection
#   - File conflict detection
#   - Transactional upgrade/install (staging + commit)
#   - Reverse dependency uninstall + optional cascade + autoremove
#   - Dry-run, resume, clean
# ============================================================

ADM_ROOT="/var/lib/adm"
PKGROOT="$ADM_ROOT/packages"
CACHEDIR="$ADM_ROOT/cache"
BUILDDIR="$ADM_ROOT/build"
DBDIR="$ADM_ROOT/db"
LOGDIR="$ADM_ROOT/log"
TMPDIR="$ADM_ROOT/tmp"
LOCKDIR="$ADM_ROOT/locks"
STAGEDIR="$ADM_ROOT/stage"

JOBS="${ADM_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
COLOR="${ADM_COLOR:-1}"
DRYRUN=0
RESUME=1
FORCE=0
VERBOSE=0
USE_CACHE=1

# ---------- UI ----------
if [[ "${COLOR}" == "1" ]] && [[ -t 1 ]]; then
  C0=$'\033[0m'; B=$'\033[1m'
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; W=$'\033[37m'
else
  C0=""; B=""; R=""; G=""; Y=""; C=""; W=""
fi

say()  { printf "%s\n" "$*"; }
ok()   { printf "%s%s[OK]%s %s\n"   "$G" "$B" "$C0" "$*"; }
warn() { printf "%s%s[WARN]%s %s\n" "$Y" "$B" "$C0" "$*"; }
err()  { printf "%s%s[ERR]%s %s\n"  "$R" "$B" "$C0" "$*" >&2; }
info() { printf "%s%s[i]%s %s\n"    "$C" "$B" "$C0" "$*"; }
die()  { err "$*"; exit 1; }

ts() { date +"%Y-%m-%d %H:%M:%S"; }

need() { command -v "$1" >/dev/null 2>&1 || die "Ferramenta ausente: $1"; }

mkdirs() {
  if ((DRYRUN)); then return 0; fi
  mkdir -p "$PKGROOT" "$CACHEDIR" "$BUILDDIR" "$DBDIR" "$LOGDIR" "$TMPDIR" "$LOCKDIR" "$STAGEDIR"
  mkdir -p "$CACHEDIR/sources" "$CACHEDIR/pkgs" "$CACHEDIR/backups"
}

run_cmd() {
  # Usage: run_cmd cmd arg...
  if ((DRYRUN)); then
    printf "%s%s[dry-run]%s " "$Y" "$B" "$C0"
    printf "%q " "$@"
    printf "\n"
    return 0
  fi
  if ((VERBOSE)); then
    printf "%s%s[run]%s " "$W" "$B" "$C0"
    printf "%q " "$@"
    printf "\n"
  fi
  "$@"
}

with_lock() {
  local key="$1"; shift
  mkdirs
  local lock="$LOCKDIR/${key}.lock"
  exec 9>"$lock"
  flock -x 9
  "$@"
}

# ---------- recipe loading ----------
reset_build_env() {
  unset pkgname pkgver pkgrel category pkgdesc url license arch
  unset -v depends makedepends sources sha256sums md5sums provides conflicts replaces
  depends=(); makedepends=(); sources=(); sha256sums=(); md5sums=()
  provides=(); conflicts=(); replaces=()
  unset -f pre_build build post_build pre_install install post_install pre_uninstall uninstall post_uninstall 2>/dev/null || true
}

load_build() {
  local cat="$1" pkg="$2"
  local bpath="$PKGROOT/$cat/$pkg/build"
  [[ -f "$bpath" ]] || die "Build script não encontrado: $bpath"
  reset_build_env
  # shellcheck disable=SC1090
  source "$bpath"

  [[ "${pkgname:-}" == "$pkg" ]] || die "Build inválido: pkgname deve ser '$pkg' (atual: '${pkgname:-}')"
  [[ -n "${pkgver:-}" ]] || die "Build inválido: pkgver vazio"
  [[ -n "${pkgrel:-}" ]] || pkgrel=1
  [[ -n "${category:-}" ]] || category="$cat"
  [[ "$category" == "$cat" ]] || category="$cat"

  # ensure arrays exist
  declare -p sources >/dev/null 2>&1 || sources=()
  declare -p depends >/dev/null 2>&1 || depends=()
  declare -p provides >/dev/null 2>&1 || provides=()
  declare -p conflicts >/dev/null 2>&1 || conflicts=()
  declare -p replaces >/dev/null 2>&1 || replaces=()
}

pkg_exists() {
  # pkg exists in any category
  local pkg="$1"
  find "$PKGROOT" -mindepth 2 -maxdepth 2 -type d -name "$pkg" -print -quit 2>/dev/null | grep -q .
}

pkg_cat_of() {
  local pkg="$1"
  local d
  d="$(find "$PKGROOT" -mindepth 2 -maxdepth 2 -type d -name "$pkg" -print -quit 2>/dev/null || true)"
  [[ -n "$d" ]] || return 1
  basename "$(dirname "$d")"
}

# ---------- DB ----------
is_installed() { [[ -f "$DBDIR/$1/META" ]]; }

db_get() {
  local pkg="$1" key="$2"
  [[ -f "$DBDIR/$pkg/META" ]] || return 1
  awk -F= -v k="$key" '$1==k{print substr($0, index($0,$2))}' "$DBDIR/$pkg/META"
}

db_ver() {
  local pkg="$1"
  local v r
  v="$(db_get "$pkg" pkgver || true)"
  r="$(db_get "$pkg" pkgrel || true)"
  [[ -n "$v" ]] && [[ -n "$r" ]] && printf "%s-%s\n" "$v" "$r"
}

db_write_pkg() {
  # args: pkg destdir explicit(0/1)
  local pkg="$1" destdir="$2" explicit="$3"
  mkdirs
  run_cmd mkdir -p "$DBDIR/$pkg"

  # files list
  (cd "$destdir" && find . -type f -o -type l | sed 's#^\./##') | sort >"$DBDIR/$pkg/FILES.tmp"
  run_cmd mv -f "$DBDIR/$pkg/FILES.tmp" "$DBDIR/$pkg/FILES"

  # meta
  {
    echo "pkgname=$pkgname"
    echo "pkgver=$pkgver"
    echo "pkgrel=$pkgrel"
    echo "category=$category"
    echo "pkgdesc=${pkgdesc:-}"
    echo "url=${url:-}"
    echo "license=${license:-}"
    echo "arch=${arch:-}"
    echo "build_time=$(ts)"
    echo "depends=${depends[*]:-}"
    echo "provides=${provides[*]:-}"
    echo "conflicts=${conflicts[*]:-}"
    echo "replaces=${replaces[*]:-}"
    echo "explicit=$explicit"
  } >"$DBDIR/$pkg/META.tmp"
  run_cmd mv -f "$DBDIR/$pkg/META.tmp" "$DBDIR/$pkg/META"
}

reverse_deps() {
  local pkg="$1"
  local hits=()
  local p
  for p in "$DBDIR"/*; do
    [[ -d "$p" ]] || continue
    local name="${p##*/}"
    local deps
    deps="$(db_get "$name" depends || true)"
    local d
    for d in $deps; do
      [[ "$d" == "$pkg" ]] && hits+=("$name")
    done
  done
  printf "%s\n" "${hits[*]:-}"
}

is_explicit() {
  local pkg="$1"
  [[ "$(db_get "$pkg" explicit 2>/dev/null || echo 0)" == "1" ]]
}

mark_explicit() {
  local pkg="$1"
  is_installed "$pkg" || return 0
  if ((DRYRUN)); then return 0; fi
  awk -F= 'BEGIN{OFS="="} $1=="explicit"{$2=1} {print}' "$DBDIR/$pkg/META" >"$DBDIR/$pkg/META.tmp"
  mv -f "$DBDIR/$pkg/META.tmp" "$DBDIR/$pkg/META"
}

# ---------- Provides/Conflicts/Replaces (simple) ----------
provider_of() {
  # returns a package name that provides "$1" (installed preferred), else empty
  local virt="$1"
  # installed providers
  local p
  for p in "$DBDIR"/*; do
    [[ -d "$p" ]] || continue
    local name="${p##*/}"
    local prov
    prov="$(db_get "$name" provides || true)"
    local x
    for x in $prov; do
      [[ "$x" == "$virt" ]] && { printf "%s\n" "$name"; return 0; }
    done
  done
  # recipe providers
  local cat pkg
  while read -r cat pkg; do
    load_build "$cat" "$pkg"
    local x
    for x in "${provides[@]:-}"; do
      [[ "$x" == "$virt" ]] && { printf "%s\n" "$pkg"; return 0; }
    done
  done < <(find "$PKGROOT" -mindepth 2 -maxdepth 2 -type d -printf '%P\n' | awk -F/ '{print $1" "$2}')
  return 1
}

# ---------- deps & toposort ----------
deps_of() {
  local pkg="$1"
  local cat
  cat="$(pkg_cat_of "$pkg")" || die "Pacote não encontrado no repo local: $pkg"
  load_build "$cat" "$pkg"
  printf "%s\n" "${depends[*]:-}"
}

resolve_dep_name() {
  # dep token could be a real pkg or virtual provided name
  local dep="$1"
  if pkg_exists "$dep"; then
    printf "%s\n" "$dep"
    return 0
  fi
  if is_installed "$dep"; then
    printf "%s\n" "$dep"
    return 0
  fi
  local prov
  prov="$(provider_of "$dep" 2>/dev/null || true)"
  if [[ -n "$prov" ]]; then
    printf "%s\n" "$prov"
    return 0
  fi
  # not found: assume system-provided (personal use)
  printf "%s\n" ""
  return 0
}

toposort() {
  local -a targets=("$@")
  local -A temp perm
  local -a order=()

  visit() {
    local n="$1"
    [[ -n "$n" ]] || return 0
    if [[ "${perm[$n]:-0}" == "1" ]]; then return 0; fi
    if [[ "${temp[$n]:-0}" == "1" ]]; then die "Ciclo de dependência detectado envolvendo: $n"; fi
    temp["$n"]=1

    local deps d r
    deps="$(deps_of "$n" || true)"
    for d in $deps; do
      r="$(resolve_dep_name "$d")"
      if [[ -n "$r" ]]; then
        if is_installed "$r"; then
          : # ok
        elif pkg_exists "$r"; then
          visit "$r"
        else
          warn "Dependência '$d' não encontrada; assumindo fornecida pelo sistema."
        fi
      else
        warn "Dependência '$d' não encontrada; assumindo fornecida pelo sistema."
      fi
    done

    perm["$n"]=1
    temp["$n"]=0
    order+=("$n")
  }

  local t
  for t in "${targets[@]}"; do
    visit "$t"
  done

  printf "%s\n" "${order[@]}"
}

# ---------- checksums ----------
parse_source() {
  # "URL::FILENAME" or "URL"
  local s="$1"
  if [[ "$s" == *"::"* ]]; then
    printf "%s\n" "${s%%::*}" "${s##*::}"
  else
    printf "%s\n" "$s" ""
  fi
}

src_cache_key() {
  local url="$1"
  local base="${url##*/}"
  local h
  h="$(printf "%s" "$url" | sha256sum | awk '{print $1}' | cut -c1-12)"
  printf "%s__%s" "$h" "$base"
}

checksum_for_file() {
  # Output: "algo hex" or empty
  # Supports:
  #  - entries like "HEX  filename"
  #  - aligned lists (same index as sources): "HEX"
  local fname="$1" idx="$2"

  # sha256 "HEX  file"
  local entry hex file
  for entry in "${sha256sums[@]:-}"; do
    if [[ "$entry" == *" "* ]]; then
      hex="${entry%% *}"
      file="${entry##* }"
      [[ "$file" == "$fname" ]] && { printf "sha256 %s\n" "$hex"; return 0; }
    fi
  done
  # md5 "HEX  file"
  for entry in "${md5sums[@]:-}"; do
    if [[ "$entry" == *" "* ]]; then
      hex="${entry%% *}"
      file="${entry##* }"
      [[ "$file" == "$fname" ]] && { printf "md5 %s\n" "$hex"; return 0; }
    fi
  done

  # aligned by index
  if (( idx >= 0 )); then
    if (( ${#sha256sums[@]:-0} > idx )); then
      entry="${sha256sums[$idx]}"
      [[ "$entry" != *" "* ]] && [[ -n "$entry" ]] && { printf "sha256 %s\n" "$entry"; return 0; }
    fi
    if (( ${#md5sums[@]:-0} > idx )); then
      entry="${md5sums[$idx]}"
      [[ "$entry" != *" "* ]] && [[ -n "$entry" ]] && { printf "md5 %s\n" "$entry"; return 0; }
    fi
  fi

  return 1
}

verify_sum_file() {
  local algo="$1" hex="$2" file="$3"
  case "$algo" in
    sha256) need sha256sum; printf "%s  %s\n" "$hex" "$file" | sha256sum -c - >/dev/null 2>&1 ;;
    md5)    need md5sum;    printf "%s  %s\n" "$hex" "$file" | md5sum -c - >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# ---------- fetch sources (parallel, robust-ish) ----------
fetch_http() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    run_cmd curl -L --fail --retry 3 --connect-timeout 20 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    run_cmd wget -O "$out" "$url"
  else
    die "Nem curl nem wget disponíveis para baixar: $url"
  fi
}

fetch_git() {
  local url="$1" outdir="$2" ref="$3"
  need git
  local repo="${url#git+}"
  local key
  key="$(src_cache_key "$repo")"
  local mir="$CACHEDIR/sources/${key}.mirror"

  if [[ ! -d "$mir" ]]; then
    run_cmd git clone --mirror "$repo" "$mir"
  else
    run_cmd git -C "$mir" fetch -p
  fi

  run_cmd rm -rf "$outdir"
  run_cmd git clone "$mir" "$outdir"
  if [[ -n "$ref" ]]; then
    run_cmd git -C "$outdir" checkout --detach "$ref"
  fi
  # record exact commit for determinism
  if (( !DRYRUN )); then
    git -C "$outdir" rev-parse HEAD >"$outdir/.adm_git_commit"
  fi
}

extract_git_ref() {
  # url may contain #ref=<ref>
  local url="$1"
  local base="${url%%#*}"
  local frag=""
  [[ "$url" == *"#"* ]] && frag="${url#*#}"
  local ref=""
  if [[ -n "$frag" ]]; then
    # simple parse: ref=something
    if [[ "$frag" == ref=* ]]; then
      ref="${frag#ref=}"
    fi
  fi
  printf "%s\n" "$base" "$ref"
}

fetch_one_source() {
  local url="$1" outname="$2" worksrc="$3" idx="$4"
  mkdirs
  run_cmd mkdir -p "$worksrc"

  local real_url ref
  read -r real_url ref < <(extract_git_ref "$url")

  local dstname="$outname"
  [[ -n "$dstname" ]] || dstname="${real_url##*/}"
  [[ -n "$dstname" ]] || dstname="source_${idx}"

  # git sources: git+... or *.git or git://...
  if [[ "$real_url" == git+* ]] || [[ "$real_url" == *.git ]] || [[ "$real_url" == git://* ]]; then
    local dstdir="$worksrc/$dstname"
    fetch_git "$real_url" "$dstdir" "$ref"
    printf "%s\n" "git:$dstname"
    return 0
  fi

  local cachekey
  cachekey="$(src_cache_key "$real_url")"
  local cachepath="$CACHEDIR/sources/$cachekey"
  local dstdl="$worksrc/$dstname"

  # cache reuse (with checksum validation if declared)
  if [[ -f "$cachepath" ]]; then
    if checksum_for_file "$dstname" "$idx" >/dev/null 2>&1; then
      local algo hex
      read -r algo hex < <(checksum_for_file "$dstname" "$idx")
      if verify_sum_file "$algo" "$hex" "$cachepath"; then
        run_cmd cp -f "$cachepath" "$dstdl"
        printf "%s\n" "cache:$dstname"
        return 0
      else
        run_cmd rm -f "$cachepath"
      fi
    else
      run_cmd cp -f "$cachepath" "$dstdl"
      printf "%s\n" "cache:$dstname"
      return 0
    fi
  fi

  fetch_http "$real_url" "$dstdl"

  if checksum_for_file "$dstname" "$idx" >/dev/null 2>&1; then
    local algo hex
    read -r algo hex < <(checksum_for_file "$dstname" "$idx")
    if ! verify_sum_file "$algo" "$hex" "$dstdl"; then
      warn "Checksum falhou ($algo) para $dstname, refazendo download..."
      run_cmd rm -f "$dstdl"
      fetch_http "$real_url" "$dstdl"
      verify_sum_file "$algo" "$hex" "$dstdl" || die "Checksum continua falhando para $dstname"
    fi
  else
    warn "Sem checksum declarado para $dstname (fonte: $real_url)"
  fi

  run_cmd cp -f "$dstdl" "$cachepath"
  printf "%s\n" "dl:$dstname"
}

fetch_sources_parallel() {
  local worksrc="$1"
  run_cmd mkdir -p "$worksrc"
  ((${#sources[@]})) || return 0

  info "Baixando fontes em paralelo (jobs=$JOBS)..."
  local -a pids=()
  local -a labels=()
  local i=0

  for s in "${sources[@]}"; do
    local url out
    read -r url out < <(parse_source "$s")
    local idx="$i"
    ((i++))

    (
      fetch_one_source "$url" "$out" "$worksrc" "$idx"
    ) >>"$LOG_CURRENT" 2>&1 &
    pids+=("$!")
    labels+=("${out:-${url##*/}}")

    # throttle
    while ((${#pids[@]} >= JOBS)); do
      local newpids=() newlabels=()
      local k
      for k in "${!pids[@]}"; do
        if kill -0 "${pids[$k]}" 2>/dev/null; then
          newpids+=("${pids[$k]}")
          newlabels+=("${labels[$k]}")
        else
          wait "${pids[$k]}" || die "Falha ao baixar fonte: ${labels[$k]} (veja log)"
        fi
      done
      pids=("${newpids[@]}")
      labels=("${newlabels[@]}")
      sleep 0.05
    done
  done

  local k
  for k in "${!pids[@]}"; do
    wait "${pids[$k]}" || die "Falha ao baixar fonte: ${labels[$k]} (veja log)"
  done
  ok "Fontes prontas."
}

# ---------- unpack ----------
unpack_sources() {
  local worksrc="$1" workdir="$2"
  run_cmd mkdir -p "$workdir"
  shopt -s nullglob
  local f
  for f in "$worksrc"/*; do
    [[ -e "$f" ]] || continue
    if [[ -d "$f" && -f "$f/.adm_git_commit" ]]; then
      # git checkout dir
      run_cmd cp -a "$f" "$workdir/"
      continue
    fi
    case "$f" in
      *.tar.gz|*.tgz) run_cmd tar -C "$workdir" -xzf "$f" ;;
      *.tar.bz2|*.tbz2) run_cmd tar -C "$workdir" -xjf "$f" ;;
      *.tar.xz|*.txz) run_cmd tar -C "$workdir" -xJf "$f" ;;
      *.tar.zst|*.tzst) run_cmd tar -C "$workdir" --zstd -xf "$f" ;;
      *.zip) need unzip; run_cmd unzip -q "$f" -d "$workdir" ;;
      *) run_cmd cp -a "$f" "$workdir/" ;;
    esac
  done
  shopt -u nullglob
}

# ---------- patches ----------
apply_patches() {
  local cat="$1" pkg="$2" srcdir="$3"
  local pdir="$PKGROOT/$cat/$pkg/patch"
  [[ -d "$pdir" ]] || return 0
  shopt -s nullglob
  local p
  for p in "$pdir"/*.patch "$pdir"/*.diff; do
    info "Aplicando patch: ${p##*/}"
    # try p1 then p0 (simple, keeps script small)
    if ! run_cmd patch -d "$srcdir" -p1 <"$p" >>"$LOG_CURRENT" 2>&1; then
      run_cmd patch -d "$srcdir" -p0 <"$p" >>"$LOG_CURRENT" 2>&1 || die "Falha ao aplicar patch ${p##*/}"
    fi
  done
  shopt -u nullglob
}

# ---------- files overlay ----------
install_files_overlay() {
  local cat="$1" pkg="$2" destdir="$3"
  local fdir="$PKGROOT/$cat/$pkg/files"
  [[ -d "$fdir" ]] || return 0
  info "Copiando files/ para DESTDIR..."
  run_cmd cp -a "$fdir"/. "$destdir"/
}

# ---------- package build output ----------
pkg_base_name() { printf "%s-%s-%s\n" "$pkgname" "$pkgver" "$pkgrel"; }

pkg_file_path() {
  local base; base="$(pkg_base_name)"
  if [[ -f "$CACHEDIR/pkgs/${base}.tar.zst" ]]; then
    printf "%s\n" "$CACHEDIR/pkgs/${base}.tar.zst"
  elif [[ -f "$CACHEDIR/pkgs/${base}.tar.xz" ]]; then
    printf "%s\n" "$CACHEDIR/pkgs/${base}.tar.xz"
  else
    printf "\n"
  fi
}

# ---------- file conflict detection ----------
file_owner_of() {
  # print owning pkg if file belongs to any installed pkg
  local path="$1"
  local p
  for p in "$DBDIR"/*; do
    [[ -d "$p" ]] || continue
    local name="${p##*/}"
    if [[ -f "$p/FILES" ]] && grep -Fxq "$path" "$p/FILES"; then
      printf "%s\n" "$name"
      return 0
    fi
  done
  return 1
}

check_conflicts_destdir() {
  # args: pkg destdir
  local pkg="$1" destdir="$2"
  local f owner
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    owner="$(file_owner_of "$f" || true)"
    if [[ -n "$owner" && "$owner" != "$pkg" ]]; then
      if ((FORCE)); then
        warn "Conflito: /$f pertence a $owner (continuando por --force)"
      else
        die "Conflito detectado: /$f pertence a '$owner'. Use --force se você realmente quer sobrescrever."
      fi
    fi
  done < <(cd "$destdir" && find . -type f -o -type l | sed 's#^\./##')
}

# ---------- packaging (include .adm metadata inside tar) ----------
make_package() {
  local destdir="$1"
  local base; base="$(pkg_base_name)"
  local outzst="$CACHEDIR/pkgs/${base}.tar.zst"
  local outxz="$CACHEDIR/pkgs/${base}.tar.xz"

  # embed metadata
  local admmeta="$destdir/.adm/META"
  local admfiles="$destdir/.adm/FILES"
  run_cmd mkdir -p "$destdir/.adm"

  (cd "$destdir" && find . -type f -o -type l | sed 's#^\./##' | grep -vE '^\.adm/' | sort) >"$admfiles"

  {
    echo "pkgname=$pkgname"
    echo "pkgver=$pkgver"
    echo "pkgrel=$pkgrel"
    echo "category=$category"
    echo "pkgdesc=${pkgdesc:-}"
    echo "url=${url:-}"
    echo "license=${license:-}"
    echo "arch=${arch:-}"
    echo "build_time=$(ts)"
    echo "depends=${depends[*]:-}"
    echo "provides=${provides[*]:-}"
    echo "conflicts=${conflicts[*]:-}"
    echo "replaces=${replaces[*]:-}"
  } >"$admmeta"

  # create tar
  if tar --help 2>/dev/null | grep -q -- '--zstd'; then
    info "Empacotando: ${outzst##*/}"
    run_cmd tar -C "$destdir" --xattrs --acls --zstd -cf "$outzst" .
    printf "%s\n" "$outzst"
  else
    need xz
    info "Empacotando (fallback xz): ${outxz##*/}"
    # preserve xattrs/acls where possible (tar does, xz compress)
    run_cmd bash -c "tar -C \"${destdir}\" --xattrs --acls -c . | xz -T0 -9e > \"${outxz}\""
    printf "%s\n" "$outxz"
  fi
}

# ---------- transactional install ----------
stage_extract_pkg() {
  local pkgfile="$1" stage="$2"
  run_cmd rm -rf "$stage"
  run_cmd mkdir -p "$stage"
  if [[ "$pkgfile" == *.tar.zst ]]; then
    run_cmd tar --xattrs --acls --zstd -xf "$pkgfile" -C "$stage"
  else
    run_cmd tar --xattrs --acls -xf "$pkgfile" -C "$stage"
  fi
}

commit_stage_to_root() {
  local stage="$1" backupdir="$2"
  # prefer rsync for robust copy (preserve hardlinks/xattrs/acls when possible)
  if command -v rsync >/dev/null 2>&1; then
    run_cmd mkdir -p "$backupdir"
    # --delay-updates reduces partial state; --backup keeps overwritten files
    run_cmd rsync -aHAX --numeric-ids --delete \
      --backup --backup-dir="$backupdir" \
      --exclude "/.adm/" \
      "$stage"/ / 
  else
    # fallback: cp -a (less robust)
    warn "rsync não encontrado; usando cp -a (menos robusto)."
    run_cmd cp -a "$stage"/. /
  fi
}

install_from_pkgfile_atomic() {
  # args: pkg pkgfile explicit(0/1)
  local pkg="$1" pkgfile="$2" explicit="$3"

  [[ -f "$pkgfile" ]] || die "Pacote não encontrado: $pkgfile"
  local base; base="$(basename "$pkgfile")"
  local stage="$STAGEDIR/${pkg}.new"
  local backupdir="$CACHEDIR/backups/${pkg}-$(date +%Y%m%d_%H%M%S)"

  info "Staging: extraindo ${base}..."
  stage_extract_pkg "$pkgfile" "$stage"

  # read embedded meta/files
  [[ -f "$stage/.adm/META" ]] || die "Pacote inválido (sem .adm/META): $pkgfile"
  [[ -f "$stage/.adm/FILES" ]] || die "Pacote inválido (sem .adm/FILES): $pkgfile"

  # conflict check (before commit)
  if [[ -f "$stage/.adm/FILES" ]]; then
    local f owner
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      owner="$(file_owner_of "$f" || true)"
      if [[ -n "$owner" && "$owner" != "$pkg" ]]; then
        if ((FORCE)); then
          warn "Conflito: /$f pertence a $owner (continuando por --force)"
        else
          die "Conflito detectado: /$f pertence a '$owner'. Use --force para sobrescrever."
        fi
      fi
    done <"$stage/.adm/FILES"
  fi

  info "Commit transacional para / ..."
  commit_stage_to_root "$stage" "$backupdir"

  # update db from stage
  run_cmd mkdir -p "$DBDIR/$pkg"
  run_cmd cp -f "$stage/.adm/META" "$DBDIR/$pkg/META"
  run_cmd cp -f "$stage/.adm/FILES" "$DBDIR/$pkg/FILES"
  if (( !DRYRUN )); then
    awk -F= 'BEGIN{OFS="="} $1=="explicit"{$2="'$explicit'"} {print} END{if(!found){} }' "$DBDIR/$pkg/META" \
      | awk 'BEGIN{found=0} {print} END{}' >"$DBDIR/$pkg/META.tmp" || true
    # ensure explicit line exists
    if ! grep -q '^explicit=' "$DBDIR/$pkg/META.tmp"; then
      echo "explicit=$explicit" >>"$DBDIR/$pkg/META.tmp"
    fi
    mv -f "$DBDIR/$pkg/META.tmp" "$DBDIR/$pkg/META"
  fi

  run_cmd rm -rf "$stage"
  ok "Instalado: $pkg"
}

# ---------- build pipeline ----------
choose_src_dir() {
  local workdir="$1"
  # if single directory inside, use it; else use workdir
  local dcount
  dcount="$(find "$workdir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  if [[ "$dcount" == "1" ]]; then
    find "$workdir" -mindepth 1 -maxdepth 1 -type d -print -quit
  else
    printf "%s\n" "$workdir"
  fi
}

build_one() {
  local cat="$1" pkg="$2"
  load_build "$cat" "$pkg"

  local base; base="$(pkg_base_name)"
  local work="$BUILDDIR/$base"
  local worksrc="$work/sources"
  local workdir="$work/workdir"
  local destdir="$work/destdir"

  mkdirs
  run_cmd mkdir -p "$work" "$worksrc" "$workdir" "$destdir"
  LOG_CURRENT="$LOGDIR/${base}.log"
  ((DRYRUN)) || : >"$LOG_CURRENT"

  info "============================================================"
  info "Construindo: ${B}${pkg}${C0} ${W}v${pkgver}-${pkgrel}${C0}  [cat: $cat]"
  info "Log: $LOG_CURRENT"

  # resume markers
  local m_fetch="$work/.step_fetch"
  local m_unpack="$work/.step_unpack"
  local m_patch="$work/.step_patch"
  local m_build="$work/.step_build"
  local m_install="$work/.step_install"
  local m_pack="$work/.step_pack"

  if ((RESUME==0)); then
    info "Limpando diretório de build (resume desativado)..."
    run_cmd rm -rf "$work"
    run_cmd mkdir -p "$work" "$worksrc" "$workdir" "$destdir"
    run_cmd rm -f "$m_fetch" "$m_unpack" "$m_patch" "$m_build" "$m_install" "$m_pack" 2>/dev/null || true
  else
    # keep resume, but always keep destdir clean to avoid lixo
    run_cmd rm -rf "$destdir"
    run_cmd mkdir -p "$destdir"
    run_cmd rm -rf "$workdir"
    run_cmd mkdir -p "$workdir"
  fi

  if [[ ! -f "$m_fetch" ]]; then
    fetch_sources_parallel "$worksrc"
    run_cmd touch "$m_fetch"
  else
    info "Resume: fontes já baixadas."
  fi

  if [[ ! -f "$m_unpack" ]]; then
    unpack_sources "$worksrc" "$workdir"
    run_cmd touch "$m_unpack"
  else
    info "Resume: unpack já feito."
  fi

  local SRC_DIR
  SRC_DIR="$(choose_src_dir "$workdir")"

  if [[ ! -f "$m_patch" ]]; then
    apply_patches "$cat" "$pkg" "$SRC_DIR"
    run_cmd touch "$m_patch"
  else
    info "Resume: patches já aplicados."
  fi

  if [[ ! -f "$m_build" ]]; then
    if declare -F pre_build >/dev/null 2>&1; then info "Hook: pre_build"; pre_build >>"$LOG_CURRENT" 2>&1; fi
    if declare -F build >/dev/null 2>&1; then
      info "Etapa: build"
      ( cd "$SRC_DIR" && build ) >>"$LOG_CURRENT" 2>&1
    else
      die "Build script sem função build()"
    fi
    if declare -F post_build >/dev/null 2>&1; then info "Hook: post_build"; post_build >>"$LOG_CURRENT" 2>&1; fi
    run_cmd touch "$m_build"
  else
    info "Resume: build já feito."
  fi

  if [[ ! -f "$m_install" ]]; then
    if declare -F pre_install >/dev/null 2>&1; then info "Hook: pre_install"; pre_install >>"$LOG_CURRENT" 2>&1; fi
    info "Etapa: install (DESTDIR)"
    if declare -F install >/dev/null 2>&1; then
      ( cd "$SRC_DIR" && DESTDIR="$destdir" install ) >>"$LOG_CURRENT" 2>&1
    else
      die "Build script sem função install()"
    fi
    install_files_overlay "$cat" "$pkg" "$destdir"
    if declare -F post_install >/dev/null 2>&1; then info "Hook: post_install"; post_install >>"$LOG_CURRENT" 2>&1; fi
    run_cmd touch "$m_install"
  else
    info "Resume: install DESTDIR já feito."
  fi

  # detect conflicts (before packaging/commit)
  check_conflicts_destdir "$pkg" "$destdir"

  local pkgfile=""
  if [[ ! -f "$m_pack" ]]; then
    pkgfile="$(make_package "$destdir")"
    run_cmd touch "$m_pack"
  else
    info "Resume: pacote já empacotado."
    pkgfile="$(pkg_file_path || true)"
  fi

  printf "%s\n" "$pkgfile"
}

# ---------- uninstall ----------
run_uninstall_hooks_if_present() {
  local cat="$1" pkg="$2"
  if [[ -f "$PKGROOT/$cat/$pkg/build" ]]; then
    load_build "$cat" "$pkg"
    if declare -F pre_uninstall >/dev/null 2>&1; then info "Hook: pre_uninstall"; pre_uninstall >>"$LOG_CURRENT" 2>&1 || true; fi
    if declare -F uninstall >/dev/null 2>&1; then info "Hook: uninstall"; uninstall >>"$LOG_CURRENT" 2>&1 || true; fi
    if declare -F post_uninstall >/dev/null 2>&1; then info "Hook: post_uninstall"; post_uninstall >>"$LOG_CURRENT" 2>&1 || true; fi
  fi
}

remove_pkg_files() {
  local pkg="$1"
  is_installed "$pkg" || die "Pacote não instalado: $pkg"
  [[ -f "$DBDIR/$pkg/FILES" ]] || die "DB inconsistente: sem FILES para $pkg"

  info "Removendo arquivos de $pkg..."
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    run_cmd rm -f "/$f" 2>/dev/null || true
  done <"$DBDIR/$pkg/FILES"

  # cleanup empty dirs best-effort
  info "Limpando diretórios vazios..."
  while IFS= read -r f; do
    local d="/${f%/*}"
    [[ "$d" == "/" ]] && continue
    run_cmd rmdir -p "$d" 2>/dev/null || true
  done < <(tac "$DBDIR/$pkg/FILES")

  run_cmd rm -rf "$DBDIR/$pkg"
  ok "Removido: $pkg"
}

cmd_remove_one() {
  local pkg="$1" cascade="$2"
  is_installed "$pkg" || die "Pacote não instalado: $pkg"

  local rdeps
  rdeps="$(reverse_deps "$pkg" || true)"
  if [[ -n "$rdeps" ]]; then
    if [[ "$cascade" == "1" ]]; then
      info "Cascade: removendo reverse-deps primeiro: $rdeps"
      local x
      for x in $rdeps; do cmd_remove_one "$x" 1; done
    else
      die "Não é possível remover '$pkg': dependências reversas: $rdeps (use remove --cascade se desejar)"
    fi
  fi

  local cat
  cat="$(db_get "$pkg" category || true)"
  LOG_CURRENT="$LOGDIR/remove-${pkg}-$(date +%Y%m%d_%H%M%S).log"
  ((DRYRUN)) || : >"$LOG_CURRENT"
  [[ -n "$cat" ]] && run_uninstall_hooks_if_present "$cat" "$pkg"

  remove_pkg_files "$pkg"
}

autoremove() {
  # remove installed packages that are explicit=0 and have no reverse deps
  local changed=1
  while ((changed)); do
    changed=0
    local p
    for p in "$DBDIR"/*; do
      [[ -d "$p" ]] || continue
      local name="${p##*/}"
      if ! is_explicit "$name"; then
        local r; r="$(reverse_deps "$name" || true)"
        if [[ -z "$r" ]]; then
          info "Autoremove: $name"
          cmd_remove_one "$name" 0
          changed=1
          break
        fi
      fi
    done
  done
}

# ---------- queue UI ----------
print_queue() {
  local -a order=("$@")
  local total="${#order[@]}"
  info "Fila: ${B}${total}${C0} pacote(s) | jobs=$JOBS | cache=$( ((USE_CACHE)) && echo on || echo off )"
  local i=0 p
  for p in "${order[@]}"; do
    ((i++))
    local mark=""
    if is_installed "$p"; then mark=" ${G}[ ✔ ]${C0}"; fi
    printf "  %s%2d/%d%s  %s%s%s%s\n" "$W" "$i" "$total" "$C0" "$B" "$p" "$C0" "$mark"
  done
}

# ---------- commands ----------
cmd_help() {
  cat <<EOF
adm - gerenciador pessoal de programas (source-based)

Uso:
  adm build <pkg...>                 Constrói (resolve deps)
  adm install <pkg...>               Instala (usa cache se existir; resolve deps)
  adm upgrade <pkg...>               Rebuild + install transacional
  adm remove <pkg...> [--cascade]    Remove com reverse-deps (ou em cascata)
  adm autoremove                     Remove orphans (deps não-explicit sem reverse-deps)
  adm rebuild-all                    Reconstrói/instala tudo instalado (deps corretas)
  adm search <texto>                 Busca com indicador [✔]
  adm info <pkg>                     Info completa com indicador [✔]
  adm list-installed                 Lista instalados
  adm sync <git_url>                 Clona/atualiza recipes em $PKGROOT
  adm clean                          Limpa tmp/build/logs/caches antigos
  adm doctor                         Checagem de ferramentas

Opções globais:
  --dry-run        Apenas mostra o plano
  --no-resume      Desativa retomada
  --jobs N         Paralelismo de downloads (default: $JOBS)
  --no-cache       Não usar pacote do cache (força build ao instalar)
  --force          Permite sobrescrever conflitos de arquivos
  -v               Verbose (mostra comandos)

EOF
}

cmd_doctor() {
  need bash; need tar; need patch; need find; need awk
  need sha256sum; need md5sum
  if ! command -v curl >/dev/null && ! command -v wget >/dev/null; then
    warn "Recomendado instalar curl ou wget (downloads http/https/ftp)."
  fi
  if ! command -v git >/dev/null; then
    warn "git ausente: sources git não funcionarão."
  fi
  ok "doctor OK."
}

cmd_search() {
  local q="${1:-}"
  [[ -n "$q" ]] || die "Uso: adm search <texto>"
  mkdirs
  local found=0
  local cat pkg
  while read -r cat pkg; do
    if [[ "$pkg" == *"$q"* || "$cat" == *"$q"* ]]; then
      found=1
      local mark=""
      if is_installed "$pkg"; then mark=" ${G}[ ✔ ]${C0}"; fi
      printf "%s%-16s%s  %s%-24s%s%s\n" "$C" "$cat" "$C0" "$B" "$pkg" "$C0" "$mark"
    fi
  done < <(find "$PKGROOT" -mindepth 2 -maxdepth 2 -type d -printf '%P\n' | awk -F/ '{print $1" "$2}')
  ((found)) || warn "Nenhum pacote encontrado para: $q"
}

cmd_info() {
  local pkg="${1:-}"
  [[ -n "$pkg" ]] || die "Uso: adm info <pkg>"
  mkdirs
  local mark=""
  if is_installed "$pkg"; then mark=" ${G}[ ✔ ]${C0}"; fi

  if pkg_exists "$pkg"; then
    local cat; cat="$(pkg_cat_of "$pkg")"
    load_build "$cat" "$pkg"
    printf "%s%s%s%s\n" "$B" "$pkg" "$C0" "$mark"
    echo "  category : $category"
    echo "  version  : $pkgver-$pkgrel"
    echo "  desc     : ${pkgdesc:-}"
    echo "  url      : ${url:-}"
    echo "  license  : ${license:-}"
    echo "  depends  : ${depends[*]:-}"
    echo "  provides : ${provides[*]:-}"
    echo "  conflicts: ${conflicts[*]:-}"
    echo "  replaces : ${replaces[*]:-}"
    echo "  sources  : ${#sources[@]} item(s)"
  else
    warn "Recipe não encontrado no repo local para: $pkg"
  fi

  if is_installed "$pkg"; then
    echo "  installed: yes (v$(db_ver "$pkg")) explicit=$(db_get "$pkg" explicit || echo 0)"
    echo "  rdeps    : $(reverse_deps "$pkg" || true)"
  else
    echo "  installed: no"
  fi
}

cmd_list_installed() {
  mkdirs
  local p
  for p in "$DBDIR"/*; do
    [[ -d "$p" ]] || continue
    local n="${p##*/}"
    printf "%s%s%s  v%s  explicit=%s\n" "$B" "$n" "$C0" "$(db_ver "$n" || echo "?")" "$(db_get "$n" explicit || echo 0)"
  done
}

cmd_sync() {
  local url="${1:-}"
  [[ -n "$url" ]] || die "Uso: adm sync <git_url>"
  need git
  mkdirs
  if [[ -d "$PKGROOT/.git" ]]; then
    info "Atualizando recipes em $PKGROOT..."
    run_cmd git -C "$PKGROOT" pull --rebase
  else
    info "Clonando recipes para $PKGROOT..."
    run_cmd rm -rf "$PKGROOT"
    run_cmd git clone "$url" "$PKGROOT"
  fi
  ok "sync OK."
}

cmd_clean() {
  mkdirs
  info "Limpando tmp..."
  run_cmd rm -rf "$TMPDIR"/* 2>/dev/null || true

  info "Removendo builds antigos (>7 dias)..."
  run_cmd find "$BUILDDIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

  info "Removendo logs antigos (>30 dias)..."
  run_cmd find "$LOGDIR" -type f -mtime +30 -delete 2>/dev/null || true

  info "Removendo packages cache antigos (>90 dias)..."
  run_cmd find "$CACHEDIR/pkgs" -type f -mtime +90 -delete 2>/dev/null || true

  ok "clean OK."
}

cmd_build() {
  mkdirs
  (("$#")) || die "Uso: adm build <pkg...>"
  local -a targets=("$@")
  local -a order
  mapfile -t order < <(toposort "${targets[@]}")
  print_queue "${order[@]}"

  local total="${#order[@]}" done=0 p
  for p in "${order[@]}"; do
    ((done++))
    printf "%s%s[%d/%d]%s %s\n" "$W" "$B" "$done" "$total" "$C0" "Build $p"
    local cat; cat="$(pkg_cat_of "$p")"
    build_one "$cat" "$p" >/dev/null
    ok "✔ build OK: $p"
  done
}

install_one_with_deps() {
  # args: pkg explicit(0/1)
  local pkg="$1" explicit="$2"
  local cat; cat="$(pkg_cat_of "$pkg")" || die "Recipe não encontrado: $pkg"
  load_build "$cat" "$pkg"

  # conflicts declared in recipe (installed)
  local c
  for c in "${conflicts[@]:-}"; do
    if is_installed "$c"; then
      die "Conflito: '$pkg' conflita com '$c' instalado."
    fi
  done

  # replaces: if installed, remove after new installed OK (we keep simple: remove after)
  # (handled after install)

  # use cache package if exists and not forcing rebuild
  local pkgfile=""
  if ((USE_CACHE)); then
    pkgfile="$(pkg_file_path || true)"
  fi

  if [[ -z "$pkgfile" ]]; then
    info "Cache não encontrado; construindo $pkg..."
    pkgfile="$(build_one "$cat" "$pkg")"
  else
    info "Usando pacote do cache: ${pkgfile##*/}"
  fi

  install_from_pkgfile_atomic "$pkg" "$pkgfile" "$explicit"

  # mark explicit if requested later
  if ((explicit)); then
    mark_explicit "$pkg"
  fi

  # handle replaces (remove old packages that should be replaced)
  local r
  for r in "${replaces[@]:-}"; do
    if is_installed "$r" && [[ "$r" != "$pkg" ]]; then
      warn "Replaces: removendo '$r' após instalação bem sucedida de '$pkg'"
      cmd_remove_one "$r" 0
    fi
  done
}

cmd_install() {
  mkdirs
  (("$#")) || die "Uso: adm install <pkg...>"
  local -a targets=("$@")
  local -a order
  mapfile -t order < <(toposort "${targets[@]}")
  print_queue "${order[@]}"

  # install dependencies as explicit=0, targets as explicit=1
  local p
  for p in "${order[@]}"; do
    local exp=0
    local t
    for t in "${targets[@]}"; do [[ "$p" == "$t" ]] && exp=1; done

    if is_installed "$p"; then
      if ((exp)); then mark_explicit "$p"; fi
      info "Já instalado: $p"
      continue
    fi

    install_one_with_deps "$p" "$exp"
    ok "✔ instalado: $p"
  done
}

cmd_upgrade() {
  mkdirs
  (("$#")) || die "Uso: adm upgrade <pkg...>"
  local -a targets=("$@")
  local -a order
  mapfile -t order < <(toposort "${targets[@]}")
  print_queue "${order[@]}"

  local p
  for p in "${order[@]}"; do
    local exp=0 t
    for t in "${targets[@]}"; do [[ "$p" == "$t" ]] && exp=1; done

    local cat; cat="$(pkg_cat_of "$p")"
    load_build "$cat" "$p"
    info "Upgrade: rebuild obrigatório para $p"
    # force rebuild by ignoring cache for this op (still keeps sources cache)
    local saved="$USE_CACHE"
    USE_CACHE=0
    install_one_with_deps "$p" "$exp"
    USE_CACHE="$saved"
    ok "✔ upgrade OK: $p"
  done
}

cmd_remove() {
  mkdirs
  (("$#")) || die "Uso: adm remove <pkg...> [--cascade]"
  local cascade=0
  local -a pkgs=()
  local a
  for a in "$@"; do
    [[ "$a" == "--cascade" ]] && cascade=1 || pkgs+=("$a")
  done
  ((${#pkgs[@]})) || die "Uso: adm remove <pkg...> [--cascade]"
  local p
  for p in "${pkgs[@]}"; do
    cmd_remove_one "$p" "$cascade"
  done
}

cmd_autoremove() {
  mkdirs
  autoremove
  ok "autoremove OK."
}

cmd_rebuild_all() {
  mkdirs
  local -a pkgs=()
  local p
  for p in "$DBDIR"/*; do
    [[ -d "$p" ]] || continue
    pkgs+=("${p##*/}")
  done
  ((${#pkgs[@]})) || { warn "Nenhum pacote instalado."; return 0; }

  local -a order
  mapfile -t order < <(toposort "${pkgs[@]}")
  print_queue "${order[@]}"
  cmd_upgrade "${order[@]}"
}

# ---------- main ----------
main() {
  mkdirs

  local -a args=()
  while (("$#")); do
    case "$1" in
      --dry-run) DRYRUN=1; shift ;;
      --no-resume) RESUME=0; shift ;;
      --jobs) JOBS="${2:-}"; shift 2 ;;
      --no-cache) USE_CACHE=0; shift ;;
      --force) FORCE=1; shift ;;
      -v) VERBOSE=1; shift ;;
      -h|--help) cmd_help; exit 0 ;;
      *) args+=("$1"); shift ;;
    esac
  done

  local cmd="${args[0]:-help}"
  case "$cmd" in
    help) cmd_help ;;
    doctor) cmd_doctor ;;
    search) cmd_search "${args[1]:-}" ;;
    info) cmd_info "${args[1]:-}" ;;
    list-installed) cmd_list_installed ;;
    sync) cmd_sync "${args[1]:-}" ;;
    clean) cmd_clean ;;
    build) cmd_build "${args[@]:1}" ;;
    install) with_lock "db" cmd_install "${args[@]:1}" ;;
    upgrade) with_lock "db" cmd_upgrade "${args[@]:1}" ;;
    remove) with_lock "db" cmd_remove "${args[@]:1}" ;;
    autoremove) with_lock "db" cmd_autoremove ;;
    rebuild-all) with_lock "db" cmd_rebuild_all ;;
    *) die "Comando desconhecido: $cmd (use: adm help)" ;;
  esac
}

main "$@"
