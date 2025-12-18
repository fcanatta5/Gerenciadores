sudo install -d /usr/local/adm /usr/local/adm/packages /var/lib/adm /var/log/adm /var/cache/adm /var/tmp/adm-build
sudo tee /usr/sbin/adm >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

ADM_VERSION="3.0.0"

# Layout requerido pelo usuário
ADM_ROOT="/usr/local/adm"
PKGROOT="$ADM_ROOT/packages"          # /usr/local/adm/packages/<cat>/<prog>/build/{patch,files}
STATE="/var/lib/adm"                 # DB/estado
LOGDIR="/var/log/adm"
CACHEDIR="/var/cache/adm"            # fontes
BUILDDIR="/var/tmp/adm-build"        # builds (limpável)

LOCK="/run/adm.lock"
WORLD="$STATE/world"

ASSUME_YES=0
DRYRUN=0
KEEP_BUILD=0
RESUME=0
CLEAN_BEFORE=1
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 1)}"
EDITOR="${EDITOR:-vi}"

# ---------- UI ----------
if [[ -t 2 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; M=$'\033[35m'; C=$'\033[36m'; D=$'\033[2m'; Z=$'\033[0m'
else
  R="";G="";Y="";B="";M="";C="";D="";Z=""
fi

hr(){ printf '%s\n' "${D}────────────────────────────────────────────────────────${Z}"; }
tag(){ printf '%b\n' "${C}[adm]${Z} $*"; }
ok(){  printf '%b\n' "${G}✔${Z} $*"; }
warn(){printf '%b\n' "${Y}⚠${Z} $*"; }
die(){ printf '%b\n' "${R}✖${Z} $*"; exit 1; }

step() {
  local name="$1"
  hr
  printf '%b\n' "${B}▶${Z} ${M}${name}${Z}"
  hr
}

run() {
  if [[ "$DRYRUN" == "1" ]]; then
    printf '%b\n' "${D}DRY-RUN:${Z} $*"
  else
    eval "$@"
  fi
}

confirm() {
  local q="$1"
  [[ "$ASSUME_YES" == "1" ]] && return 0
  read -r -p "$q [s/N]: " a || true
  [[ "${a,,}" == "s" || "${a,,}" == "sim" || "${a,,}" == "y" || "${a,,}" == "yes" ]]
}

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Execute como root."; }
have(){ command -v "$1" >/dev/null 2>&1; }
need(){ local m=(); for c in "$@"; do have "$c" || m+=("$c"); done; ((${#m[@]}==0)) || die "Faltam comandos: ${m[*]}"; }

lock() { exec 9>"$LOCK" || die "Não abri lock"; flock -n 9 || die "adm já está rodando."; }

log_init() {
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

init_dirs() {
  run "mkdir -p '$PKGROOT' '$STATE/db' '$CACHEDIR/src' '$BUILDDIR' '$LOGDIR'"
  run "touch '$WORLD'"
}

# ---------- DB ----------
dbp(){ echo "$STATE/db/$1"; }
db_has(){ [[ -d "$(dbp "$1")" ]]; }
db_get(){ [[ -f "$(dbp "$1")/$2" ]] && cat "$(dbp "$1")/$2" || true; }

db_list(){ find "$STATE/db" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort; }

db_record() {
  local name="$1" ver="$2" cat="$3" deps="$4" bdeps="$5" provides="$6"
  run "mkdir -p '$(dbp "$name")'"
  run "printf '%s\n' '$name' > '$(dbp "$name")/name'"
  run "printf '%s\n' '$ver'  > '$(dbp "$name")/version'"
  run "printf '%s\n' '$cat'  > '$(dbp "$name")/category'"
  run "printf '%s\n' '$deps' > '$(dbp "$name")/depends'"
  run "printf '%s\n' '$bdeps' > '$(dbp "$name")/build_depends'"
  run "printf '%s\n' '$provides' > '$(dbp "$name")/provides'"
  run "date -Is > '$(dbp "$name")/installed_at'"
}

db_set_manifest() {
  local name="$1" mf="$2"
  [[ -s "$mf" ]] || die "Manifest ausente/vazio para $name (obrigatório)."
  run "cp -f '$mf' '$(dbp "$name")/manifest'"
}

# Reverse-deps (runtime)
rdeps(){
  local t="$1" out=0
  for p in $(db_list); do
    [[ -f "$(dbp "$p")/depends" ]] || continue
    if grep -qw -- "$t" "$(dbp "$p")/depends"; then
      echo "$p"; out=1
    fi
  done
  [[ "$out" -eq 1 ]] || true
}

# World
world_list(){ sed '/^\s*$/d' "$WORLD" | sort -u; }
world_add(){ run "printf '%s\n' '$1' >> '$WORLD'"; run "sort -u -o '$WORLD' '$WORLD'"; }
world_del(){
  if [[ "$DRYRUN" == "1" ]]; then echo "DRY-RUN: removeria $1 do world"; return 0; fi
  grep -vx -- "$1" "$WORLD" > "$WORLD.tmp" || true
  mv -f "$WORLD.tmp" "$WORLD"
}

# ---------- Package layout ----------
pkgdir(){ echo "$PKGROOT/$1/$2"; }           # cat/prog
builddir(){ echo "$(pkgdir "$1" "$2")/build"; }
patchdir(){ echo "$(builddir "$1" "$2")/patch"; }
filesdir(){ echo "$(builddir "$1" "$2")/files"; }
buildscript(){ echo "$(builddir "$1" "$2")/build"; }   # arquivo "build" (script)

# ---------- State for resume ----------
statedir(){ echo "$STATE/state/$1"; }      # por pacote (nome)
st_mark(){ run "mkdir -p '$(statedir "$1")'"; run "printf '%s\n' '1' > '$(statedir "$1")/$2'"; }
st_has(){ [[ -f "$(statedir "$1")/$2" ]]; }
st_clear(){ run "rm -rf '$(statedir "$1")'"; }

# ---------- Fetch/Extract/Patch ----------
need_fetch_tools(){
  need curl sha256sum tar find sed awk grep cut head sort xargs
}

fetch_src(){
  local name="$1" url="$2" sha="$3"
  need_fetch_tools
  local base; base="$(basename "${url%%\?*}")"
  local out="$CACHEDIR/src/$base"

  step "$name: fetch"
  if [[ -f "$out" ]]; then
    ok "Fonte já existe: $out"
  else
    run "curl -fL --retry 3 --retry-delay 2 -o '$out.part' '$url'"
    run "mv -f '$out.part' '$out'"
    ok "Baixado: $out"
  fi

  [[ -n "$sha" ]] || die "$name: SHA256 obrigatório."
  local got; got="$(sha256sum "$out" | awk '{print $1}')"
  [[ "$got" == "$sha" ]] || die "$name: SHA256 inválido. esperado=$sha obtido=$got"
  ok "SHA256 OK"
  echo "$out"
}

extract_src(){
  local name="$1" tarball="$2" work="$3"
  step "$name: extract"
  run "rm -rf '$work/src' && mkdir -p '$work/src'"
  local top; top="$(tar -tf "$tarball" | head -n1 | cut -d/ -f1)"
  run "tar -xf '$tarball' -C '$work/src'"
  local src="$work/src/$top"
  [[ -d "$src" ]] || die "$name: falha ao extrair (src não encontrado)."
  ok "Extraído em $src"
  echo "$src"
}

apply_patches(){
  local name="$1" src="$2" pdir="$3"
  step "$name: patch"
  [[ -d "$pdir" ]] || { ok "Sem patches"; return 0; }
  local patches=()
  while IFS= read -r -d '' f; do patches+=("$f"); done < <(find "$pdir" -maxdepth 1 -type f \( -name "*.patch" -o -name "*.diff" \) -print0 | sort -z)

  if ((${#patches[@]}==0)); then
    ok "Sem patches"
    return 0
  fi

  need patch
  local i=0
  for pf in "${patches[@]}"; do
    ((i++))
    tag "Aplicando patch ($i/${#patches[@]}): $(basename "$pf")"
    # tenta -p1, senão -p0
    if patch -d "$src" -p1 --forward --silent < "$pf"; then
      ok "patch -p1 OK"
    elif patch -d "$src" -p0 --forward --silent < "$pf"; then
      ok "patch -p0 OK"
    else
      die "$name: falha ao aplicar patch $(basename "$pf")"
    fi
  done
}

# ---------- Build engine (inteligente) ----------
# O build script do pacote define variáveis e opcionalmente funções:
#  - pkg_prepare, pkg_configure, pkg_build, pkg_install
# Se não definir, o adm tenta defaults: configure/make/make install DESTDIR.
load_pkg_buildscript(){
  local cat="$1" prog="$2"
  local bs; bs="$(buildscript "$cat" "$prog")"
  [[ -f "$bs" && -x "$bs" ]] || die "Build script ausente/não executável: $bs"
  # limpa possíveis funções anteriores
  for fn in pkg_prepare pkg_configure pkg_build pkg_install pkg_env; do
    declare -F "$fn" >/dev/null 2>&1 && unset -f "$fn" || true
  done

  # shellcheck disable=SC1090
  source "$bs"

  [[ -n "${NAME:-}" ]] || NAME="$prog"
  [[ -n "${CATEGORY:-}" ]] || CATEGORY="$cat"
  [[ -n "${VERSION:-}" ]] || die "$cat/$prog: VERSION obrigatório no build script"
  [[ -n "${URL:-}" ]] || die "$cat/$prog: URL obrigatório no build script"
  [[ -n "${SHA256:-}" ]] || die "$cat/$prog: SHA256 obrigatório no build script"
  : "${DEPENDS:=}"
  : "${BUILD_DEPENDS:=}"
  : "${PROVIDES:=}"
  : "${PREFIX:=/usr}"
  : "${CONFIGURE_OPTS:=}"
  : "${MAKE_OPTS:=}"
  : "${INSTALL_OPTS:=}"
}

# ---------- Dependency resolver ----------
declare -A VIS=()
declare -a ORDER=()

resolve_dfs(){
  local cat="$1" prog="$2" key="$cat/$prog"
  [[ "${VIS[$key]:-}" == "perm" ]] && return 0
  [[ "${VIS[$key]:-}" == "temp" ]] && die "Ciclo de dependência detectado: $key"
  VIS["$key"]="temp"

  load_pkg_buildscript "$cat" "$prog"
  # deps e build_deps (ambos precisam existir instalados ou como pacote)
  local dep
  for dep in $BUILD_DEPENDS $DEPENDS; do
    # formato esperado: categoria/programa
    if [[ "$dep" == */* ]]; then
      local dcat="${dep%%/*}" dprog="${dep##*/}"
      [[ -f "$(buildscript "$dcat" "$dprog")" ]] || die "$key: dep $dep não existe em packages/"
      resolve_dfs "$dcat" "$dprog"
    else
      # permitir dependência “virtual” via PROVIDES (instalado)
      # aqui exige que exista instalado ou você use formato cat/prog nas receitas
      db_has "$dep" || warn "$key: dep '$dep' não é cat/prog e não está no DB (você deve padronizar em cat/prog)."
    fi
  done

  VIS["$key"]="perm"
  ORDER+=("$key")
}

resolve_order(){
  VIS=(); ORDER=()
  resolve_dfs "$1" "$2"
  printf '%s\n' "${ORDER[@]}"
}

# ---------- Install staging + manifest ----------
# Instala em DESTDIR (staging) SEM tocar em /, gera manifest, depois “commit” para /
# Isso permite uninstall/upgrade limpo.
commit_staging(){
  local name="$1" stage="$2" manifest="$3"
  step "$name: commit"
  [[ -d "$stage" ]] || die "$name: staging inexistente"

  # aplica files/ (conteúdo extra do pacote) no staging
  if [[ -d "$FILES_DIR" ]]; then
    tag "Copiando files/ para staging"
    (cd "$FILES_DIR" && tar -cpf - .) | (cd "$stage" && tar -xpf -)
  fi

  # manifest = lista absoluta do que será instalado
  ( cd "$stage" && find . -mindepth 1 -print | sed 's|^\./|/|' | sort ) > "$manifest"
  [[ -s "$manifest" ]] || die "$name: manifest vazio"

  if [[ "$DRYRUN" == "1" ]]; then
    echo "DRY-RUN: commit de $(wc -l < "$manifest") paths"
    return 0
  fi

  # commit: tar pipe (preserva permissões)
  ( cd "$stage" && tar -cpf - . ) | ( cd / && tar -xpf - )
  ok "Commit OK"
}

remove_by_manifest(){
  local name="$1" mf="$2"
  [[ -f "$mf" ]] || die "$name: sem manifest"
  if [[ "$DRYRUN" == "1" ]]; then
    echo "DRY-RUN: removeria $(wc -l < "$mf") paths"
    return 0
  fi
  # remove em ordem reversa
  tac "$mf" | while IFS= read -r p; do
    [[ -z "$p" || "$p" == "/" ]] && continue
    if [[ -e "$p" || -L "$p" ]]; then
      rm -f -- "$p" 2>/dev/null || true
      rmdir --ignore-fail-on-non-empty -p -- "$(dirname "$p")" 2>/dev/null || true
    fi
  done
}

# ---------- Build pipeline per package ----------
build_one(){
  local cat="$1" prog="$2" key="$cat/$prog"
  load_pkg_buildscript "$cat" "$prog"

  local name="$NAME"
  local work="$BUILDDIR/${cat}-${prog}-${VERSION}"
  local stage="$work/stage"
  local manifest="$work/manifest.txt"
  local pdir; pdir="$(patchdir "$cat" "$prog")"
  FILES_DIR="$(filesdir "$cat" "$prog")"   # usado no commit

  # limpeza antes de construir (requisito)
  if [[ "$CLEAN_BEFORE" == "1" && "$RESUME" == "0" ]]; then
    step "$name: clean before build"
    run "rm -rf '$work'"
    st_clear "$name"
    ok "Limpo"
  fi

  run "mkdir -p '$work' '$stage'"

  # fetch
  if [[ "$RESUME" == "1" && st_has "$name" "fetched" ]]; then
    ok "$name: retomando (fetch já feito)"
    local tarball; tarball="$(ls -1 "$CACHEDIR/src/"* 2>/dev/null | grep -F "$(basename "${URL%%\?*}")" | head -n1 || true)"
    [[ -n "$tarball" ]] || tarball="$(fetch_src "$name" "$URL" "$SHA256")"
  else
    local tarball; tarball="$(fetch_src "$name" "$URL" "$SHA256")"
    st_mark "$name" "fetched"
  fi

  # extract
  local src
  if [[ "$RESUME" == "1" && st_has "$name" "extracted" && -d "$work/src" ]]; then
    ok "$name: retomando (extract já feito)"
    src="$(find "$work/src" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
    [[ -n "$src" ]] || src="$(extract_src "$name" "$tarball" "$work")"
  else
    src="$(extract_src "$name" "$tarball" "$work")"
    st_mark "$name" "extracted"
  fi

  # patches automáticos
  if [[ "$RESUME" == "1" && st_has "$name" "patched" ]]; then
    ok "$name: retomando (patch já feito)"
  else
    apply_patches "$name" "$src" "$pdir"
    st_mark "$name" "patched"
  fi

  # ambiente do pacote
  if declare -F pkg_env >/dev/null 2>&1; then
    step "$name: env"
    ( cd "$src" && pkg_env )
    ok "env OK"
  fi

  # prepare
  if declare -F pkg_prepare >/dev/null 2>&1; then
    step "$name: prepare"
    ( cd "$src" && pkg_prepare )
    ok "prepare OK"
  fi

  # configure (default: ./configure)
  if [[ "$RESUME" == "1" && st_has "$name" "configured" ]]; then
    ok "$name: retomando (configure já feito)"
  else
    step "$name: configure"
    if declare -F pkg_configure >/dev/null 2>&1; then
      ( cd "$src" && pkg_configure )
    else
      if [[ -x "$src/configure" ]]; then
        run "(cd '$src' && ./configure --prefix='$PREFIX' $CONFIGURE_OPTS)"
      else
        warn "$name: sem ./configure (defina pkg_configure no build script, se necessário)"
      fi
    fi
    st_mark "$name" "configured"
    ok "configure OK"
  fi

  # build (default: make)
  if [[ "$RESUME" == "1" && st_has "$name" "built" ]]; then
    ok "$name: retomando (build já feito)"
  else
    step "$name: build"
    if declare -F pkg_build >/dev/null 2>&1; then
      ( cd "$src" && pkg_build )
    else
      run "(cd '$src' && make -j'$JOBS' $MAKE_OPTS)"
    fi
    st_mark "$name" "built"
    ok "build OK"
  fi

  # install: staging obrigatório
  if [[ "$RESUME" == "1" && st_has "$name" "installed" ]]; then
    ok "$name: retomando (install já feito)"
  else
    step "$name: install (staging)"
    run "rm -rf '$stage' && mkdir -p '$stage'"
    if declare -F pkg_install >/dev/null 2>&1; then
      # pkg_install deve instalar em $stage (DESTDIR)
      ( cd "$src" && DESTDIR="$stage" pkg_install )
    else
      # default: make install DESTDIR=
      run "(cd '$src' && make install DESTDIR='$stage' $INSTALL_OPTS)"
    fi
    st_mark "$name" "installed"
    ok "install OK"
  fi

  # upgrade inteligente: remove arquivos antigos que sumiram
  local oldm=""
  if db_has "$name"; then
    oldm="$(dbp "$name")/manifest"
    if [[ -f "$oldm" ]]; then
      step "$name: upgrade cleanup (old files not in new)"
      # gera manifest novo no commit_staging; aqui faremos depois e então limpamos diff.
      ok "Preparado"
    fi
  fi

  # commit + manifest
  commit_staging "$name" "$stage" "$manifest"

  # cleanup diff de manifests (só agora temos manifest novo)
  if [[ -n "$oldm" && -f "$oldm" && "$DRYRUN" == "0" ]]; then
    step "$name: removing obsolete files"
    comm -23 <(sort "$oldm") <(sort "$manifest") | tac | while IFS= read -r p; do
      [[ -z "$p" || "$p" == "/" ]] && continue
      if [[ -e "$p" || -L "$p" ]]; then
        rm -f -- "$p" 2>/dev/null || true
        rmdir --ignore-fail-on-non-empty -p -- "$(dirname "$p")" 2>/dev/null || true
      fi
    done
    ok "Obsoletos removidos"
  fi

  # DB record
  db_record "$name" "$VERSION" "$cat" "$DEPENDS" "$BUILD_DEPENDS" "$PROVIDES"
  db_set_manifest "$name" "$manifest"

  ok "Instalado/Atualizado: $name ($VERSION)"

  # final: limpar build dir (opcional)
  if [[ "$KEEP_BUILD" != "1" ]]; then
    run "rm -rf '$work'"
  else
    warn "KEEP_BUILD=1: mantendo $work"
  fi
}

# ---------- High-level commands ----------
cmd_build(){
  local cat="${1:-}" prog="${2:-}"
  [[ -n "$cat" && -n "$prog" ]] || die "Uso: adm build <categoria> <programa>"
  mapfile -t o < <(resolve_order "$cat" "$prog")
  step "Build order"
  printf '%b\n' "${G}${o[*]}${Z}"
  for key in "${o[@]}"; do
    local c="${key%%/*}" p="${key##*/}"
    build_one "$c" "$p"
  done
}

cmd_remove(){
  local name="${1:-}" force="${2:-0}"
  [[ -n "$name" ]] || die "Uso: adm remove <nome> [--force]"
  db_has "$name" || die "Não instalado: $name"
  local rd; rd="$(rdeps "$name" || true)"
  if [[ -n "$rd" && "$force" != "1" ]]; then
    die "Reverse-deps impedem remoção: $(echo "$rd" | tr '\n' ' '). Use --force se quiser quebrar."
  fi
  local mf; mf="$(dbp "$name")/manifest"
  confirm "Remover $name pelo manifest?" || die "Cancelado."
  step "$name: uninstall"
  remove_by_manifest "$name" "$mf"
  run "rm -rf '$(dbp "$name")'"
  ok "Removido: $name"
}

cmd_clean(){
  # limpeza do sistema
  step "System clean"
  confirm "Limpar builds temporários em $BUILDDIR?" && run "rm -rf '$BUILDDIR'/*" || true
  confirm "Limpar cache de fontes em $CACHEDIR/src (cuidado)?" && run "rm -rf '$CACHEDIR/src'/*" || true
  confirm "Limpar estados de resume em $STATE/state?" && run "rm -rf '$STATE/state'/*" || true
  ok "Clean concluído"
}

cmd_orphans(){
  # Órfãos: instalados que não estão no world e não são deps de ninguém
  step "Orphans"
  local wl tmp
  wl="$(mktemp)"; tmp="$(mktemp)"
  world_list > "$wl" || true
  db_list > "$tmp" || true
  while IFS= read -r pkg; do
    grep -qx -- "$pkg" "$wl" && continue
    local used=0
    for p in $(db_list); do
      [[ -f "$(dbp "$p")/depends" ]] || continue
      if grep -qw -- "$pkg" "$(dbp "$p")/depends"; then used=1; break; fi
    done
    [[ "$used" -eq 0 ]] && echo "$pkg"
  done < "$tmp"
  rm -f "$wl" "$tmp"
}

cmd_health(){
  step "Health"
  have uname && echo "kernel=$(uname -r)"
  have ps && ps -p 1 -o pid,comm,args || true
  have df && df -hT || true
  ok "Health concluído"
}

cmd_list(){
  # lista packages existentes no layout
  step "Packages tree"
  find "$PKGROOT" -mindepth 3 -maxdepth 3 -type d -name build -printf "%h\n" 2>/dev/null \
  | sed "s|^$PKGROOT/||" | sort
}

cmd_info(){
  local name="${1:-}"
  [[ -n "$name" ]] || die "Uso: adm info <nome>"
  db_has "$name" || die "Não instalado: $name"
  echo "name=$(db_get "$name" name)"
  echo "version=$(db_get "$name" version)"
  echo "category=$(db_get "$name" category)"
  echo "depends=$(db_get "$name" depends)"
  echo "build_depends=$(db_get "$name" build_depends)"
  echo "provides=$(db_get "$name" provides)"
  echo "installed_at=$(db_get "$name" installed_at)"
  echo "manifest=$(dbp "$name")/manifest ($(wc -l < "$(dbp "$name")/manifest" 2>/dev/null || echo 0) paths)"
}

cmd_world(){
  local sub="${1:-list}" arg="${2:-}"
  case "$sub" in
    list) world_list ;;
    add) [[ -n "$arg" ]] || die "Uso: adm world add <nome>"; world_add "$arg"; ok "world add: $arg" ;;
    del) [[ -n "$arg" ]] || die "Uso: adm world del <nome>"; world_del "$arg"; ok "world del: $arg" ;;
    *) die "Uso: adm world [list|add|del] <nome>" ;;
  esac
}

usage(){
  cat <<USAGE
adm $ADM_VERSION
Layout: $PKGROOT/<categoria>/<programa>/build/{build,patch/,files/}

Comandos:
  list                               Lista packages disponíveis no layout
  build <cat> <prog>                 Resolve deps e constrói (clean antes por padrão)
  build --resume <cat> <prog>        Retoma etapas concluídas (fetch/extract/...)
  remove <nome> [--force]            Uninstall inteligente (manifest + reverse-deps)
  info <nome>                        Info do pacote instalado
  world [list|add|del] <nome>        World set (rolling)
  rdeps <nome>                       Reverse-deps
  orphans                            Lista órfãos
  clean                              Limpezas (build/cache/state)
  health                             Checagens rápidas
Opções:
  -y|--yes        assume sim
  -n|--dry-run    simula
  -j N            jobs
  --keep-build    não apaga workdir
  --no-clean      não limpa antes de construir
USAGE
}

main(){
  local cmd="${1:-help}"; shift || true

  # opções globais
  while [[ "$cmd" == -* ]]; do
    case "$cmd" in
      -y|--yes) ASSUME_YES=1 ;;
      -n|--dry-run) DRYRUN=1 ;;
      -j) JOBS="${1:-}"; shift ;;
      --keep-build) KEEP_BUILD=1 ;;
      --resume) RESUME=1 ;;
      --no-clean) CLEAN_BEFORE=0 ;;
      *) die "Opção desconhecida: $cmd" ;;
    esac
    cmd="${1:-help}"; shift || true
  done

  case "$cmd" in
    help|--help|-h) usage; exit 0 ;;
    version) echo "$ADM_VERSION"; exit 0 ;;
  esac

  need_root
  lock
  log_init
  init_dirs

  case "$cmd" in
    list) cmd_list ;;
    build)
      if [[ "${1:-}" == "--resume" ]]; then RESUME=1; shift; fi
      cmd_build "${1:-}" "${2:-}"
      ;;
    remove)
      local name="${1:-}"; shift || true
      local force=0
      [[ "${1:-}" == "--force" ]] && force=1
      cmd_remove "$name" "$force"
      ;;
    info) cmd_info "${1:-}" ;;
    world) cmd_world "${1:-list}" "${2:-}" ;;
    rdeps) rdeps "${1:-}" ;;
    orphans) cmd_orphans ;;
    clean) cmd_clean ;;
    health) cmd_health ;;
    *) die "Comando desconhecido: $cmd (use: adm help)" ;;
  esac
}

main "$@"
EOF
sudo chmod +x /usr/sbin/adm
