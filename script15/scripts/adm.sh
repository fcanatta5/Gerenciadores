#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

ADM_VERSION="1.0.0"
# Sync para o repo sudo REPO_URL="git@seu-host:seu-repo.git" adm sync

# ---------------- Paths / Policy ----------------
ADM_ROOT="${ADM_ROOT:-/usr/local/adm}"
PKGROOT="${PKGROOT:-$ADM_ROOT/packages}"         # packages/<cat>/<prog>/build (ou buildfile arbitrário passado por caminho)
REPO_URL="${REPO_URL:-}"                         # opcional: repo git remoto com packages/
REPO_DIR="${REPO_DIR:-$PKGROOT}"                 # destino do sync
STATE="${STATE:-/var/lib/adm}"
DB="$STATE/db"
WORLD="$STATE/world"
CACHE="${CACHE:-/var/cache/adm}"
SRC_CACHE="$CACHE/sources"
BIN_CACHE="$CACHE/bins"
WORK="${WORK:-/var/tmp/adm-work}"
LOGDIR="${LOGDIR:-/var/log/adm}"
LOCK="/run/adm.lock"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 1)}"
ASSUME_YES=0
DRYRUN=0
KEEP_WORK=0
CLEAN_BEFORE=1
RESUME=0

# ---------------- UI ----------------
if [[ -t 2 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; M=$'\033[35m'; C=$'\033[36m'; D=$'\033[2m'; Z=$'\033[0m'
else
  R="";G="";Y="";B="";M="";C="";D="";Z=""
fi
hr(){ printf '%s\n' "${D}────────────────────────────────────────────────────────${Z}"; }
tag(){ printf '%b\n' "${C}[adm]${Z} $*"; }
ok(){  printf '%b\n' "${G}[ ✔️]${Z} $*"; }
warn(){printf '%b\n' "${Y}[ ! ]${Z} $*"; }
die(){ printf '%b\n' "${R}[ x ]${Z} $*"; exit 1; }
step(){ hr; printf '%b\n' "${B}▶${Z} ${M}$*${Z}"; hr; }

run(){
  if [[ "$DRYRUN" == "1" ]]; then
    printf '%b\n' "${D}DRY-RUN:${Z} $*"
  else
    eval "$@"
  fi
}
confirm(){
  [[ "$ASSUME_YES" == "1" ]] && return 0
  read -r -p "$1 [s/N]: " a || true
  [[ "${a,,}" == "s" || "${a,,}" == "sim" || "${a,,}" == "y" || "${a,,}" == "yes" ]]
}
have(){ command -v "$1" >/dev/null 2>&1; }
need(){
  local m=()
  for c in "$@"; do have "$c" || m+=("$c"); done
  ((${#m[@]}==0)) || die "Comandos ausentes: ${m[*]}"
}

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Execute como root."; }

lock(){
  exec 9>"$LOCK" || die "Não foi possível abrir lock ($LOCK)"
  flock -n 9 || die "adm já está rodando (lock ativo)."
}

log_init(){
  run "mkdir -p '$LOGDIR'"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  LOG="$LOGDIR/adm-$ts.log"
  exec > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2)
  tag "Log: $LOG"
}
onerr(){
  local ec=$? ln=${BASH_LINENO[0]:-?} cmd=${BASH_COMMAND:-?}
  printf '%b\n' "${R}FALHA${Z} exit=$ec linha=$ln cmd=$cmd"
  printf '%b\n' "Log: ${LOG:-"(não inicializado)"}"
  exit "$ec"
}
trap onerr ERR

init_dirs(){
  run "mkdir -p '$ADM_ROOT' '$PKGROOT' '$STATE' '$DB' '$CACHE' '$SRC_CACHE' '$BIN_CACHE' '$WORK' '$LOGDIR'"
  run "touch '$WORLD'"
}

# ---------------- DB ----------------
dbp(){ echo "$DB/$1"; }
installed(){ [[ -d "$(dbp "$1")" ]]; }
db_get(){ [[ -f "$(dbp "$1")/$2" ]] && cat "$(dbp "$1")/$2" || true; }
db_list(){ find "$DB" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort; }

db_record(){
  local name="$1" ver="$2" cat="$3" deps="$4" bdeps="$5" buildfile="$6"
  run "mkdir -p '$(dbp "$name")'"
  run "printf '%s\n' '$name' > '$(dbp "$name")/name'"
  run "printf '%s\n' '$ver'  > '$(dbp "$name")/version'"
  run "printf '%s\n' '$cat'  > '$(dbp "$name")/category'"
  run "printf '%s\n' '$deps' > '$(dbp "$name")/depends'"
  run "printf '%s\n' '$bdeps' > '$(dbp "$name")/build_depends'"
  run "printf '%s\n' '$buildfile' > '$(dbp "$name")/buildfile'"
  run "date -Is > '$(dbp "$name")/installed_at'"
}
db_set_manifest(){
  local name="$1" mf="$2"
  [[ -s "$mf" ]] || die "$name: manifest ausente/vazio (obrigatório)."
  run "cp -f '$mf' '$(dbp "$name")/manifest'"
}
db_set_pkgref(){
  local name="$1" pkg="$2"
  run "printf '%s\n' '$pkg' > '$(dbp "$name")/package'"
}

rdeps(){
  local t="$1"
  for p in $(db_list); do
    [[ -f "$(dbp "$p")/depends" ]] || continue
    if grep -qw -- "$t" "$(dbp "$p")/depends"; then echo "$p"; fi
  done
}

world_list(){ sed '/^\s*$/d' "$WORLD" | sort -u; }
world_add(){ run "printf '%s\n' '$1' >> '$WORLD'"; run "sort -u -o '$WORLD' '$WORLD'"; }
world_del(){
  if [[ "$DRYRUN" == "1" ]]; then echo "DRY-RUN: removeria $1 do world"; return 0; fi
  grep -vx -- "$1" "$WORLD" > "$WORLD.tmp" || true
  mv -f "$WORLD.tmp" "$WORLD"
}

# ---------------- Buildfile parsing ----------------
# Buildfile é um shell script com variáveis:
# NAME CATEGORY VERSION URL SHA256 DEPENDS BUILD_DEPENDS
# Exemplo (como seu build.txt): 1
load_buildfile(){
  local bf="$1"
  [[ -f "$bf" ]] || die "Buildfile não encontrado: $bf"

  # limpa hooks antigos
  for fn in pkg_env pkg_prepare pkg_configure pkg_build pkg_install pkg_post; do
    declare -F "$fn" >/dev/null 2>&1 && unset -f "$fn" || true
  done

  unset NAME CATEGORY VERSION URL SHA256 MD5 DEPENDS BUILD_DEPENDS
  unset URLS GIT GIT_REF
  unset PREFIX BUILD_SYSTEM CONFIGURE_OPTS MAKE_OPTS INSTALL_OPTS MESON_OPTS CMAKE_OPTS
  unset TOOLCHAIN LINKER CFLAGS CXXFLAGS LDFLAGS RUSTFLAGS GOFLAGS

  # defaults
  PREFIX="/usr"
  BUILD_SYSTEM="auto"
  DEPENDS=""
  BUILD_DEPENDS=""
  CONFIGURE_OPTS=""
  MAKE_OPTS=""
  INSTALL_OPTS=""
  MESON_OPTS=""
  CMAKE_OPTS=""
  TOOLCHAIN="auto"
  LINKER="auto"

  # shellcheck disable=SC1090
  source "$bf"

  [[ -n "${NAME:-}" ]] || die "Buildfile sem NAME: $bf"
  [[ -n "${CATEGORY:-}" ]] || CATEGORY="misc"
  [[ -n "${VERSION:-}" ]] || die "$NAME: VERSION obrigatório"
  # fontes podem ser: URL (tarball), URLS (multi), ou GIT (repo)
  if [[ -z "${URL:-}" && -z "${URLS:-}" && -z "${GIT:-}" ]]; then
    die "$NAME: defina URL ou URLS ou GIT"
  fi
  [[ -n "${SHA256:-}" || -n "${MD5:-}" ]] || die "$NAME: defina SHA256 (preferido) ou MD5"
}

# ---------------- Source fetch + verify (SHA256 then MD5 fallback) ----------------
verify_file(){
  local f="$1" sha="${2:-}" md5="${3:-}"
  need sha256sum md5sum awk

  if [[ -n "$sha" ]]; then
    local got; got="$(sha256sum "$f" | awk '{print $1}')"
    [[ "$got" == "$sha" ]] && return 0
    return 1
  fi
  if [[ -n "$md5" ]]; then
    local got; got="$(md5sum "$f" | awk '{print $1}')"
    [[ "$got" == "$md5" ]] && return 0
    return 1
  fi
  return 1
}

fetch_url(){
  local url="$1" sha="${2:-}" md5="${3:-}"
  need curl
  local base; base="$(basename "${url%%\?*}")"
  local out="$SRC_CACHE/$base"

  if [[ -f "$out" ]]; then
    if verify_file "$out" "$sha" "$md5"; then
      ok "cache ok: $base"
      echo "$out"; return 0
    fi
    warn "checksum falhou no cache, removendo e baixando novamente: $base"
    run "rm -f '$out'"
  fi

  step "$NAME: download $(basename "$out")"
  run "curl -fL --retry 3 --retry-delay 2 -o '$out.part' '$url'"
  run "mv -f '$out.part' '$out'"

  if ! verify_file "$out" "$sha" "$md5"; then
    run "rm -f '$out'"
    die "$NAME: checksum falhou após download. Arquivo removido."
  fi
  ok "checksum ok: $base"
  echo "$out"
}

fetch_git(){
  local giturl="$1" ref="${2:-}"
  need git
  local dir="$SRC_CACHE/git-${NAME}"
  if [[ -d "$dir/.git" ]]; then
    step "$NAME: git fetch"
    run "(cd '$dir' && git fetch --all --prune)"
  else
    step "$NAME: git clone"
    run "rm -rf '$dir'"
    run "git clone --recursive '$giturl' '$dir'"
  fi
  if [[ -n "$ref" ]]; then
    step "$NAME: git checkout $ref"
    run "(cd '$dir' && git checkout -f '$ref')"
    run "(cd '$dir' && git submodule update --init --recursive)"
  fi
  echo "$dir"
}

# ---------------- Patch + files directories ----------------
patch_dir_for(){
  local bf="$1"
  # patch/ ao lado do buildfile
  echo "$(cd "$(dirname "$bf")" && pwd)/patch"
}
files_dir_for(){
  echo "$(cd "$(dirname "$1")" && pwd)/files"
}

apply_patches(){
  local src="$1" pdir="$2"
  [[ -d "$pdir" ]] || { ok "$NAME: sem patches"; return 0; }
  need patch find sort
  local patches=()
  while IFS= read -r -d '' f; do patches+=("$f"); done < <(find "$pdir" -maxdepth 1 -type f \( -name "*.patch" -o -name "*.diff" \) -print0 | sort -z)
  ((${#patches[@]}==0)) && { ok "$NAME: sem patches"; return 0; }

  step "$NAME: applying patches"
  local i=0
  for pf in "${patches[@]}"; do
    ((i++))
    tag "patch ($i/${#patches[@]}): $(basename "$pf")"
    if patch -d "$src" -p1 --forward --silent < "$pf"; then
      ok "aplicado (-p1)"
    elif patch -d "$src" -p0 --forward --silent < "$pf"; then
      ok "aplicado (-p0)"
    else
      die "$NAME: falha aplicando patch $(basename "$pf")"
    fi
  done
}

# ---------------- Extract ----------------
extract_tarball(){
  local tarball="$1" outdir="$2"
  need tar
  run "rm -rf '$outdir' && mkdir -p '$outdir'"
  local top; top="$(tar -tf "$tarball" | head -n1 | cut -d/ -f1)"
  run "tar -xf '$tarball' -C '$outdir'"
  [[ -d "$outdir/$top" ]] || die "$NAME: falha ao extrair"
  echo "$outdir/$top"
}

# ---------------- Build helper: detect system ----------------
detect_build_system(){
  [[ "$BUILD_SYSTEM" != "auto" ]] && { echo "$BUILD_SYSTEM"; return; }
  [[ -f Cargo.toml ]] && { echo "cargo"; return; }
  [[ -f go.mod ]] && { echo "go"; return; }
  [[ -f meson.build ]] && { echo "meson"; return; }
  [[ -f CMakeLists.txt ]] && { echo "cmake"; return; }
  [[ -x configure || -f configure.ac || -f configure.in ]] && { echo "autotools"; return; }
  [[ -f Makefile || -f GNUmakefile || -f makefile ]] && { echo "make"; return; }
  echo "make"
}

pick_toolchain(){
  # compilers
  case "${TOOLCHAIN:-auto}" in
    auto)
      if have clang; then export CC="${CC:-clang}" CXX="${CXX:-clang++}"
      else export CC="${CC:-gcc}" CXX="${CXX:-g++}"
      fi
      ;;
    clang) export CC="${CC:-clang}" CXX="${CXX:-clang++}" ;;
    gcc)   export CC="${CC:-gcc}"   CXX="${CXX:-g++}" ;;
    *) die "$NAME: TOOLCHAIN inválido: $TOOLCHAIN" ;;
  esac
  # linker
  case "${LINKER:-auto}" in
    auto) : ;;
    lld)  export LDFLAGS="${LDFLAGS:-} -fuse-ld=lld" ;;
    mold) export LDFLAGS="${LDFLAGS:-} -fuse-ld=mold" ;;
    bfd)  export LDFLAGS="${LDFLAGS:-} -fuse-ld=bfd" ;;
    *) die "$NAME: LINKER inválido: $LINKER" ;;
  esac
  export CFLAGS="${CFLAGS:-} -O2"
  export CXXFLAGS="${CXXFLAGS:-} -O2"
  export LC_ALL=C LANG=C
}

# ---------------- Dependency resolution with cycle detection ----------------
# DEPENDS and BUILD_DEPENDS accept: "pkgA pkgB" (name) OR "cat/prog"
# We resolve by NAME where possible: buildfile discovery uses PKGROOT.
find_buildfile_by_name(){
  local needle="$1"
  # prefer: .../<cat>/<prog>/build/build
  local bf
  bf="$(find "$PKGROOT" -type f -name build -path "*/build/build" 2>/dev/null | while read -r p; do
    # quick parse NAME=
    local n
    n="$(grep -E '^NAME=' "$p" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" )"
    [[ "$n" == "$needle" ]] && { echo "$p"; break; }
  done | head -n1)"
  [[ -n "$bf" ]] && echo "$bf" || true
}

declare -A VIS=()
declare -a ORDER=()

dfs_resolve(){
  local bf="$1"
  load_buildfile "$bf"
  local key="$NAME"
  [[ "${VIS[$key]:-}" == "perm" ]] && return
  [[ "${VIS[$key]:-}" == "temp" ]] && die "Ciclo de dependências detectado envolvendo: $key"
  VIS["$key"]="temp"

  local d
  for d in $BUILD_DEPENDS $DEPENDS; do
    [[ -z "$d" ]] && continue
    local depbf=""
    if [[ "$d" == */* ]]; then
      # cat/prog
      local c="${d%%/*}" p="${d##*/}"
      depbf="$PKGROOT/$c/$p/build/build"
      [[ -f "$depbf" ]] || die "$NAME: dependência $d sem buildfile: $depbf"
    else
      depbf="$(find_buildfile_by_name "$d")"
      [[ -n "$depbf" ]] || { installed "$d" && continue; die "$NAME: dependência '$d' não instalada e sem buildfile."; }
    fi
    dfs_resolve "$depbf"
  done

  VIS["$key"]="perm"
  ORDER+=("$bf")
}

resolve_order(){
  VIS=(); ORDER=()
  dfs_resolve "$1"
  printf '%s\n' "${ORDER[@]}"
}

# ---------------- Packaging: tar.zst fallback tar.xz ----------------
pkg_path(){
  local name="$1" ver="$2"
  echo "$BIN_CACHE/${name}-${ver}.tar"
}
pack_stage(){
  local stagedir="$1" name="$2" ver="$3"
  need tar
  run "mkdir -p '$BIN_CACHE'"
  local base="$BIN_CACHE/${name}-${ver}.tar"
  local out=""
  if have zstd; then
    out="${base}.zst"
    step "$name: packaging tar.zst"
    if [[ "$DRYRUN" == "0" ]]; then
      (cd "$stagedir" && tar -cpf - .) | zstd -T0 -19 -o "$out"
    else
      echo "DRY-RUN: tar | zstd -> $out"
    fi
  else
    need xz
    out="${base}.xz"
    step "$name: packaging tar.xz"
    if [[ "$DRYRUN" == "0" ]]; then
      (cd "$stagedir" && tar -cpf - .) | xz -T0 -9 -c > "$out"
    else
      echo "DRY-RUN: tar | xz -> $out"
    fi
  fi
  echo "$out"
}

# ---------------- Install / Uninstall by manifest ----------------
manifest_from_stage(){
  local stagedir="$1" out="$2"
  (cd "$stagedir" && find . -mindepth 1 -print | sed 's|^\./|/|' | sort) > "$out"
  [[ -s "$out" ]] || die "$NAME: manifest vazio"
}

commit_stage(){
  local stagedir="$1"
  need tar
  step "$NAME: install commit"
  if [[ "$DRYRUN" == "1" ]]; then
    echo "DRY-RUN: commit stage -> /"
    return 0
  fi
  (cd "$stagedir" && tar -cpf - .) | (cd / && tar -xpf -)
  ok "commit OK"
}

remove_by_manifest(){
  local mf="$1"
  [[ -f "$mf" ]] || die "manifest não encontrado: $mf"
  if [[ "$DRYRUN" == "1" ]]; then
    echo "DRY-RUN: removeria $(wc -l < "$mf") paths"
    return 0
  fi
  tac "$mf" | while IFS= read -r p; do
    [[ -z "$p" || "$p" == "/" ]] && continue
    if [[ -e "$p" || -L "$p" ]]; then
      rm -f -- "$p" 2>/dev/null || true
      rmdir --ignore-fail-on-non-empty -p -- "$(dirname "$p")" 2>/dev/null || true
    fi
  done
}

# ---------------- Build pipeline per package ----------------
build_one(){
  local bf="$1"
  load_buildfile "$bf"
  pick_toolchain

  local pdir; pdir="$(patch_dir_for "$bf")"
  local fdir; fdir="$(files_dir_for "$bf")"

  local wdir="$WORK/${NAME}-${VERSION}"
  local srcdir="$wdir/src"
  local staged="$wdir/stage"
  local mf="$wdir/manifest.txt"

  # Limpar sempre antes de construir (default) — mas permitir retomada com --resume/--keep-work
  if [[ "$CLEAN_BEFORE" == "1" && "$RESUME" == "0" ]]; then
    step "$NAME: clean before build"
    run "rm -rf '$wdir'"
    ok "limpo"
  fi
  run "mkdir -p '$wdir' '$staged'"

  # Obtém fontes
  local source_root=""
  if [[ -n "${GIT:-}" ]]; then
    source_root="$(fetch_git "$GIT" "${GIT_REF:-}")"
    # build a partir do clone (não extraí)
    run "rm -rf '$srcdir' && cp -a '$source_root' '$srcdir'"
  else
    # URLS múltiplas: baixa todas; a primeira é “principal” para extrair; as demais ficam disponíveis em $wdir/distfiles
    run "mkdir -p '$wdir/distfiles'"
    local primary=""
    if [[ -n "${URLS:-}" ]]; then
      local u
      for u in $URLS; do
        local f; f="$(fetch_url "$u" "${SHA256:-}" "${MD5:-}")"
        run "cp -f '$f' '$wdir/distfiles/'"
        [[ -z "$primary" ]] && primary="$f"
      done
    else
      primary="$(fetch_url "$URL" "${SHA256:-}" "${MD5:-}")"
      run "cp -f '$primary' '$wdir/distfiles/'"
    fi
    source_root="$(extract_tarball "$primary" "$wdir/unpack")"
    run "rm -rf '$srcdir' && cp -a '$source_root' '$srcdir'"
  fi

  apply_patches "$srcdir" "$pdir"

  # hooks opcionais no buildfile:
  declare -F pkg_env >/dev/null 2>&1 && (cd "$srcdir" && pkg_env) || true
  declare -F pkg_prepare >/dev/null 2>&1 && (cd "$srcdir" && pkg_prepare) || true

  # configure/build/install helper
  local sys
  sys="$(cd "$srcdir" && detect_build_system)"
  step "$NAME: build-system=$sys"

  # out-of-tree for meson/cmake
  local bld="$wdir/builddir"

  if declare -F pkg_configure >/dev/null 2>&1; then
    (cd "$srcdir" && pkg_configure)
  else
    case "$sys" in
      autotools)
        if [[ ! -x "$srcdir/configure" && ( -f "$srcdir/configure.ac" || -f "$srcdir/configure.in" ) ]]; then
          have autoreconf || die "$NAME: precisa autoreconf (autoconf/automake/libtool)"
          (cd "$srcdir" && autoreconf -fi)
        fi
        (cd "$srcdir" && ./configure --prefix="$PREFIX" $CONFIGURE_OPTS)
        ;;
      meson)
        need meson ninja
        run "rm -rf '$bld' && mkdir -p '$bld'"
        (cd "$srcdir" && meson setup "$bld" --prefix="$PREFIX" --buildtype=release $MESON_OPTS)
        ;;
      cmake)
        need cmake
        run "rm -rf '$bld' && mkdir -p '$bld'"
        (cd "$srcdir" && cmake -S . -B "$bld" -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release $CMAKE_OPTS)
        ;;
      *)
        : ;;
    esac
  fi

  if declare -F pkg_build >/dev/null 2>&1; then
    (cd "$srcdir" && pkg_build)
  else
    case "$sys" in
      autotools|make) (cd "$srcdir" && make -j"$JOBS" $MAKE_OPTS) ;;
      meson)          (cd "$srcdir" && ninja -C "$bld" -j"$JOBS") ;;
      cmake)          (cd "$srcdir" && cmake --build "$bld" -- -j"$JOBS") ;;
      cargo)          need cargo; (cd "$srcdir" && cargo build --release) ;;
      go)             need go; (cd "$srcdir" && go build ./...) ;;
      *)              (cd "$srcdir" && make -j"$JOBS" $MAKE_OPTS) ;;
    esac
  fi

  # install to DESTDIR staging
  step "$NAME: install DESTDIR"
  run "rm -rf '$staged' && mkdir -p '$staged'"

  if declare -F pkg_install >/dev/null 2>&1; then
    (cd "$srcdir" && DESTDIR="$staged" pkg_install)
  else
    case "$sys" in
      autotools|make) (cd "$srcdir" && make install DESTDIR="$staged" $INSTALL_OPTS) ;;
      meson)          need ninja; (cd "$srcdir" && DESTDIR="$staged" ninja -C "$bld" install) ;;
      cmake)
        # cmake respects DESTDIR env
        (cd "$srcdir" && DESTDIR="$staged" cmake --install "$bld")
        ;;
      cargo)
        need cargo
        (cd "$srcdir" && cargo install --path . --root "$staged$PREFIX" --locked --force)
        ;;
      go)
        die "$NAME: go install default é ambíguo. Defina pkg_install no buildfile."
        ;;
      *)
        (cd "$srcdir" && make install DESTDIR="$staged" $INSTALL_OPTS) ;;
    esac
  fi

  # copy files/ into staging (always)
  if [[ -d "$fdir" ]]; then
    step "$NAME: apply files/"
    (cd "$fdir" && tar -cpf - .) | (cd "$staged" && tar -xpf -)
  fi

  # manifest + package
  step "$NAME: manifest + package"
  manifest_from_stage "$staged" "$mf"
  local pkg; pkg="$(pack_stage "$staged" "$NAME" "$VERSION")"

  # upgrade inteligente: remove obsoletos (arquivos antigos que não estão mais no novo manifest)
  if installed "$NAME"; then
    local oldm="$(dbp "$NAME")/manifest"
    if [[ -f "$oldm" && "$DRYRUN" == "0" ]]; then
      step "$NAME: remove obsolete files"
      comm -23 <(sort "$oldm") <(sort "$mf") | tac | while IFS= read -r p; do
        [[ -z "$p" || "$p" == "/" ]] && continue
        if [[ -e "$p" || -L "$p" ]]; then
          rm -f -- "$p" 2>/dev/null || true
          rmdir --ignore-fail-on-non-empty -p -- "$(dirname "$p")" 2>/dev/null || true
        fi
      done
      ok "obsoletos removidos"
    fi
  fi

  # commit install
  commit_stage "$staged"

  # DB record
  db_record "$NAME" "$VERSION" "$CATEGORY" "$DEPENDS" "$BUILD_DEPENDS" "$bf"
  db_set_manifest "$NAME" "$mf"
  db_set_pkgref "$NAME" "$pkg"

  ok "instalado/atualizado: $NAME-$VERSION"
  if [[ "$KEEP_WORK" != "1" ]]; then
    run "rm -rf '$wdir'"
  else
    warn "KEEP_WORK=1 mantendo workdir: $wdir"
  fi
}

# build with deps
cmd_build(){
  local arg="$1"
  [[ -n "$arg" ]] || die "Uso: adm build <nome|buildfile>"

  local bf=""
  if [[ -f "$arg" ]]; then
    bf="$arg"
  else
    # arg é NAME do pacote (ex.: zlib)
    bf="$(find_buildfile_by_name "$arg")"
    [[ -n "$bf" && -f "$bf" ]] || die "Não encontrei buildfile para '$arg' em $PKGROOT"
  fi

  mapfile -t order < <(resolve_order "$bf")
  step "Build order"
  for x in "${order[@]}"; do
    load_buildfile "$x"
    local mark=" "
    installed "$NAME" && mark="✔️"
    printf '%b\n' " - [$mark] $NAME ($CATEGORY) from $(dirname "$x")"
  done
  for x in "${order[@]}"; do build_one "$x"; done
}

# install from binary cache (package) with deps (must be installed deps already or build them)
install_pkgfile(){
  local pkgfile="$1"
  [[ -f "$pkgfile" ]] || die "Pacote não encontrado: $pkgfile"
  need tar
  step "install package: $(basename "$pkgfile")"
  if [[ "$DRYRUN" == "1" ]]; then
    echo "DRY-RUN: extrairia pacote em /"
    return 0
  fi
  case "$pkgfile" in
    *.zst) need zstd; zstd -dc "$pkgfile" | tar -xpf - -C / ;;
    *.xz)  need xz;  xz -dc "$pkgfile" | tar -xpf - -C / ;;
    *) die "Extensão de pacote desconhecida: $pkgfile" ;;
  esac
  ok "pacote instalado"
}

cmd_install(){
  # instala um pacote já construído pelo nome (usa db/package)
  local name="$1"
  [[ -n "$name" ]] || die "Uso: adm install <nome>"
  installed "$name" && { ok "$name já está instalado"; return 0; }
  die "Sem metadados para instalar '$name'. Use 'build' ou construa primeiro para gerar pacote."
}

cmd_remove(){
  local name="$1" force="${2:-0}"
  [[ -n "$name" ]] || die "Uso: adm remove <nome> [--force]"
  installed "$name" || die "Não instalado: $name"

  local rd; rd="$(rdeps "$name" || true)"
  if [[ -n "$rd" && "$force" != "1" ]]; then
    die "Reverse-deps impedem remoção: $(echo "$rd" | tr '\n' ' ') (use --force)"
  fi

  local mf="$(dbp "$name")/manifest"
  confirm "Remover $name pelo manifest?" || die "Cancelado."
  step "$name: uninstall"
  remove_by_manifest "$mf"
  run "rm -rf '$(dbp "$name")'"
  ok "removido: $name"
}

cmd_upgrade(){
  # upgrade inteligente: rebuild world
  step "upgrade (world)"
  mapfile -t wl < <(world_list)
  ((${#wl[@]})) || die "World vazio. Use: adm world add <nome>"
  local n
  for n in "${wl[@]}"; do
    local bf
    bf="$(find_buildfile_by_name "$n")"
    [[ -n "$bf" ]] || die "World item '$n' sem buildfile em $PKGROOT"
    cmd_build "$bf"
  done
  ok "upgrade concluído"
}

cmd_rebuild(){
  # rebuild do sistema inteiro (world) — remove e build novamente em ordem
  step "rebuild world"
  confirm "Isso vai rebuildar TODO o world. Continuar?" || die "Cancelado."
  cmd_upgrade
}

cmd_sync(){
  [[ -n "$REPO_URL" ]] || die "Defina REPO_URL no ambiente ou /etc para usar sync."
  need git
  step "sync repo"
  if [[ -d "$REPO_DIR/.git" ]]; then
    run "(cd '$REPO_DIR' && git fetch --all --prune && git pull --rebase)"
  else
    run "rm -rf '$REPO_DIR'"
    run "git clone '$REPO_URL' '$REPO_DIR'"
  fi
  # opcional: linkar packages do repo para PKGROOT
  if [[ -d "$REPO_DIR/packages" ]]; then
    step "sync packages -> $PKGROOT"
    if [[ "$DRYRUN" == "0" ]]; then
      rsync -a --delete "$REPO_DIR/packages/" "$PKGROOT/"
    else
      echo "DRY-RUN: rsync packages"
    fi
  fi
  ok "sync ok"
}

cmd_clean(){
  step "clean"
  confirm "Limpar workdir ($WORK)?" && run "rm -rf '$WORK'/*" || true
  confirm "Limpar cache de sources ($SRC_CACHE)?" && run "rm -rf '$SRC_CACHE'/*" || true
  confirm "Limpar cache de bins ($BIN_CACHE)?" && run "rm -rf '$BIN_CACHE'/*" || true
  confirm "Limpar logs ($LOGDIR)?" && run "find '$LOGDIR' -type f -name 'adm-*.log' -delete" || true
  ok "clean concluído"
}

cmd_info(){
  local name="$1"
  [[ -n "$name" ]] || die "Uso: adm info <nome>"
  if installed "$name"; then
    ok "$name instalado"
    echo "name=$(db_get "$name" name)"
    echo "version=$(db_get "$name" version)"
    echo "category=$(db_get "$name" category)"
    echo "depends=$(db_get "$name" depends)"
    echo "build_depends=$(db_get "$name" build_depends)"
    echo "installed_at=$(db_get "$name" installed_at)"
    echo "manifest=$(dbp "$name")/manifest"
    echo "package=$(db_get "$name" package)"
  else
    warn "$name NÃO instalado"
  fi
}

cmd_search(){
  local q="${1:-}"
  [[ -n "$q" ]] || die "Uso: adm search <texto>"
  step "search: $q"
  # busca em buildfiles no PKGROOT e sinaliza se instalado
  find "$PKGROOT" -type f -name build -path "*/build/build" 2>/dev/null | while read -r bf; do
    local n
    n="$(grep -E '^NAME=' "$bf" | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
    [[ -z "$n" ]] && continue
    if echo "$n" | grep -qi -- "$q"; then
      if installed "$n"; then
        printf '%b\n' "[$(printf '✔️')] $n  (build: $bf)"
      else
        printf '%b\n' "[ ] $n  (build: $bf)"
      fi
    fi
  done
}

usage(){
  cat <<USAGE
adm $ADM_VERSION

Comandos:
  build <buildfile>           Constrói (deps + ciclo) e instala (DESTDIR+manifest), empacota e cacheia
  remove <nome> [--force]     Uninstall inteligente (manifest + reverse-deps)
  info <nome>                Info (mostra [ ✔️] se instalado)
  search <texto>             Procura programa (mostra [✔️] se instalado)
  world add|del|list <nome>  Controla rolling (upgrade rebuilda world)
  upgrade                    Rebuild inteligente do world
  rebuild                    Rebuild do world (atalho)
  sync                       Atualiza scripts do seu repo git (REPO_URL)
  clean                      Limpeza total (work/cache/logs)

Opções globais:
  -y|--yes       assume sim
  -n|--dry-run   simula tudo
  --keep-work    mantém workdir
  --resume       tenta retomar (não limpa workdir)
  --no-clean     não limpa antes de construir
  -j N           paralelismo

Notas:
- Patches: pasta patch/ ao lado do buildfile.
- Files: pasta files/ ao lado do buildfile (copiado para staging sempre).
USAGE
}

main(){
  local cmd="${1:-help}"; shift || true

  # opções
  while [[ "$cmd" == -* ]]; do
    case "$cmd" in
      -y|--yes) ASSUME_YES=1 ;;
      -n|--dry-run) DRYRUN=1 ;;
      --keep-work) KEEP_WORK=1 ;;
      --resume) RESUME=1 ;;
      --no-clean) CLEAN_BEFORE=0 ;;
      -j) JOBS="${1:-}"; shift ;;
      *) die "Opção desconhecida: $cmd" ;;
    esac
    cmd="${1:-help}"; shift || true
  done

  case "$cmd" in
    help|-h|--help) usage; exit 0 ;;
    version) echo "$ADM_VERSION"; exit 0 ;;
  esac

  need_root
  lock
  log_init
  init_dirs

  case "$cmd" in
    build)   cmd_build "${1:-}" ;;
    remove)
      local name="${1:-}"; shift || true
      local force=0
      [[ "${1:-}" == "--force" ]] && force=1
      cmd_remove "$name" "$force"
      ;;
    info)    cmd_info "${1:-}" ;;
    search)  cmd_search "${1:-}" ;;
    world)
      local sub="${1:-list}" name="${2:-}"
      case "$sub" in
        list) world_list ;;
        add) [[ -n "$name" ]] || die "Uso: adm world add <nome>"; world_add "$name"; ok "world add: $name" ;;
        del) [[ -n "$name" ]] || die "Uso: adm world del <nome>"; world_del "$name"; ok "world del: $name" ;;
        *) die "Uso: adm world [list|add|del] <nome>" ;;
      esac
      ;;
    upgrade) cmd_upgrade ;;
    rebuild) cmd_rebuild ;;
    sync)    cmd_sync ;;
    clean)   cmd_clean ;;
    *) die "Comando desconhecido: $cmd (use: adm help)" ;;
  esac
}

main "$@"
