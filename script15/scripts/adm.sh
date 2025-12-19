#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

ADM_VERSION="2.0.0"

# ---------------- Paths / Policy ----------------
ADM_ROOT="${ADM_ROOT:-/usr/local/adm}"
PKGROOT="${PKGROOT:-$ADM_ROOT/packages}"         # /usr/local/adm/packages/<cat>/<prog>/{build,patch,files}
REPO_URL="${REPO_URL:-}"                         # opcional: repo git remoto com packages/
REPO_DIR="${REPO_DIR:-$ADM_ROOT/repo}"           # destino do sync
STATE="${STATE:-/var/lib/adm}"
DB="$STATE/db"
WORLD="$STATE/world"
FILEMAP="$STATE/filemap"                         # arquivo->dono (pkg)
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
FORCE_FILES=0

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

# Sem eval: executa comando com quoting correto
run(){
  if [[ "$DRYRUN" == "1" ]]; then
    printf '%b\n' "${D}DRY-RUN:${Z} $*"
    return 0
  fi
  "$@"
}
run_sh(){
  # para casos onde você precisa de shell (ex.: pipes). Use com cuidado.
  if [[ "$DRYRUN" == "1" ]]; then
    printf '%b\n' "${D}DRY-RUN(sh):${Z} $*"
    return 0
  fi
  bash -lc "$*"
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
  run mkdir -p "$LOGDIR"
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
  run mkdir -p "$ADM_ROOT" "$PKGROOT" "$STATE" "$DB" "$CACHE" "$SRC_CACHE" "$BIN_CACHE" "$WORK" "$LOGDIR"
  run touch "$WORLD"
  run touch "$FILEMAP"
}

# ---------------- DB ----------------
dbp(){ echo "$DB/$1"; }
installed(){ [[ -d "$(dbp "$1")" ]]; }
db_get(){ [[ -f "$(dbp "$1")/$2" ]] && cat "$(dbp "$1")/$2" || true; }
db_list(){ find "$DB" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort; }

db_record(){
  local name="$1" ver="$2" cat="$3" deps="$4" bdeps="$5" buildfile="$6"
  run mkdir -p "$(dbp "$name")"
  printf '%s\n' "$name" >"$(dbp "$name")/name"
  printf '%s\n' "$ver"  >"$(dbp "$name")/version"
  printf '%s\n' "$cat"  >"$(dbp "$name")/category"
  printf '%s\n' "$deps" >"$(dbp "$name")/depends"
  printf '%s\n' "$bdeps" >"$(dbp "$name")/build_depends"
  printf '%s\n' "$buildfile" >"$(dbp "$name")/buildfile"
  date -Is >"$(dbp "$name")/installed_at"
}
db_set_manifest(){
  local name="$1" mf="$2"
  [[ -s "$mf" ]] || die "$name: manifest ausente/vazio (obrigatório)."
  run cp -f "$mf" "$(dbp "$name")/manifest"
}
db_set_pkgref(){
  local name="$1" pkg="$2"
  printf '%s\n' "$pkg" >"$(dbp "$name")/package"
}

rdeps(){
  local t="$1"
  for p in $(db_list); do
    [[ -f "$(dbp "$p")/depends" ]] || continue
    if grep -qw -- "$t" "$(dbp "$p")/depends"; then echo "$p"; fi
  done
}

world_list(){ sed '/^\s*$/d' "$WORLD" | sort -u; }
world_add(){ printf '%s\n' "$1" >>"$WORLD"; sort -u -o "$WORLD" "$WORLD"; }
world_del(){
  if [[ "$DRYRUN" == "1" ]]; then echo "DRY-RUN: removeria $1 do world"; return 0; fi
  grep -vx -- "$1" "$WORLD" >"$WORLD.tmp" || true
  mv -f "$WORLD.tmp" "$WORLD"
}

# ---------------- Layout helpers (NOVO) ----------------
# Agora: /usr/local/adm/packages/<cat>/<prog>/build (arquivo)
buildfile_path_catprog(){
  local cat="$1" prog="$2"
  echo "$PKGROOT/$cat/$prog/build"
}
patch_dir_catprog(){
  local cat="$1" prog="$2"
  echo "$PKGROOT/$cat/$prog/patch"
}
files_dir_catprog(){
  local cat="$1" prog="$2"
  echo "$PKGROOT/$cat/$prog/files"
}

# Dado um buildfile, patch/files são irmãos no mesmo diretório do programa
patch_dir_for_bf(){
  local bf="$1"
  echo "$(cd "$(dirname "$bf")" && pwd)/patch"
}
files_dir_for_bf(){
  local bf="$1"
  echo "$(cd "$(dirname "$bf")" && pwd)/files"
}

# ---------------- Buildfile discovery ----------------
# Procura por arquivos chamados "build" diretamente em <cat>/<prog>/build
find_buildfiles(){
  find "$PKGROOT" -type f -name build -perm -111 2>/dev/null
}
find_buildfile_by_name(){
  local needle="$1"
  local bf=""
  while IFS= read -r p; do
    # evita executar: só parseia a linha NAME= (simples)
    local n
    n="$(grep -E '^NAME=' "$p" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs echo -n)"
    [[ "$n" == "$needle" ]] && { bf="$p"; break; }
  done < <(find_buildfiles)
  [[ -n "$bf" ]] && echo "$bf" || true
}
find_buildfile_by_catprog(){
  local cat="$1" prog="$2"
  local bf; bf="$(buildfile_path_catprog "$cat" "$prog")"
  [[ -f "$bf" ]] && echo "$bf" || true
}

# ---------------- Buildfile parsing ----------------
# Buildfile é um shell script com variáveis:
# NAME CATEGORY VERSION URL/URLS/GIT SHA256/MD5 DEPENDS BUILD_DEPENDS
# Multi-source real suportado por:
#   URLS=(...); SHA256S=(...); MD5S=(...)
# Se SHA256S/MD5S ausentes, usa SHA256/MD5 como "espelho".
load_buildfile(){
  local bf="$1"
  [[ -f "$bf" ]] || die "Buildfile não encontrado: $bf"

  # limpa hooks antigos
  for fn in pkg_env pkg_prepare pkg_configure pkg_build pkg_install pkg_post; do
    declare -F "$fn" >/dev/null 2>&1 && unset -f "$fn" || true
  done

  # limpa vars antigas
  unset NAME CATEGORY VERSION URL SHA256 MD5 DEPENDS BUILD_DEPENDS
  unset URLS SHA256S MD5S
  unset GIT GIT_REF GIT_COMMIT
  unset PREFIX BUILD_SYSTEM CONFIGURE_OPTS MAKE_OPTS INSTALL_OPTS MESON_OPTS CMAKE_OPTS
  unset TOOLCHAIN LINKER
  unset ALLOW_FILE_CONFLICTS

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
  ALLOW_FILE_CONFLICTS=0

  # carrega
  # shellcheck disable=SC1090
  source "$bf"

  [[ -n "${NAME:-}" ]] || die "Buildfile sem NAME: $bf"
  [[ -n "${CATEGORY:-}" ]] || CATEGORY="misc"
  [[ -n "${VERSION:-}" ]] || die "$NAME: VERSION obrigatório"

  if [[ -z "${URL:-}" && -z "${URLS:-}" && -z "${GIT:-}" ]]; then
    die "$NAME: defina URL ou URLS[] ou GIT"
  fi

  # checksums: para git, exigimos pin em commit
  if [[ -n "${GIT:-}" ]]; then
    [[ -n "${GIT_COMMIT:-}" ]] || die "$NAME: para GIT, defina GIT_COMMIT=<hash> (pin obrigatório)"
  else
    if [[ -z "${SHA256:-}" && -z "${MD5:-}" && -z "${SHA256S:-}" && -z "${MD5S:-}" ]]; then
      die "$NAME: defina SHA256/MD5 ou SHA256S[]/MD5S[]"
    fi
  fi
}

# ---------------- Checksums (corrigido) ----------------
# Regra: tenta SHA256; se falhar e houver MD5, tenta MD5 antes de declarar falha.
verify_file(){
  local f="$1" sha="${2:-}" md5="${3:-}"
  need sha256sum md5sum awk

  if [[ -n "$sha" ]]; then
    local got; got="$(sha256sum "$f" | awk '{print $1}')"
    [[ "$got" == "$sha" ]] && return 0
    # fallback MD5 se fornecido
    if [[ -n "$md5" ]]; then
      got="$(md5sum "$f" | awk '{print $1}')"
      [[ "$got" == "$md5" ]] && return 0
    fi
    return 1
  fi

  if [[ -n "$md5" ]]; then
    local got; got="$(md5sum "$f" | awk '{print $1}')"
    [[ "$got" == "$md5" ]] && return 0
    return 1
  fi
  return 1
}

# ---------------- Source fetch + cache ----------------
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
    run rm -f "$out"
  fi

  step "$NAME: download $base"
  run curl -fL --retry 3 --retry-delay 2 -o "$out.part" "$url"
  run mv -f "$out.part" "$out"

  if ! verify_file "$out" "$sha" "$md5"; then
    run rm -f "$out"
    die "$NAME: checksum falhou após download. Arquivo removido."
  fi
  ok "checksum ok: $base"
  echo "$out"
}

fetch_git(){
  local giturl="$1" ref="${2:-}" commit="$3"
  need git
  local dir="$SRC_CACHE/git-${NAME}"
  if [[ -d "$dir/.git" ]]; then
    step "$NAME: git fetch"
    run_sh "cd '$dir' && git fetch --all --prune"
  else
    step "$NAME: git clone"
    run rm -rf "$dir"
    run git clone --recursive "$giturl" "$dir"
  fi

  # checkout ref (opcional), mas sempre valida commit pin
  if [[ -n "$ref" ]]; then
    step "$NAME: git checkout $ref"
    run_sh "cd '$dir' && git checkout -f '$ref' && git submodule update --init --recursive"
  fi

  step "$NAME: git pin $commit"
  run_sh "cd '$dir' && git checkout -f '$commit' && git submodule update --init --recursive"
  local head
  head="$(run_sh "cd '$dir' && git rev-parse HEAD" || true)"
  [[ "$head" == "$commit" ]] || die "$NAME: pin inválido (HEAD=$head esperado=$commit)"

  echo "$dir"
}

# ---------------- Patch/files ----------------
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
  run rm -rf "$outdir"
  run mkdir -p "$outdir"
  local top; top="$(tar -tf "$tarball" | head -n1 | cut -d/ -f1)"
  run tar -xf "$tarball" -C "$outdir"
  [[ -d "$outdir/$top" ]] || die "$NAME: falha ao extrair"
  echo "$outdir/$top"
}

# ---------------- Build helper ----------------
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
declare -A VIS=()
declare -a ORDER=()

dfs_resolve(){
  local bf="$1"
  load_buildfile "$bf"
  local key="$NAME"
  [[ "${VIS[$key]:-}" == "perm" ]] && return
  [[ "${VIS[$key]:-}" == "temp" ]] && die "Ciclo de dependências detectado envolvendo: $key"
  VIS["$key"]="temp"

  local d depbf
  for d in $BUILD_DEPENDS $DEPENDS; do
    [[ -z "$d" ]] && continue
    depbf=""
    if [[ "$d" == */* ]]; then
      local c="${d%%/*}" p="${d##*/}"
      depbf="$(find_buildfile_by_catprog "$c" "$p")"
      [[ -n "$depbf" ]] || die "$NAME: dependência $d sem buildfile: $(buildfile_path_catprog "$c" "$p")"
    else
      depbf="$(find_buildfile_by_name "$d")"
      if [[ -z "$depbf" ]]; then
        installed "$d" && continue
        die "$NAME: dependência '$d' não instalada e sem buildfile."
      fi
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

# ---------------- Resume checkpoints ----------------
ckdir(){ echo "$STATE/checkpoints/$1"; }
ck_has(){ [[ -f "$(ckdir "$1")/$2" ]]; }
ck_set(){ run mkdir -p "$(ckdir "$1")"; printf '%s\n' "1" >"$(ckdir "$1")/$2"; }

# ---------------- Packaging: tar.zst fallback tar.xz + meta ----------------
write_meta(){
  local stagedir="$1"
  run mkdir -p "$stagedir/.adm"
  cat >"$stagedir/.adm/meta" <<META
NAME=$NAME
VERSION=$VERSION
CATEGORY=$CATEGORY
DEPENDS=$DEPENDS
BUILD_DEPENDS=$BUILD_DEPENDS
META
}
pack_stage(){
  local stagedir="$1" name="$2" ver="$3"
  need tar
  run mkdir -p "$BIN_CACHE"

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

# ---------------- File ownership (corrigido) ----------------
# FILEMAP: "path<TAB>pkg"
file_owner(){
  local p="$1"
  awk -v p="$p" -F'\t' '$1==p{print $2; exit}' "$FILEMAP" 2>/dev/null || true
}
filemap_remove_pkg(){
  local pkg="$1"
  if [[ "$DRYRUN" == "1" ]]; then
    echo "DRY-RUN: removeria entradas do filemap para $pkg"
    return 0
  fi
  awk -F'\t' -v pkg="$pkg" '$2!=pkg{print}' "$FILEMAP" >"$FILEMAP.tmp" || true
  mv -f "$FILEMAP.tmp" "$FILEMAP"
}
filemap_add_manifest(){
  local pkg="$1" mf="$2"
  if [[ "$DRYRUN" == "1" ]]; then
    echo "DRY-RUN: adicionaria filemap para $pkg"
    return 0
  fi
  # remove entradas antigas desse pkg e adiciona novas
  filemap_remove_pkg "$pkg"
  while IFS= read -r p; do
    [[ -z "$p" || "$p" == "/" ]] && continue
    printf '%s\t%s\n' "$p" "$pkg"
  done <"$mf" >>"$FILEMAP"
}

check_collisions(){
  local mf="$1"
  local allow="${ALLOW_FILE_CONFLICTS:-0}"
  [[ "$FORCE_FILES" == "1" ]] && return 0
  [[ "$allow" == "1" ]] && return 0

  local bad=0
  while IFS= read -r p; do
    [[ -z "$p" || "$p" == "/" ]] && continue
    local owner; owner="$(file_owner "$p")"
    if [[ -n "$owner" && "$owner" != "$NAME" ]]; then
      warn "colisão: $p já pertence a $owner"
      bad=1
    fi
  done <"$mf"

  [[ "$bad" -eq 0 ]] || die "$NAME: colisões detectadas (use --force-files ou ALLOW_FILE_CONFLICTS=1 no buildfile)."
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
remove_by_manifest_owned(){
  local pkg="$1" mf="$2"
  [[ -f "$mf" ]] || die "manifest não encontrado: $mf"
  if [[ "$DRYRUN" == "1" ]]; then
    echo "DRY-RUN: removeria paths de $pkg (somente os que pertencem ao pacote)"
    return 0
  fi
  tac "$mf" | while IFS= read -r p; do
    [[ -z "$p" || "$p" == "/" ]] && continue
    local owner; owner="$(file_owner "$p")"
    [[ "$owner" == "$pkg" ]] || continue
    if [[ -e "$p" || -L "$p" ]]; then
      rm -f -- "$p" 2>/dev/null || true
      rmdir --ignore-fail-on-non-empty -p -- "$(dirname "$p")" 2>/dev/null || true
    fi
  done
}

# ---------------- Install package file (bin cache) ----------------
read_meta_from_pkg(){
  local pkgfile="$1"
  local tmp="$WORK/.adm-meta.$$"
  run rm -rf "$tmp"
  run mkdir -p "$tmp"

  case "$pkgfile" in
    *.zst) need zstd tar; run_sh "zstd -dc '$pkgfile' | tar -xpf - -C '$tmp' ./.adm/meta" ;;
    *.xz)  need xz tar;  run_sh "xz -dc '$pkgfile' | tar -xpf - -C '$tmp' ./.adm/meta" ;;
    *) die "Pacote desconhecido: $pkgfile" ;;
  esac
  [[ -f "$tmp/.adm/meta" ]] || die "Pacote sem meta: $pkgfile"
  cat "$tmp/.adm/meta"
  run rm -rf "$tmp"
}

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

# ---------------- Build pipeline per package ----------------
build_one(){
  local bf="$1"
  load_buildfile "$bf"
  pick_toolchain

  local pdir; pdir="$(patch_dir_for_bf "$bf")"
  local fdir; fdir="$(files_dir_for_bf "$bf")"

  local wdir="$WORK/${NAME}-${VERSION}"
  local srcdir="$wdir/src"
  local staged="$wdir/stage"
  local mf="$wdir/manifest.txt"

  # Clean sempre antes (default); resume pula
  if [[ "$CLEAN_BEFORE" == "1" && "$RESUME" == "0" ]]; then
    step "$NAME: clean before build"
    run rm -rf "$wdir"
    ok "limpo"
  fi
  run mkdir -p "$wdir" "$staged"

  # fontes
  if [[ "$RESUME" == "1" && -d "$srcdir" ]]; then
    ok "$NAME: resume (srcdir existente)"
  else
    run rm -rf "$srcdir"

    if [[ -n "${GIT:-}" ]]; then
      local gitroot
      gitroot="$(fetch_git "$GIT" "${GIT_REF:-}" "$GIT_COMMIT")"
      run cp -a "$gitroot" "$srcdir"
    else
      run mkdir -p "$wdir/distfiles"
      local primary=""
      # multi-source real (arrays) ou espelhos (URLS string)
      if declare -p URLS >/dev/null 2>&1; then
        # URLS é array
        local i=0
        while true; do
          local u
          u="$(eval "printf '%s' \"\${URLS[$i]:-}\"")"
          [[ -n "$u" ]] || break
          local sha md5
          sha="$(eval "printf '%s' \"\${SHA256S[$i]:-${SHA256:-}}\"")"
          md5="$(eval "printf '%s' \"\${MD5S[$i]:-${MD5:-}}\"")"
          local f; f="$(fetch_url "$u" "$sha" "$md5")"
          run cp -f "$f" "$wdir/distfiles/"
          [[ -z "$primary" ]] && primary="$f"
          i=$((i+1))
        done
      elif [[ -n "${URLS:-}" ]]; then
        # URLS é lista (espelhos)
        local u
        for u in $URLS; do
          local f; f="$(fetch_url "$u" "${SHA256:-}" "${MD5:-}")"
          run cp -f "$f" "$wdir/distfiles/"
          [[ -z "$primary" ]] && primary="$f"
        done
      else
        primary="$(fetch_url "$URL" "${SHA256:-}" "${MD5:-}")"
        run cp -f "$primary" "$wdir/distfiles/"
      fi

      [[ -n "$primary" ]] || die "$NAME: sem source principal para extrair"
      local unpacked
      unpacked="$(extract_tarball "$primary" "$wdir/unpack")"
      run cp -a "$unpacked" "$srcdir"
    fi
  fi

  # patch
  if [[ "$RESUME" == "1" && ck_has "$NAME" "patched" ]]; then
    ok "$NAME: resume (patched)"
  else
    apply_patches "$srcdir" "$pdir"
    ck_set "$NAME" "patched"
  fi

  # hooks opcionais
  declare -F pkg_env >/dev/null 2>&1 && (cd "$srcdir" && pkg_env) || true
  declare -F pkg_prepare >/dev/null 2>&1 && (cd "$srcdir" && pkg_prepare) || true

  # configure/build/install helper
  local sys
  sys="$(cd "$srcdir" && detect_build_system)"
  step "$NAME: build-system=$sys"

  local bld="$wdir/builddir"

  if [[ "$RESUME" == "1" && ck_has "$NAME" "configured" ]]; then
    ok "$NAME: resume (configured)"
  else
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
          run rm -rf "$bld"
          run mkdir -p "$bld"
          (cd "$srcdir" && meson setup "$bld" --prefix="$PREFIX" --buildtype=release $MESON_OPTS)
          ;;
        cmake)
          need cmake
          run rm -rf "$bld"
          run mkdir -p "$bld"
          (cd "$srcdir" && cmake -S . -B "$bld" -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release $CMAKE_OPTS)
          ;;
        *) : ;;
      esac
    fi
    ck_set "$NAME" "configured"
  fi

  if [[ "$RESUME" == "1" && ck_has "$NAME" "built" ]]; then
    ok "$NAME: resume (built)"
  else
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
    ck_set "$NAME" "built"
  fi

  # install to DESTDIR staging
  step "$NAME: install DESTDIR"
  run rm -rf "$staged"
  run mkdir -p "$staged"

  if declare -F pkg_install >/dev/null 2>&1; then
    (cd "$srcdir" && DESTDIR="$staged" pkg_install)
  else
    case "$sys" in
      autotools|make) (cd "$srcdir" && make install DESTDIR="$staged" $INSTALL_OPTS) ;;
      meson)          need ninja; (cd "$srcdir" && DESTDIR="$staged" ninja -C "$bld" install) ;;
      cmake)          (cd "$srcdir" && DESTDIR="$staged" cmake --install "$bld") ;;
      cargo)
        need cargo
        (cd "$srcdir" && cargo install --path . --root "$staged$PREFIX" --locked --force)
        ;;
      go)
        die "$NAME: go install default é ambíguo. Defina pkg_install no buildfile."
        ;;
      *) (cd "$srcdir" && make install DESTDIR="$staged" $INSTALL_OPTS) ;;
    esac
  fi

  # files/ sempre
  if [[ -d "$fdir" ]]; then
    step "$NAME: apply files/"
    (cd "$fdir" && tar -cpf - .) | (cd "$staged" && tar -xpf -)
  fi

  # meta + manifest
  write_meta "$staged"
  manifest_from_stage "$staged" "$mf"

  # colisões antes do commit
  check_collisions "$mf"

  # pacote binário
  local pkg; pkg="$(pack_stage "$staged" "$NAME" "$VERSION")"

  # upgrade inteligente: remover obsoletos SOMENTE se pertencem ao pacote
  if installed "$NAME"; then
    local oldm="$(dbp "$NAME")/manifest"
    if [[ -f "$oldm" && "$DRYRUN" == "0" ]]; then
      step "$NAME: remove obsolete files (owned)"
      comm -23 <(sort "$oldm") <(sort "$mf") | tac | while IFS= read -r p; do
        [[ -z "$p" || "$p" == "/" ]] && continue
        local owner; owner="$(file_owner "$p")"
        [[ "$owner" == "$NAME" ]] || continue
        if [[ -e "$p" || -L "$p" ]]; then
          rm -f -- "$p" 2>/dev/null || true
          rmdir --ignore-fail-on-non-empty -p -- "$(dirname "$p")" 2>/dev/null || true
        fi
      done
      ok "obsoletos removidos"
    fi
  fi

  # commit
  commit_stage "$staged"

  # pós (corrigido: agora executa)
  declare -F pkg_post >/dev/null 2>&1 && (cd "$srcdir" && pkg_post) || true

  # DB + file ownership
  db_record "$NAME" "$VERSION" "$CATEGORY" "$DEPENDS" "$BUILD_DEPENDS" "$bf"
  db_set_manifest "$NAME" "$mf"
  db_set_pkgref "$NAME" "$pkg"
  filemap_add_manifest "$NAME" "$mf"

  ok "instalado/atualizado: $NAME-$VERSION"
  if [[ "$KEEP_WORK" != "1" ]]; then
    run rm -rf "$wdir"
  else
    warn "KEEP_WORK=1 mantendo workdir: $wdir"
  fi
}

# ---------------- Build command (corrigido) ----------------
# Agora aceita:
#   adm build zlib
#   adm build cat prog
#   adm build /caminho/para/build
cmd_build(){
  local a1="${1:-}" a2="${2:-}"
  [[ -n "$a1" ]] || die "Uso: adm build <nome|cat prog|buildfile>"

  local bf=""
  if [[ -f "$a1" ]]; then
    bf="$a1"
  elif [[ -n "$a2" ]]; then
    bf="$(find_buildfile_by_catprog "$a1" "$a2")"
    [[ -n "$bf" ]] || die "Não encontrei buildfile para $a1/$a2 em $PKGROOT"
  else
    bf="$(find_buildfile_by_name "$a1")"
    [[ -n "$bf" ]] || die "Não encontrei buildfile para '$a1' em $PKGROOT"
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

# ---------------- Install (bin cache) com deps ----------------
pkgfile_for(){
  local name="$1"
  if installed "$name"; then
    # se já instalado, ainda pode ter package no DB
    local p; p="$(db_get "$name" package)"
    [[ -n "$p" && -f "$p" ]] && { echo "$p"; return 0; }
  fi
  # tenta achar no bin cache (pega o mais novo)
  ls -1t "$BIN_CACHE/${name}-"*.tar.* 2>/dev/null | head -n1 || true
}

install_name(){
  local name="$1"
  [[ -n "$name" ]] || die "Uso: adm install <nome>"
  if installed "$name"; then
    ok "$name já está instalado"
    return 0
  fi

  # precisa do buildfile para deps
  local bf; bf="$(find_buildfile_by_name "$name")"
  [[ -n "$bf" ]] || die "Sem buildfile para '$name' em $PKGROOT"

  load_buildfile "$bf"

  # instala deps primeiro
  local d
  for d in $DEPENDS; do
    [[ -z "$d" ]] && continue
    # dependências nomeadas: assume NAME
    if [[ "$d" == */* ]]; then
      local c="${d%%/*}" p="${d##*/}"
      local dbf; dbf="$(find_buildfile_by_catprog "$c" "$p")"
      [[ -n "$dbf" ]] || die "$NAME: dep $d sem buildfile"
      load_buildfile "$dbf"
      install_name "$NAME"
    else
      install_name "$d"
    fi
  done

  # tenta instalar binário do cache; senão constrói
  local pkg; pkg="$(pkgfile_for "$name")"
  if [[ -n "$pkg" ]]; then
    # para instalar via pacote, precisamos gerar manifest+filemap também:
    # preferimos construir se não há DB ainda. Aqui fazemos build se não tiver DB.
    warn "$name: pacote binário encontrado, mas DB/manifest são gerados no build. Construindo para registro correto."
    cmd_build "$bf"
  else
    cmd_build "$bf"
  fi
}

cmd_install(){
  install_name "${1:-}"
}

# ---------------- Remove (corrigido com filemap) ----------------
cmd_remove(){
  local name="$1" force="${2:-0}"
  [[ -n "$name" ]] || die "Uso: adm remove <nome> [--force]"
  installed "$name" || die "Não instalado: $name"

  local rd; rd="$(rdeps "$name" || true)"
  if [[ -n "$rd" && "$force" != "1" ]]; then
    die "Reverse-deps impedem remoção: $(echo "$rd" | tr '\n' ' ') (use --force)"
  fi

  local mf="$(dbp "$name")/manifest"
  confirm "Remover $name pelo manifest (somente arquivos pertencentes ao pacote)?" || die "Cancelado."
  step "$name: uninstall"
  remove_by_manifest_owned "$name" "$mf"
  filemap_remove_pkg "$name"
  run rm -rf "$(dbp "$name")"
  ok "removido: $name"
}

# ---------------- Upgrade/Rebuild ----------------
cmd_upgrade(){
  step "upgrade (world)"
  mapfile -t wl < <(world_list)
  ((${#wl[@]})) || die "World vazio. Use: adm world add <nome>"
  local n
  for n in "${wl[@]}"; do
    cmd_build "$n"
  done
  ok "upgrade concluído"
}
cmd_rebuild(){
  step "rebuild world"
  confirm "Isso vai rebuildar TODO o world. Continuar?" || die "Cancelado."
  cmd_upgrade
}

# ---------------- Sync ----------------
cmd_sync(){
  [[ -n "$REPO_URL" ]] || die "Defina REPO_URL para usar sync."
  need git rsync
  step "sync repo"
  if [[ -d "$REPO_DIR/.git" ]]; then
    run_sh "cd '$REPO_DIR' && git fetch --all --prune && git pull --rebase"
  else
    run rm -rf "$REPO_DIR"
    run git clone "$REPO_URL" "$REPO_DIR"
  fi
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

# ---------------- Clean/Info/Search ----------------
cmd_clean(){
  step "clean"
  confirm "Limpar workdir ($WORK)?" && run_sh "rm -rf '$WORK'/*" || true
  confirm "Limpar cache de sources ($SRC_CACHE)?" && run_sh "rm -rf '$SRC_CACHE'/*" || true
  confirm "Limpar cache de bins ($BIN_CACHE)?" && run_sh "rm -rf '$BIN_CACHE'/*" || true
  confirm "Limpar checkpoints ($STATE/checkpoints)?" && run_sh "rm -rf '$STATE/checkpoints'/*" || true
  confirm "Limpar logs ($LOGDIR)?" && run_sh "find '$LOGDIR' -type f -name 'adm-*.log' -delete" || true
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
    echo "buildfile=$(db_get "$name" buildfile)"
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
  find_buildfiles | while IFS= read -r bf; do
    local n
    n="$(grep -E '^NAME=' "$bf" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs echo -n)"
    [[ -z "$n" ]] && continue
    if echo "$n" | grep -qi -- "$q"; then
      if installed "$n"; then
        printf '%b\n' "[✔️] $n  (build: $bf)"
      else
        printf '%b\n' "[ ]  $n  (build: $bf)"
      fi
    fi
  done
}

usage(){
  cat <<USAGE
adm $ADM_VERSION

Layout:
  $PKGROOT/<categoria>/<programa>/{build,patch/,files/}

Comandos:
  build <nome|cat prog|buildfile>   Constrói (deps+ciclo) e instala, empacota e cacheia
  install <nome>                   Instala por nome (resolve deps; build para registrar corretamente)
  remove <nome> [--force]          Uninstall inteligente (manifest+reverse-deps+filemap)
  info <nome>                      Info (mostra [ ✔️] se instalado)
  search <texto>                   Procura programa (mostra [✔️] se instalado)
  world add|del|list <nome>        Controla rolling
  upgrade                          Rebuild inteligente do world
  rebuild                          Rebuild do world
  sync                             Atualiza scripts do seu repo git (REPO_URL)
  clean                            Limpeza total (work/cache/logs/checkpoints)

Opções globais:
  -y|--yes         assume sim
  -n|--dry-run     simula tudo
  --keep-work      mantém workdir
  --resume         tenta retomar (não limpa workdir)
  --no-clean       não limpa antes de construir
  --force-files    ignora colisões de arquivos
  -j N             paralelismo
USAGE
}

main(){
  local cmd="${1:-help}"; shift || true

  while [[ "$cmd" == -* ]]; do
    case "$cmd" in
      -y|--yes) ASSUME_YES=1 ;;
      -n|--dry-run) DRYRUN=1 ;;
      --keep-work) KEEP_WORK=1 ;;
      --resume) RESUME=1 ;;
      --no-clean) CLEAN_BEFORE=0 ;;
      --force-files) FORCE_FILES=1 ;;
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
    build)    cmd_build "${1:-}" "${2:-}" ;;
    install)  cmd_install "${1:-}" ;;
    remove)
      local name="${1:-}"; shift || true
      local force=0
      [[ "${1:-}" == "--force" ]] && force=1
      cmd_remove "$name" "$force"
      ;;
    info)     cmd_info "${1:-}" ;;
    search)   cmd_search "${1:-}" ;;
    world)
      local sub="${1:-list}" name="${2:-}"
      case "$sub" in
        list) world_list ;;
        add) [[ -n "$name" ]] || die "Uso: adm world add <nome>"; world_add "$name"; ok "world add: $name" ;;
        del) [[ -n "$name" ]] || die "Uso: adm world del <nome>"; world_del "$name"; ok "world del: $name" ;;
        *) die "Uso: adm world [list|add|del] <nome>" ;;
      esac
      ;;
    upgrade)  cmd_upgrade ;;
    rebuild)  cmd_rebuild ;;
    sync)     cmd_sync ;;
    clean)    cmd_clean ;;
    *) die "Comando desconhecido: $cmd (use: adm help)" ;;
  esac
}

main "$@"
