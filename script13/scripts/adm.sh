#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# adm - Package Manager (Bash)
# Layout:
#   /var/lib/adm/packages/<cat>/<pkg>/{build,patch/,files/}
# Stores:
#   /var/lib/adm/{repo,cache,build,db,log,tmp,locks}
# ============================================================

ADM_ROOT="/var/lib/adm"
PKGROOT="$ADM_ROOT/packages"
REPOROOT="$ADM_ROOT/repo"
CACHEDIR="$ADM_ROOT/cache"
BUILDDIR="$ADM_ROOT/build"
DBDIR="$ADM_ROOT/db"
LOGDIR="$ADM_ROOT/log"
TMPDIR="$ADM_ROOT/tmp"
LOCKDIR="$ADM_ROOT/locks"

JOBS="${ADM_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
COLOR="${ADM_COLOR:-1}"
DRYRUN=0
RESUME=1

# ---------- UI ----------
if [[ "${COLOR}" == "1" ]] && [[ -t 1 ]]; then
  C0=$'\033[0m'; B=$'\033[1m'
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; W=$'\033[37m'
else
  C0=""; B=""; R=""; G=""; Y=""; C=""; W=""
fi

ok()   { printf "%s%s[OK]%s %s\n"   "$G" "$B" "$C0" "$*"; }
warn() { printf "%s%s[WARN]%s %s\n" "$Y" "$B" "$C0" "$*"; }
err()  { printf "%s%s[ERR]%s %s\n"  "$R" "$B" "$C0" "$*" >&2; }
info() { printf "%s%s[i]%s %s\n"    "$C" "$B" "$C0" "$*"; }

die() { err "$*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Ferramenta ausente: $1"; }

run() {
  if ((DRYRUN)); then
    printf "%s%s[dry-run]%s %s\n" "$Y" "$B" "$C0" "$*"
    return 0
  fi
  eval "$@"
}

mkdirs() { run "mkdir -p '$PKGROOT' '$REPOROOT' '$CACHEDIR' '$BUILDDIR' '$DBDIR' '$LOGDIR' '$TMPDIR' '$LOCKDIR'"; }

# ---------- Lock ----------
with_lock() {
  local key="$1"; shift
  mkdirs
  local lock="$LOCKDIR/${key}.lock"
  exec 9>"$lock"
  flock -x 9
  "$@"
}

# ---------- Utils ----------
ts() { date +"%Y-%m-%d %H:%M:%S"; }

is_installed() { [[ -f "$DBDIR/$1/meta" ]]; }

installed_ver() {
  [[ -f "$DBDIR/$1/meta" ]] || return 1
  awk -F= '$1=="pkgver"{print $2}' "$DBDIR/$1/meta"
}

meta_get() {
  local pkg="$1" key="$2"
  [[ -f "$DBDIR/$pkg/meta" ]] || return 1
  awk -F= -v k="$key" '$1==k{print $2}' "$DBDIR/$pkg/meta"
}

# ---------- Build script loading ----------
# Build script contract:
# Required vars:
#   pkgname pkgver pkgrel category
# Optional:
#   pkgdesc url license arch
#   depends=(...) makedepends=(...)
# Sources:
#   sources=( "URL[::FILENAME]" ... )
# Checksums (either/both accepted):
#   sha256sums=( "HEX  FILENAME" ... )  OR sha256sums=( "HEX" ... ) aligned with sources
#   md5sums=( "HEX  FILENAME" ... )     OR aligned with sources
# Hooks/functions (all optional):
#   pre_build build post_build
#   pre_install install post_install
#   pre_uninstall uninstall post_uninstall

reset_build_env() {
  unset pkgname pkgver pkgrel category pkgdesc url license arch
  unset -v depends makedepends sources sha256sums md5sums
  depends=(); makedepends=(); sources=(); sha256sums=(); md5sums=()
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
  [[ "${category:-}" == "$cat" ]] || category="$cat"
  declare -p sources >/dev/null 2>&1 || sources=()
  declare -p depends >/dev/null 2>&1 || depends=()
}

# ---------- Source fetching (parallel) ----------
cache_key_from_url() {
  local url="$1"
  # stable filename; keep basename, but include hash of url to avoid collisions
  local base="${url##*/}"
  local h
  h="$(printf "%s" "$url" | sha256sum | awk '{print $1}' | cut -c1-12)"
  printf "%s__%s" "$h" "$base"
}

parse_source() {
  # "URL::FILENAME" or "URL"
  local s="$1"
  if [[ "$s" == *"::"* ]]; then
    printf "%s\n" "${s%%::*}" "${s##*::}"
  else
    printf "%s\n" "$s" ""
  fi
}

checksum_lookup() {
  # returns "algo hex filename" or empty
  local fname="$1"

  # sha256sums can be aligned list (one per source) or "HEX  file"
  for entry in "${sha256sums[@]:-}"; do
    if [[ "$entry" == *" "* ]]; then
      local hex="${entry%% *}"
      local file="${entry##* }"
      [[ "$file" == "$fname" ]] && { printf "sha256 %s %s\n" "$hex" "$file"; return 0; }
    fi
  done
  for entry in "${md5sums[@]:-}"; do
    if [[ "$entry" == *" "* ]]; then
      local hex="${entry%% *}"
      local file="${entry##* }"
      [[ "$file" == "$fname" ]] && { printf "md5 %s %s\n" "$hex" "$file"; return 0; }
    fi
  done
  return 1
}

verify_sum() {
  local algo="$1" hex="$2" file="$3"
  case "$algo" in
    sha256)
      need sha256sum
      printf "%s  %s\n" "$hex" "$file" | sha256sum -c - >/dev/null 2>&1
      ;;
    md5)
      need md5sum
      printf "%s  %s\n" "$hex" "$file" | md5sum -c - >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

fetch_one_source() {
  local url="$1" outname="$2" worksrc="$3"

  mkdir -p "$CACHEDIR/sources" "$worksrc"
  local ck; ck="$(cache_key_from_url "$url")"
  local cachepath="$CACHEDIR/sources/$ck"
  local dstname="$outname"
  [[ -n "$dstname" ]] || dstname="${url##*/}"
  [[ -n "$dstname" ]] || dstname="$ck"

  local dstdl="$worksrc/$dstname"

  # If cached exists and checksum matches (when available) reuse.
  if [[ -f "$cachepath" ]]; then
    if checksum_lookup "$dstname" >/dev/null 2>&1; then
      read -r algo hex _ < <(checksum_lookup "$dstname")
      if verify_sum "$algo" "$hex" "$cachepath"; then
        cp -f "$cachepath" "$dstdl"
        printf "%s\n" "cache:$dstname"
        return 0
      else
        rm -f "$cachepath"
      fi
    else
      cp -f "$cachepath" "$dstdl"
      printf "%s\n" "cache:$dstname"
      return 0
    fi
  fi

  # Git sources
  if [[ "$url" == git+* ]] || [[ "$url" == *.git ]] || [[ "$url" == git://* ]]; then
    need git
    local repo="${url#git+}"
    local mir="$CACHEDIR/sources/${ck}.mirror"
    if [[ ! -d "$mir" ]]; then
      run "git clone --mirror '$repo' '$mir' >/dev/null"
    else
      run "git -C '$mir' fetch -p >/dev/null"
    fi
    # checkout default HEAD
    run "git clone '$mir' '$dstdl' >/dev/null"
    printf "%s\n" "git:$dstname"
    return 0
  fi

  # HTTP/HTTPS/FTP (prefer curl, fallback wget)
  if command -v curl >/dev/null 2>&1; then
    run "curl -L --fail --retry 3 --connect-timeout 20 -o '$dstdl' '$url'"
  elif command -v wget >/dev/null 2>&1; then
    run "wget -O '$dstdl' '$url'"
  else
    die "Nem curl nem wget disponíveis para baixar: $url"
  fi

  # Verify checksum; fallback sha256->md5 or md5->sha256 if only one exists
  if checksum_lookup "$dstname" >/dev/null 2>&1; then
    read -r algo hex _ < <(checksum_lookup "$dstname")
    if ! verify_sum "$algo" "$hex" "$dstdl"; then
      warn "Checksum falhou ($algo) para $dstname, removendo e baixando novamente..."
      run "rm -f '$dstdl'"
      # One retry
      if command -v curl >/dev/null 2>&1; then
        run "curl -L --fail --retry 3 --connect-timeout 20 -o '$dstdl' '$url'"
      else
        run "wget -O '$dstdl' '$url'"
      fi
      verify_sum "$algo" "$hex" "$dstdl" || die "Checksum continua falhando para $dstname"
    fi
  else
    # No checksum provided: warn but allow
    warn "Sem checksum declarado para $dstname (fonte: $url)"
  fi

  # Save to cache (only if checksum ok or not provided)
  run "cp -f '$dstdl' '$cachepath'"
  printf "%s\n" "dl:$dstname"
}

fetch_sources_parallel() {
  local worksrc="$1"
  mkdir -p "$worksrc"
  local -a jobspec=()

  for s in "${sources[@]:-}"; do
    read -r url outname < <(parse_source "$s")
    jobspec+=("$url|$outname")
  done

  if ((${#jobspec[@]} == 0)); then
    return 0
  fi

  info "Baixando fontes em paralelo (jobs=$JOBS)..."
  local fifo="$TMPDIR/adm.fetch.$$.fifo"
  run "mkfifo '$fifo'"
  # Writer: enqueue
  {
    for j in "${jobspec[@]}"; do
      printf "%s\n" "$j"
    done
  } >"$fifo" &

  local pids=()
  local i=0
  while IFS= read -r line; do
    ((i++))
    {
      local url="${line%%|*}"
      local out="${line#*|}"
      fetch_one_source "$url" "$out" "$worksrc"
    } >>"$LOG_CURRENT" 2>&1 &
    pids+=("$!")
    # throttle
    while ((${#pids[@]} >= JOBS)); do
      for idx in "${!pids[@]}"; do
        if ! kill -0 "${pids[$idx]}" 2>/dev/null; then
          wait "${pids[$idx]}" || die "Falha ao baixar fonte (veja log)."
          unset 'pids[idx]'
        fi
      done
      pids=("${pids[@]}") # compact
      sleep 0.1
    done
  done <"$fifo"
  run "rm -f '$fifo'"

  for pid in "${pids[@]}"; do
    wait "$pid" || die "Falha ao baixar fonte (veja log)."
  done
  ok "Fontes prontas."
}

# ---------- Unpack ----------
unpack_sources() {
  local worksrc="$1" workdir="$2"
  mkdir -p "$workdir"
  shopt -s nullglob
  local f
  for f in "$worksrc"/*; do
    [[ -e "$f" ]] || continue
    case "$f" in
      *.tar.gz|*.tgz) run "tar -C '$workdir' -xzf '$f'" ;;
      *.tar.bz2|*.tbz2) run "tar -C '$workdir' -xjf '$f'" ;;
      *.tar.xz|*.txz) run "tar -C '$workdir' -xJf '$f'" ;;
      *.tar.zst|*.tzst) run "tar -C '$workdir' --zstd -xf '$f'" ;;
      *.zip) need unzip; run "unzip -q '$f' -d '$workdir'" ;;
      *)
        # Might be a git checkout dir or raw file; just copy into workdir
        if [[ -d "$f" ]]; then
          run "cp -a '$f' '$workdir/'"
        else
          run "cp -a '$f' '$workdir/'"
        fi
      ;;
    esac
  done
  shopt -u nullglob
}

# ---------- Patch apply ----------
apply_patches() {
  local cat="$1" pkg="$2" srcdir="$3"
  local pdir="$PKGROOT/$cat/$pkg/patch"
  [[ -d "$pdir" ]] || return 0
  shopt -s nullglob
  local p
  for p in "$pdir"/*.patch "$pdir"/*.diff; do
    info "Aplicando patch: ${p##*/}"
    run "patch -d '$srcdir' -p1 < '$p' >>'$LOG_CURRENT' 2>&1"
  done
  shopt -u nullglob
}

# ---------- Files overlay ----------
install_files_overlay() {
  local cat="$1" pkg="$2" destdir="$3"
  local fdir="$PKGROOT/$cat/$pkg/files"
  [[ -d "$fdir" ]] || return 0
  info "Copiando files/ para DESTDIR..."
  run "cp -a '$fdir'/* '$destdir'/" 2>/dev/null || true
}

# ---------- Packaging ----------
make_package() {
  local pkg="$1" ver="$2" rel="$3" cat="$4" destdir="$5"
  mkdir -p "$CACHEDIR/pkgs" "$REPOROOT"
  local base="${pkg}-${ver}-${rel}"
  local outzst="$CACHEDIR/pkgs/${base}.tar.zst"
  local outxz="$CACHEDIR/pkgs/${base}.tar.xz"

  # filelist
  local flist="$TMPDIR/${base}.files"
  (cd "$destdir" && find . -type f -o -type l -o -type d | sed 's#^\./##') | sort >"$flist"

  if tar --help 2>/dev/null | grep -q -- '--zstd'; then
    info "Empacotando: $outzst"
    run "(cd '$destdir' && tar --zstd -cf '$outzst' .) >>'$LOG_CURRENT' 2>&1"
    run "cp -f '$outzst' '$REPOROOT/'"
    printf "%s\n" "$outzst"
  else
    need xz
    info "Empacotando (fallback xz): $outxz"
    # xz otimizado: -9e e threads
    run "(cd '$destdir' && tar -c . | xz -T0 -9e > '$outxz') >>'$LOG_CURRENT' 2>&1"
    run "cp -f '$outxz' '$REPOROOT/'"
    printf "%s\n" "$outxz"
  fi
}

# ---------- Install/uninstall ----------
db_write_meta() {
  local pkg="$1"
  mkdir -p "$DBDIR/$pkg"
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
  } >"$DBDIR/$pkg/meta"
}

db_write_files() {
  local pkg="$1" destdir="$2"
  mkdir -p "$DBDIR/$pkg"
  (cd "$destdir" && find . -type f -o -type l | sed 's#^\./##') | sort >"$DBDIR/$pkg/files"
}

install_from_destdir() {
  local pkg="$1" destdir="$2"
  info "Instalando no sistema (commit do DESTDIR)..."
  run "cp -a '$destdir'/* '/' 2>/dev/null || true"
  ok "Instalado: $pkg"
}

uninstall_pkg() {
  local pkg="$1"
  is_installed "$pkg" || die "Pacote não está instalado: $pkg"

  # reverse deps
  local rdeps
  rdeps="$(reverse_deps "$pkg" || true)"
  if [[ -n "$rdeps" ]]; then
    die "Não é possível remover '$pkg': dependências reversas: $rdeps"
  fi

  local cat; cat="$(meta_get "$pkg" category || true)"
  if [[ -n "$cat" ]] && [[ -f "$PKGROOT/$cat/$pkg/build" ]]; then
    load_build "$cat" "$pkg"
    if declare -F pre_uninstall >/dev/null 2>&1; then pre_uninstall || die "pre_uninstall falhou"; fi
    if declare -F uninstall >/dev/null 2>&1; then uninstall || true; fi
    if declare -F post_uninstall >/dev/null 2>&1; then post_uninstall || true; fi
  fi

  info "Removendo arquivos..."
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    run "rm -f '/$f' 2>/dev/null || true"
  done <"$DBDIR/$pkg/files"

  # remove empty dirs (best-effort)
  info "Limpando diretórios vazios..."
  while IFS= read -r f; do
    local d="/${f%/*}"
    [[ "$d" == "/" ]] && continue
    run "rmdir -p '$d' 2>/dev/null || true"
  done < <(tac "$DBDIR/$pkg/files")

  run "rm -rf '$DBDIR/$pkg'"
  ok "Removido: $pkg"
}

# ---------- Dependency resolution ----------
# Build graph from build scripts:
# Nodes: pkg
# Edges: pkg -> dep
# Toposort with cycle detection

list_all_pkgs() {
  find "$PKGROOT" -mindepth 2 -maxdepth 2 -type d -printf '%P\n' | awk -F/ '{print $1" "$2}'
}

pkg_cat_of() {
  local pkg="$1"
  local cat
  cat="$(find "$PKGROOT" -mindepth 2 -maxdepth 2 -type d -name "$pkg" -printf '%h\n' 2>/dev/null | head -n1 | awk -F/ '{print $(NF)}')"
  [[ -n "$cat" ]] || return 1
  printf "%s\n" "$cat"
}

deps_of() {
  local pkg="$1"
  local cat; cat="$(pkg_cat_of "$pkg")" || die "Pacote não encontrado no repo local: $pkg"
  load_build "$cat" "$pkg"
  printf "%s\n" "${depends[*]:-}"
}

toposort() {
  # args: targets...
  local -a targets=("$@")
  local -A temp perm
  local -a order=()

  visit() {
    local n="$1"
    if [[ "${perm[$n]:-0}" == "1" ]]; then return 0; fi
    if [[ "${temp[$n]:-0}" == "1" ]]; then die "Ciclo de dependência detectado envolvendo: $n"; fi
    temp["$n"]=1

    local deps; deps="$(deps_of "$n" || true)"
    local d
    for d in $deps; do
      # dependencies may be provided by system; if not in repo and installed, accept; else require in repo
      if is_installed "$d"; then
        : # ok
      else
        # if exists in local repo, traverse; else require user to provide
        if pkg_cat_of "$d" >/dev/null 2>&1; then
          visit "$d"
        else
          warn "Dependência '$d' não encontrada no repo local; assumindo fornecida pelo sistema."
        fi
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

reverse_deps() {
  local pkg="$1"
  local hit=()
  local p
  for p in "$DBDIR"/*; do
    [[ -d "$p" ]] || continue
    local name="${p##*/}"
    local deps; deps="$(meta_get "$name" depends || true)"
    for d in $deps; do
      if [[ "$d" == "$pkg" ]]; then
        hit+=("$name")
      fi
    done
  done
  printf "%s\n" "${hit[*]:-}"
}

# ---------- Build pipeline ----------
build_one() {
  local cat="$1" pkg="$2"
  load_build "$cat" "$pkg"

  local stamp="${pkg}-${pkgver}-${pkgrel}"
  local work="$BUILDDIR/$stamp"
  local worksrc="$work/sources"
  local workdir="$work/workdir"
  local srcroot="$work/src"
  local destdir="$work/destdir"
  mkdir -p "$work" "$worksrc" "$workdir" "$srcroot" "$destdir"

  LOG_CURRENT="$LOGDIR/${stamp}.log"
  run "mkdir -p '$LOGDIR'"
  run ": > '$LOG_CURRENT'"

  info "============================================================"
  info "Construindo: ${B}${pkg}${C0} ${W}v${pkgver}-${pkgrel}${C0}  [cat: $cat]"
  info "Log: $LOG_CURRENT"

  # clean (keep resume markers if RESUME=1)
  if ((RESUME == 0)); then
    info "Limpando diretório de build (resume desativado)..."
    run "rm -rf '$work'"
    mkdir -p "$work" "$worksrc" "$workdir" "$srcroot" "$destdir"
  else
    # keep but ensure destdir clean to avoid lixo
    run "rm -rf '$destdir' && mkdir -p '$destdir'"
    run "rm -rf '$srcroot' && mkdir -p '$srcroot'"
    run "rm -rf '$workdir' && mkdir -p '$workdir'"
  fi

  # Step markers
  local m_fetch="$work/.step_fetch"
  local m_unpack="$work/.step_unpack"
  local m_patch="$work/.step_patch"
  local m_build="$work/.step_build"
  local m_install="$work/.step_install"
  local m_pack="$work/.step_pack"

  if [[ ! -f "$m_fetch" ]]; then
    fetch_sources_parallel "$worksrc"
    run "touch '$m_fetch'"
  else
    info "Resume: fontes já baixadas."
  fi

  if [[ ! -f "$m_unpack" ]]; then
    unpack_sources "$worksrc" "$workdir"
    # choose source root: first dir inside workdir if single, else workdir
    local first
    first="$(find "$workdir" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
    if [[ -n "$first" ]]; then
      run "cp -a '$first' '$srcroot/'"
      SRC_DIR="$srcroot/${first##*/}"
    else
      SRC_DIR="$workdir"
    fi
    run "touch '$m_unpack'"
  else
    info "Resume: unpack já feito."
    # best-effort set SRC_DIR
    local first
    first="$(find "$srcroot" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
    SRC_DIR="${first:-$srcroot}"
  fi

  if [[ ! -f "$m_patch" ]]; then
    apply_patches "$cat" "$pkg" "$SRC_DIR"
    run "touch '$m_patch'"
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
    run "touch '$m_build'"
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
    run "touch '$m_install'"
  else
    info "Resume: install DESTDIR já feito."
  fi

  local pkgfile=""
  if [[ ! -f "$m_pack" ]]; then
    pkgfile="$(make_package "$pkg" "$pkgver" "$pkgrel" "$cat" "$destdir")"
    run "touch '$m_pack'"
  else
    info "Resume: pacote já empacotado."
    pkgfile="$(ls -1 "$CACHEDIR/pkgs/${pkg}-${pkgver}-${pkgrel}".tar.* 2>/dev/null | head -n1 || true)"
  fi

  printf "%s\n" "$pkgfile"
}

install_pkg_atomic() {
  local cat="$1" pkg="$2"

  load_build "$cat" "$pkg"
  local new_stamp="${pkg}-${pkgver}-${pkgrel}"
  local new_work="$BUILDDIR/$new_stamp"
  local new_dest="$new_work/destdir"
  [[ -d "$new_dest" ]] || die "DESTDIR não encontrado; construa antes: adm build $pkg"

  # backup current if installed
  local backup=""
  if is_installed "$pkg"; then
    local curver; curver="$(installed_ver "$pkg" || echo "unknown")"
    backup="$CACHEDIR/backups/${pkg}-${curver}-backup.tar.zst"
    mkdir -p "$CACHEDIR/backups"
    info "Criando backup do instalado ($pkg v$curver)..."
    # backup files list
    local tmpb="$TMPDIR/${pkg}.backup.$$"
    mkdir -p "$tmpb"
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      if [[ -e "/$f" || -L "/$f" ]]; then
        mkdir -p "$tmpb/$(dirname "$f")"
        cp -a "/$f" "$tmpb/$f" 2>/dev/null || true
      fi
    done <"$DBDIR/$pkg/files"
    if tar --help 2>/dev/null | grep -q -- '--zstd'; then
      run "(cd '$tmpb' && tar --zstd -cf '$backup' .) >>'$LOG_CURRENT' 2>&1"
    else
      run "(cd '$tmpb' && tar -c . | xz -T0 -9e > '${backup%.zst}.xz') >>'$LOG_CURRENT' 2>&1"
      backup="${backup%.zst}.xz"
    fi
    run "rm -rf '$tmpb'"
  fi

  # do install
  info "Commit para / (somente após build/pack OK)..."
  if ! install_from_destdir "$pkg" "$new_dest" >>"$LOG_CURRENT" 2>&1; then
    err "Falha na instalação. Tentando rollback..."
    if [[ -n "$backup" && -f "$backup" ]]; then
      if [[ "$backup" == *.tar.zst ]]; then
        run "tar --zstd -xf '$backup' -C '/'"
      else
        run "tar -xf '$backup' -C '/'"
      fi
    fi
    die "Instalação falhou (rollback aplicado quando possível)."
  fi

  db_write_meta "$pkg"
  db_write_files "$pkg" "$new_dest"
  ok "Registro atualizado."

  # remove files from old version not present in new (clean upgrade)
  if [[ -n "$backup" ]] && is_installed "$pkg"; then
    # We can compare previous file list (already overwritten). Best-effort: clean orphan dirs only.
    :
  fi
}

# ---------- Plan / Queue UI ----------
print_queue() {
  local -a order=("$@")
  local total="${#order[@]}"
  info "Fila de build: ${B}${total}${C0} pacote(s)"
  local i=0
  for p in "${order[@]}"; do
    ((i++))
    local mark=""
    if is_installed "$p"; then mark=" ${G}[ ✔ ]${C0}"; fi
    printf "  %s%2d/%d%s %s%s%s\n" "$W" "$i" "$total" "$C0" "$B" "$p" "$C0$mark"
  done
}

# ---------- Commands ----------
cmd_help() {
  cat <<EOF
adm - gerenciador simples de pacotes (LFS-style)

Uso:
  adm build <pkg...>           Constrói pacote(s) (resolve deps)
  adm install <pkg...>         Constrói se necessário e instala (resolve deps)
  adm remove <pkg...>          Remove pacote(s) com reverse-deps
  adm upgrade <pkg...>         Build + install (só troca após sucesso)
  adm rebuild-all              Reconstrói tudo instalado (resolvendo deps)
  adm search <texto>           Procura pacotes (com indicador instalado)
  adm info <pkg>               Informações completas (com indicador instalado)
  adm list-installed           Lista instalados
  adm sync <git_url>           Clona/atualiza repo para $REPOROOT (git pull)
  adm clean                    Limpeza inteligente (build/tmp/logs/cache antigo)
  adm doctor                   Verifica dependências de ferramentas

Opções globais:
  --dry-run        Não executa; apenas mostra o plano
  --no-resume      Desativa retomada (limpa tudo antes)
  --jobs N         Downloads paralelos (default: $JOBS)

EOF
}

cmd_doctor() {
  need bash
  need tar
  need patch
  need find
  need awk
  need sha256sum
  info "Ferramentas básicas OK."
  if ! command -v curl >/dev/null && ! command -v wget >/dev/null; then
    warn "Recomendado instalar curl ou wget."
  fi
  if ! command -v git >/dev/null; then
    warn "git ausente: fontes git não funcionarão."
  fi
  ok "doctor finalizado."
}

cmd_search() {
  local q="${1:-}"
  [[ -n "$q" ]] || die "Uso: adm search <texto>"
  mkdirs
  local found=0
  while read -r cat pkg; do
    if [[ "$pkg" == *"$q"* || "$cat" == *"$q"* ]]; then
      found=1
      local mark=""
      if is_installed "$pkg"; then mark=" ${G}[ ✔ ]${C0}"; fi
      printf "%s%-16s%s  %s%-24s%s%s\n" "$C" "$cat" "$C0" "$B" "$pkg" "$C0" "$mark"
    fi
  done < <(list_all_pkgs)
  ((found)) || warn "Nenhum pacote encontrado para: $q"
}

cmd_info() {
  local pkg="${1:-}"
  [[ -n "$pkg" ]] || die "Uso: adm info <pkg>"
  mkdirs
  local cat
  cat="$(pkg_cat_of "$pkg" 2>/dev/null || true)"
  if [[ -n "$cat" ]]; then
    load_build "$cat" "$pkg"
    local mark=""
    if is_installed "$pkg"; then mark=" ${G}[ ✔ ]${C0}"; fi
    printf "%s%s%s%s\n" "$B" "$pkg" "$C0" "$mark"
    echo "  category: $category"
    echo "  version : $pkgver-$pkgrel"
    echo "  desc    : ${pkgdesc:-}"
    echo "  url     : ${url:-}"
    echo "  license : ${license:-}"
    echo "  depends : ${depends[*]:-}"
    echo "  sources : ${#sources[@]} item(s)"
  else
    warn "Pacote não existe no repo local: $pkg"
  fi
  if is_installed "$pkg"; then
    echo "  installed: yes (v$(installed_ver "$pkg"))"
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
    printf "%s%s%s  v%s\n" "$B" "$n" "$C0" "$(installed_ver "$n" || echo "?")"
  done
}

cmd_build() {
  mkdirs
  local -a targets=("$@")
  ((${#targets[@]})) || die "Uso: adm build <pkg...>"
  local -a order
  mapfile -t order < <(toposort "${targets[@]}")
  print_queue "${order[@]}"

  local done=0 total="${#order[@]}"
  local p
  for p in "${order[@]}"; do
    ((done++))
    printf "%s%s[%d/%d]%s %s\n" "$W" "$B" "$done" "$total" "$C0" "Processando $p"
    if is_installed "$p"; then
      info "Já instalado: $p (pule build; use upgrade se desejar)."
      continue
    fi
    local cat; cat="$(pkg_cat_of "$p")"
    if build_one "$cat" "$p" >/dev/null; then
      ok "✔ build OK: $p"
    else
      err "X build falhou: $p (veja log)"
      return 1
    fi
  done
}

cmd_install() {
  mkdirs
  local -a targets=("$@")
  ((${#targets[@]})) || die "Uso: adm install <pkg...>"
  local -a order
  mapfile -t order < <(toposort "${targets[@]}")
  print_queue "${order[@]}"

  local done=0 total="${#order[@]}"
  local p
  for p in "${order[@]}"; do
    ((done++))
    printf "%s%s[%d/%d]%s %s\n" "$W" "$B" "$done" "$total" "$C0" "Instalando $p"
    if is_installed "$p"; then
      info "Já instalado: $p"
      continue
    fi
    local cat; cat="$(pkg_cat_of "$p")"
    build_one "$cat" "$p" >/dev/null
    install_pkg_atomic "$cat" "$p"
    ok "✔ instalado: $p"
  done
}

cmd_upgrade() {
  mkdirs
  local -a targets=("$@")
  ((${#targets[@]})) || die "Uso: adm upgrade <pkg...>"
  local -a order
  mapfile -t order < <(toposort "${targets[@]}")
  print_queue "${order[@]}"

  local done=0 total="${#order[@]}"
  local p
  for p in "${order[@]}"; do
    ((done++))
    printf "%s%s[%d/%d]%s %s\n" "$W" "$B" "$done" "$total" "$C0" "Upgrade $p"
    local cat; cat="$(pkg_cat_of "$p")"
    # Always rebuild for upgrade
    build_one "$cat" "$p" >/dev/null
    install_pkg_atomic "$cat" "$p"
    ok "✔ upgrade OK: $p"
  done
}

cmd_remove() {
  mkdirs
  (("$#")) || die "Uso: adm remove <pkg...>"
  local p
  for p in "$@"; do
    with_lock "db" uninstall_pkg "$p"
  done
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

cmd_sync() {
  mkdirs
  local url="${1:-}"
  [[ -n "$url" ]] || die "Uso: adm sync <git_url>"
  need git
  if [[ -d "$REPOROOT/.git" ]]; then
    info "Atualizando repo local em $REPOROOT..."
    run "git -C '$REPOROOT' pull --rebase"
  else
    info "Clonando repo para $REPOROOT..."
    run "rm -rf '$REPOROOT'"
    run "git clone '$url' '$REPOROOT'"
  fi
  ok "sync OK."
}

cmd_clean() {
  mkdirs
  info "Limpando build/tmp..."
  run "rm -rf '$TMPDIR'/* 2>/dev/null || true"
  # remove build dirs older than 7 days
  info "Removendo builds antigos (>7 dias)..."
  run "find '$BUILDDIR' -mindepth 1 -maxdepth 1 -type d -mtime +7 -print -exec rm -rf {} + >/dev/null 2>&1 || true"
  # compress/rotate logs older
  info "Removendo logs antigos (>30 dias)..."
  run "find '$LOGDIR' -type f -mtime +30 -delete >/dev/null 2>&1 || true"
  ok "clean OK."
}

# ---------- Arg parse ----------
main() {
  mkdirs
  local -a args=()
  while (("$#")); do
    case "$1" in
      --dry-run) DRYRUN=1; shift ;;
      --no-resume) RESUME=0; shift ;;
      --jobs) JOBS="${2:-}"; shift 2 ;;
      -h|--help) cmd_help; exit 0 ;;
      *) args+=("$1"); shift ;;
    esac
  done

  local cmd="${args[0]:-help}"
  shift || true

  case "$cmd" in
    help) cmd_help ;;
    doctor) cmd_doctor ;;
    search) cmd_search "${args[1]:-}" ;;
    info) cmd_info "${args[1]:-}" ;;
    list-installed) cmd_list_installed ;;
    build) cmd_build "${args[@]:1}" ;;
    install) with_lock "db" cmd_install "${args[@]:1}" ;;
    upgrade) with_lock "db" cmd_upgrade "${args[@]:1}" ;;
    remove) with_lock "db" cmd_remove "${args[@]:1}" ;;
    rebuild-all) with_lock "db" cmd_rebuild_all ;;
    sync) cmd_sync "${args[1]:-}" ;;
    clean) cmd_clean ;;
    *)
      die "Comando desconhecido: $cmd (use: adm help)"
      ;;
  esac
}

main "$@"
