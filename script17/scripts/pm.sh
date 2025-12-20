#!/bin/sh
# pm.sh - gerenciador de pacotes minimalista (POSIX sh), foco musl
#
# Layout de receitas: pkgs/<categoria>/<programa>/
#   meta, build.sh, files/, patch/
#
# Requisitos esperados (BusyBox OK):
#   sh, find, sort, awk, sed, tar, xz, sha256sum, mkdir, rm, mv, date
# Opcionais conforme uso:
#   git (sync/push), patch (patch/), strip (PM_STRIP=1), wget/curl (nas receitas)
#
# Uso: ./pm.sh help

set -eu

PM_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKGS_DIR="$PM_ROOT/pkgs"
STATE_DIR="$PM_ROOT/state"
DB_DIR="$STATE_DIR/db"
CACHE_DIR="$STATE_DIR/cache"      # cache de binários .tar.xz
LOG_DIR="$STATE_DIR/logs"
BUILD_ROOT="$STATE_DIR/build"
LOCK_DIR="$STATE_DIR/lock"

: "${PM_PREFIX:=/usr/local}"      # prefix alvo: a receita instala em DESTDIR + PM_PREFIX
: "${PM_JOBS:=1}"                 # paralelismo sugerido às receitas
: "${PM_STRIP:=1}"                # 1 = tenta strip (best effort)
: "${PM_GIT_REMOTE:=origin}"      # git remote
: "${PM_UPGRADE_REBUILD_ON_DEP_CHANGE:=1}"  # 1 = rebuild se snapshot de deps mudou
: "${PM_ASSUME_TAR_SAFE:=0}"      # 0 = valida tarball antes de extrair em /
: "${PM_LOCK_TIMEOUT:=0}"         # 0 = sem timeout; se >0, tenta esperar X segundos

umask 022

mkdir -p "$PKGS_DIR" "$DB_DIR" "$CACHE_DIR" "$LOG_DIR" "$BUILD_ROOT" "$LOCK_DIR"

log() {
  lvl=$1; shift
  ts=$(date -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)
  printf "%s [%s] %s\n" "$ts" "$lvl" "$*" | tee -a "$LOG_DIR/pm.log" >&2
}

die() { log "ERROR" "$*"; exit 1; }

need_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Comando requerido não encontrado: $c"
  done
}

safe_rm_rf() {
  p=$1
  [ -n "$p" ] || die "safe_rm_rf: path vazio"
  case "$p" in
    "/"|"/bin"|"/sbin"|"/usr"|"/etc"|"/var"|"/home") die "safe_rm_rf: recusando apagar caminho crítico: $p" ;;
  esac
  rm -rf -- "$p"
}

# -------------------------
# Lock simples (mkdir lockdir)
# -------------------------
acquire_lock() {
  name=$1
  lock="$LOCK_DIR/$name.lock"
  start=$(date +%s 2>/dev/null || echo 0)
  while ! mkdir "$lock" 2>/dev/null; do
    if [ "$PM_LOCK_TIMEOUT" -gt 0 ] 2>/dev/null; then
      now=$(date +%s 2>/dev/null || echo 0)
      if [ "$start" -ne 0 ] && [ "$now" -ne 0 ]; then
        elapsed=$((now - start))
        [ "$elapsed" -ge "$PM_LOCK_TIMEOUT" ] && die "Timeout aguardando lock: $name"
      fi
    fi
    sleep 1
  done
  echo "$lock"
}

release_lock() {
  lock=$1
  [ -n "$lock" ] || return 0
  rmdir "$lock" 2>/dev/null || true
}

# -------------------------
# Resolução de receita: ID = "categoria/pacote"
# Permite chamar por "pacote" se for único.
# -------------------------
pkg_resolve() {
  q=$1
  # Já parece cat/pkg?
  case "$q" in
    */*)
      [ -d "$PKGS_DIR/$q" ] || die "Receita não encontrada: $q"
      printf "%s\n" "$q"
      return 0
      ;;
  esac

  # Buscar por nome único
  found=""
  # pkgs/<cat>/<pkg>
  # shellcheck disable=SC2039
  for d in "$PKGS_DIR"/*/"$q"; do
    [ -d "$d" ] || continue
    rel=${d#"$PKGS_DIR"/}
    if [ -z "$found" ]; then
      found=$rel
    else
      die "Pacote ambíguo '$q'. Use categoria/pacote. Exemplos: '$found' e '$rel'"
    fi
  done
  [ -n "$found" ] || die "Receita não encontrada para: $q"
  printf "%s\n" "$found"
}

pkg_path() {
  id=$1
  printf "%s/%s\n" "$PKGS_DIR" "$id"
}

pkg_cat() {
  id=$1
  echo "$id" | awk -F/ '{print $1}'
}

pkg_name() {
  id=$1
  echo "$id" | awk -F/ '{print $2}'
}

# -------------------------
# Meta
# -------------------------
meta_load() {
  # define: PKGNAME, PKGVER, DEPS, DESC
  id=$1
  pdir=$(pkg_path "$id")
  m="$pdir/meta"
  [ -f "$m" ] || die "Meta não encontrada: $id/meta"
  # shellcheck disable=SC1090
  . "$m"
  : "${PKGNAME:=$(pkg_name "$id")}"
  : "${PKGVER:?PKGVER não definido em $id/meta}"
  : "${DEPS:=}"
  : "${DESC:=}"
}

# Hash determinístico do conteúdo da receita (inclui meta/build.sh/files/patch)
pkg_recipe_hash() {
  id=$1
  pdir=$(pkg_path "$id")
  [ -d "$pdir" ] || die "Pacote inexistente: $id"
  (
    cd "$pdir"
    # lista determinística + hash de conteúdo
    find . -type f -maxdepth 4 2>/dev/null \
      | LC_ALL=C sort \
      | while IFS= read -r f; do
          [ -f "$f" ] || continue
          printf "%s\0" "$f"
          sha256sum "$f" | awk '{print $1}'
          printf "\0"
        done
  ) | sha256sum | awk '{print $1}'
}

# -------------------------
# DB
# -------------------------
db_installed_dir() { printf "%s/installed/%s\n" "$DB_DIR" "$1"; }
db_is_installed() { [ -f "$(db_installed_dir "$1")/meta" ]; }

db_write_kv() {
  f=$1 k=$2 v=$3
  mkdir -p "$(dirname -- "$f")"
  if [ -f "$f" ]; then
    awk -v K="$k" -v V="$v" 'BEGIN{FS=OFS="="} $1==K{$0=K"="V;found=1} {print} END{if(!found)print K"="V}' "$f" >"$f.tmp"
    mv -f "$f.tmp" "$f"
  else
    printf "%s=%s\n" "$k" "$v" >"$f"
  fi
}

db_get_kv() {
  f=$1 k=$2
  [ -f "$f" ] || return 1
  awk -F= -v K="$k" '$1==K{print substr($0,index($0,"=")+1);exit}' "$f"
}

# owners index: texto "path<TAB>pkgid"
OWNERS_FILE="$DB_DIR/owners.tsv"

owners_get() {
  path=$1
  [ -f "$OWNERS_FILE" ] || return 1
  awk -v P="$path" -F '\t' '$1==P{print $2; exit}' "$OWNERS_FILE"
}

owners_set_if_empty() {
  path=$1 pkgid=$2
  cur=$(owners_get "$path" 2>/dev/null || true)
  [ -n "${cur:-}" ] && return 0
  mkdir -p "$(dirname -- "$OWNERS_FILE")"
  printf "%s\t%s\n" "$path" "$pkgid" >>"$OWNERS_FILE"
}

owners_remove_if_owner() {
  path=$1 pkgid=$2
  [ -f "$OWNERS_FILE" ] || return 0
  awk -v P="$path" -v O="$pkgid" -F '\t' '!( $1==P && $2==O )' "$OWNERS_FILE" >"$OWNERS_FILE.tmp" || true
  mv -f "$OWNERS_FILE.tmp" "$OWNERS_FILE"
}

db_track_file() {
  pkgid=$1 file=$2
  idir=$(db_installed_dir "$pkgid")
  mkdir -p "$idir"
  printf "%s\n" "$file" >>"$idir/files.list"
  owners_set_if_empty "$file" "$pkgid"
}

# deps snapshot: gravamos em installed/<id>/deps.snapshot
db_write_deps_snapshot() {
  pkgid=$1
  idir=$(db_installed_dir "$pkgid")
  mkdir -p "$idir"
  snap="$idir/deps.snapshot"
  : >"$snap"
  meta_load "$pkgid"
  for d in $DEPS; do
    did=$(pkg_resolve "$d")
    if db_is_installed "$did"; then
      dv=$(db_get_kv "$(db_installed_dir "$did")/meta" PKGVER 2>/dev/null || echo "unknown")
    else
      dv="not-installed"
    fi
    printf "%s=%s\n" "$did" "$dv" >>"$snap"
  done
  sha256sum "$snap" | awk '{print $1}' >"$idir/deps.snapshot.sha256"
}

db_deps_snapshot_hash() {
  pkgid=$1
  f="$(db_installed_dir "$pkgid")/deps.snapshot.sha256"
  [ -f "$f" ] || return 1
  awk '{print $1; exit}' "$f"
}

# reverse deps
db_track_revdep_add() {
  pkgid=$1 depid=$2
  d="$DB_DIR/revdeps/$depid"
  mkdir -p "$d"
  f="$d/list"
  touch "$f"
  if ! grep -qx "$pkgid" "$f" 2>/dev/null; then
    printf "%s\n" "$pkgid" >>"$f"
  fi
}

db_track_revdep_remove() {
  pkgid=$1 depid=$2
  f="$DB_DIR/revdeps/$depid/list"
  [ -f "$f" ] || return 0
  grep -vx "$pkgid" "$f" >"$f.tmp" || true
  mv -f "$f.tmp" "$f"
}

revdeps_list() {
  depid=$1
  f="$DB_DIR/revdeps/$depid/list"
  [ -f "$f" ] || return 0
  cat "$f"
}

db_mark_installed() {
  pkgid=$1
  meta_load "$pkgid"
  idir=$(db_installed_dir "$pkgid")
  mkdir -p "$idir"
  rhash=$(pkg_recipe_hash "$pkgid")
  db_write_kv "$idir/meta" "PKGID" "$pkgid"
  db_write_kv "$idir/meta" "CATEGORY" "$(pkg_cat "$pkgid")"
  db_write_kv "$idir/meta" "PKGNAME" "$PKGNAME"
  db_write_kv "$idir/meta" "PKGVER" "$PKGVER"
  db_write_kv "$idir/meta" "RECIPE_HASH" "$rhash"
  db_write_kv "$idir/meta" "DESC" "$DESC"
  db_write_kv "$idir/meta" "INSTALLED_AT" "$(date -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)"

  # registra DEPS do momento (para uninstall correto mesmo se receita mudar depois)
  depsfile="$idir/deps.list"
  : >"$depsfile"
  for d in $DEPS; do
    printf "%s\n" "$(pkg_resolve "$d")" >>"$depsfile"
  done

  # deps -> revdeps
  for depid in $(cat "$depsfile" 2>/dev/null || true); do
    db_track_revdep_add "$pkgid" "$depid"
  done

  db_write_deps_snapshot "$pkgid"
}

# -------------------------
# Solver de dependências (DFS com detecção de ciclo)
# Saída: ordem topológica em stdout (pkgid por linha)
# -------------------------
solve_deps() {
  tmp="$BUILD_ROOT/.solve.$$"
  mkdir -p "$tmp"
  visiting="$tmp/visiting"
  visited="$tmp/visited"
  order="$tmp/order"
  : >"$visiting"; : >"$visited"; : >"$order"

  dfs() {
    q=$1
    id=$(pkg_resolve "$q")
    [ -d "$(pkg_path "$id")" ] || die "Receita não encontrada: $id"

    if grep -qx "$id" "$visited" 2>/dev/null; then
      return 0
    fi
    if grep -qx "$id" "$visiting" 2>/dev/null; then
      die "Ciclo detectado nas dependências envolvendo: $id"
    fi

    printf "%s\n" "$id" >>"$visiting"
    meta_load "$id"
    for d in $DEPS; do
      dfs "$d"
    done

    grep -vx "$id" "$visiting" >"$visiting.tmp" || true
    mv -f "$visiting.tmp" "$visiting"

    printf "%s\n" "$id" >>"$visited"
    printf "%s\n" "$id" >>"$order"
  }

  for root in "$@"; do
    dfs "$root"
  done

  cat "$order"
  safe_rm_rf "$tmp"
}

# -------------------------
# Build/Package/Install
# -------------------------
apply_patches() {
  pkgid=$1 srcdir=$2
  pdir="$(pkg_path "$pkgid")/patch"
  [ -d "$pdir" ] || return 0
  need_cmd patch
  find "$pdir" -type f -maxdepth 1 2>/dev/null | LC_ALL=C sort | while IFS= read -r pf; do
    log "INFO" "Aplicando patch: $pf"
    (cd "$srcdir" && patch -p1 <"$pf") || die "Falha ao aplicar patch: $pf"
  done
}

copy_files_overlay() {
  pkgid=$1 destdir=$2
  fdir="$(pkg_path "$pkgid")/files"
  [ -d "$fdir" ] || return 0
  log "INFO" "Copiando overlay files/ para DESTDIR"
  (cd "$fdir" && tar -cf - .) | (cd "$destdir" && tar -xpf -)
}

strip_binaries_in_destdir() {
  destdir=$1
  [ "$PM_STRIP" = "1" ] || return 0
  command -v strip >/dev/null 2>&1 || return 0
  find "$destdir" -type f 2>/dev/null | while IFS= read -r f; do
    case "$f" in
      *.a|*.o) continue ;;
    esac
    strip --strip-unneeded "$f" 2>/dev/null || true
  done
}

# Hooks opcionais na receita:
#   hook_pre_install
#   hook_post_install
# (executadas no host, antes/depois de extrair o tarball em /)
run_hook() {
  pkgid=$1 hookname=$2
  pdir=$(pkg_path "$pkgid")
  [ -f "$pdir/build.sh" ] || return 0
  # carregamos build.sh em subshell para não poluir ambiente global
  (
    meta_load "$pkgid"
    export PM_ROOT PM_PREFIX PM_JOBS PKGNAME PKGVER
    # shellcheck disable=SC1090
    . "$pdir/build.sh"
    command -v "$hookname" >/dev/null 2>&1 || exit 0
    "$hookname"
  ) >>"$LOG_DIR/hooks.$(pkg_name "$pkgid").log" 2>&1 || die "Hook $hookname falhou para $pkgid"
}

pkg_build() {
  pkgid=$1
  meta_load "$pkgid"
  pdir=$(pkg_path "$pkgid")
  bdir="$BUILD_ROOT/$pkgid"

  # sempre limpar antes de construir (pedido seu)
  safe_rm_rf "$bdir"
  mkdir -p "$bdir"

  logf="$LOG_DIR/build.$(pkg_cat "$pkgid").$(pkg_name "$pkgid").log"
  : >"$logf"

  WORKDIR="$bdir/work"
  SRCDIR="$bdir/src"
  DESTDIR="$bdir/dest"
  mkdir -p "$WORKDIR" "$SRCDIR" "$DESTDIR"

  export PM_ROOT PM_PREFIX PM_JOBS WORKDIR SRCDIR DESTDIR PKGNAME PKGVER

  [ -f "$pdir/build.sh" ] || die "build.sh não encontrado para $pkgid"
  # shellcheck disable=SC1090
  . "$pdir/build.sh" >/dev/null 2>&1 || true

  command -v pkg_fetch   >/dev/null 2>&1 || die "$pkgid: build.sh deve definir função pkg_fetch"
  command -v pkg_unpack  >/dev/null 2>&1 || die "$pkgid: build.sh deve definir função pkg_unpack"
  command -v pkg_build   >/dev/null 2>&1 || die "$pkgid: build.sh deve definir função pkg_build"
  command -v pkg_install >/dev/null 2>&1 || die "$pkgid: build.sh deve definir função pkg_install"

  log "INFO" "Build iniciado: $pkgid-$PKGVER"
  {
    pkg_fetch
    pkg_unpack
    apply_patches "$pkgid" "$SRCDIR"
    pkg_build
    pkg_install
    copy_files_overlay "$pkgid" "$DESTDIR"
    strip_binaries_in_destdir "$DESTDIR"
  } >>"$logf" 2>&1 || die "Falha no build de $pkgid. Veja: $logf"
  log "INFO" "Build concluído: $pkgid-$PKGVER"
}

pkg_pack() {
  pkgid=$1
  meta_load "$pkgid"
  bdir="$BUILD_ROOT/$pkgid"
  dest="$bdir/dest"
  [ -d "$dest" ] || die "DESTDIR não existe para $pkgid; rode build antes"
  out="$CACHE_DIR/$(pkg_cat "$pkgid")__$(pkg_name "$pkgid")-$PKGVER.tar.xz"
  log "INFO" "Empacotando: $out"
  (cd "$dest" && tar -c .) | xz -T0 -9e >"$out.tmp"
  mv -f "$out.tmp" "$out"
  sha256sum "$out" >"$out.sha256"
  printf "%s\n" "$out"
}

cache_tarball_path() {
  pkgid=$1 ver=$2
  echo "$CACHE_DIR/$(pkg_cat "$pkgid")__$(pkg_name "$pkgid")-$ver.tar.xz"
}

cache_has_pkgver() {
  pkgid=$1 ver=$2
  tb=$(cache_tarball_path "$pkgid" "$ver")
  [ -f "$tb" ] && [ -f "$tb.sha256" ]
}

cache_verify() {
  file=$1
  [ -f "$file.sha256" ] || die "Checksum não encontrado: $file.sha256"
  (cd "$(dirname -- "$file")" && sha256sum -c "$(basename -- "$file").sha256") >/dev/null 2>&1 \
    || die "Checksum inválido para: $file"
}

tarball_is_safe() {
  tb=$1
  # valida entradas: nada de absoluto, nada de .., nada de vazio
  tar -tf "$tb" | while IFS= read -r f; do
    f=${f#./}
    [ -n "$f" ] || continue
    case "$f" in
      /*) exit 2 ;;
      *"../"*|*".."|../*) exit 2 ;;
    esac
  done
}

install_tarball() {
  pkgid=$1 tarball=$2
  cache_verify "$tarball"

  if [ "$PM_ASSUME_TAR_SAFE" != "1" ]; then
    tarball_is_safe "$tarball" || die "Tarball potencialmente inseguro (path traversal): $tarball"
  fi

  run_hook "$pkgid" hook_pre_install

  log "INFO" "Instalando: $pkgid a partir de $tarball (extraindo em /)"
  tar -C / -xJpf "$tarball"

  # registra arquivos instalados (e owners)
  idir=$(db_installed_dir "$pkgid")
  mkdir -p "$idir"
  : >"$idir/files.list"
  tar -tf "$tarball" | while IFS= read -r f; do
    f=${f#./}
    [ -n "$f" ] || continue
    db_track_file "$pkgid" "/$f"
  done

  run_hook "$pkgid" hook_post_install
}

pm_install_one() {
  pkgid=$(pkg_resolve "$1")
  meta_load "$pkgid"

  # Determinação inteligente de necessidade de upgrade:
  need=0
  dep_changed=0

  if db_is_installed "$pkgid"; then
    inst_meta="$(db_installed_dir "$pkgid")/meta"
    inst_ver=$(db_get_kv "$inst_meta" "PKGVER" 2>/dev/null || echo "")
    inst_hash=$(db_get_kv "$inst_meta" "RECIPE_HASH" 2>/dev/null || echo "")
    new_hash=$(pkg_recipe_hash "$pkgid")

    if [ "$inst_ver" != "$PKGVER" ] || [ "$inst_hash" != "$new_hash" ]; then
      need=1
    else
      # receita/versão iguais -> checar snapshot de deps (ABI)
      if [ "$PM_UPGRADE_REBUILD_ON_DEP_CHANGE" = "1" ]; then
        old_snap=$(db_deps_snapshot_hash "$pkgid" 2>/dev/null || echo "")
        # gera snapshot atual em arquivo temp e compara hash
        tmp="$BUILD_ROOT/.depsnap.$$"
        mkdir -p "$tmp"
        cur="$tmp/snap"
        : >"$cur"
        for d in $DEPS; do
          did=$(pkg_resolve "$d")
          if db_is_installed "$did"; then
            dv=$(db_get_kv "$(db_installed_dir "$did")/meta" PKGVER 2>/dev/null || echo "unknown")
          else
            dv="not-installed"
          fi
          printf "%s=%s\n" "$did" "$dv" >>"$cur"
        done
        cur_hash=$(sha256sum "$cur" | awk '{print $1}')
        safe_rm_rf "$tmp"

        if [ -n "$old_snap" ] && [ "$old_snap" != "$cur_hash" ]; then
          dep_changed=1
          need=1
        fi
      fi
    fi

    if [ "$need" -eq 0 ]; then
      log "INFO" "$pkgid já está instalado e atualizado ($PKGVER)."
      return 0
    fi

    if [ "$dep_changed" -eq 1 ]; then
      log "INFO" "Rebuild por mudança de dependências: $pkgid"
    else
      log "INFO" "Upgrade necessário: $pkgid"
    fi
  else
    need=1
  fi

  # tenta instalar do cache; senão compila e empacota
  if cache_has_pkgver "$pkgid" "$PKGVER"; then
    tb=$(cache_tarball_path "$pkgid" "$PKGVER")
    install_tarball "$pkgid" "$tb"
  else
    pkg_build "$pkgid"
    tb=$(pkg_pack "$pkgid")
    install_tarball "$pkgid" "$tb"
  fi

  # marca instalado e registra deps/revdeps/snapshot
  db_mark_installed "$pkgid"
}

# -------------------------
# Uninstall melhorado
# - respeita owners: só remove arquivo se owner==pkg
# - remove diretórios vazios ascendentes de forma conservadora
# - não depende de meta atual: usa deps.list instalado
# Hooks opcionais:
#   hook_pre_remove, hook_post_remove (se definidos na receita)
# -------------------------
run_remove_hook() {
  pkgid=$1 hookname=$2
  pdir=$(pkg_path "$pkgid")
  [ -f "$pdir/build.sh" ] || return 0
  (
    # apenas para dar contexto; pode não existir receita (mas normalmente existe)
    meta_load "$pkgid" || true
    export PM_ROOT PM_PREFIX PM_JOBS PKGNAME PKGVER
    # shellcheck disable=SC1090
    . "$pdir/build.sh" || true
    command -v "$hookname" >/dev/null 2>&1 || exit 0
    "$hookname"
  ) >>"$LOG_DIR/hooks.remove.$(pkg_name "$pkgid").log" 2>&1 || die "Hook $hookname falhou para $pkgid"
}

cmd_remove() {
  [ $# -ge 1 ] || die "Uso: remove <pkg> [pkg...]"
  lock=$(acquire_lock "pm")
  trap 'release_lock "$lock"' EXIT INT TERM

  for q in "$@"; do
    pkgid=$(pkg_resolve "$q")
    db_is_installed "$pkgid" || die "$pkgid não está instalado."

    # bloqueia se houver reverse deps
    r=$(revdeps_list "$pkgid" 2>/dev/null || true)
    if [ -n "${r:-}" ]; then
      die "Não é possível remover $pkgid: requerido por:\n$r"
    fi

    idir=$(db_installed_dir "$pkgid")
    files="$idir/files.list"
    depslist="$idir/deps.list"

    run_remove_hook "$pkgid" hook_pre_remove

    # Remover arquivos do pacote em ordem reversa
    if [ -f "$files" ]; then
      # gera ordem reversa portável
      rev=$(awk '{a[NR]=$0} END{for(i=NR;i>=1;i--)print a[i]}' "$files")
      # primeiro remove arquivos
      printf "%s\n" "$rev" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
          "/"|"") continue ;;
        esac
        owner=$(owners_get "$f" 2>/dev/null || true)
        if [ "$owner" = "$pkgid" ]; then
          rm -f -- "$f" 2>/dev/null || true
          owners_remove_if_owner "$f" "$pkgid"
        fi
      done

      # depois tenta remover diretórios vazios ascendentes (conservador)
      printf "%s\n" "$rev" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        d=$(dirname -- "$f")
        # suba removendo vazios, mas pare em /
        while [ "$d" != "/" ] && [ -n "$d" ]; do
          rmdir -- "$d" 2>/dev/null || break
          d=$(dirname -- "$d")
        done
      done
    fi

    # Atualiza revdeps usando deps.list instalado (não depende da receita atual)
    if [ -f "$depslist" ]; then
      while IFS= read -r depid; do
        [ -n "$depid" ] || continue
        db_track_revdep_remove "$pkgid" "$depid"
      done <"$depslist"
    fi

    safe_rm_rf "$idir"

    run_remove_hook "$pkgid" hook_post_remove

    log "INFO" "Removido: $pkgid"
  done
}

# -------------------------
# Comandos utilitários
# -------------------------
cmd_install() {
  [ $# -ge 1 ] || die "Uso: install <pkg> [pkg...]"
  need_cmd tar xz sha256sum
  lock=$(acquire_lock "pm")
  trap 'release_lock "$lock"' EXIT INT TERM

  order=$(solve_deps "$@")
  printf "%s\n" "$order" | while IFS= read -r id; do
    pm_install_one "$id"
  done
  log "INFO" "Instalação finalizada."
}

cmd_search() {
  [ $# -eq 1 ] || die "Uso: search <termo>"
  q=$1
  find "$PKGS_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null \
    | while IFS= read -r d; do
        rel=${d#"$PKGS_DIR"/}   # cat/pkg
        if echo "$rel" | grep -qi "$q"; then
          echo "$rel"
          continue
        fi
        if [ -f "$d/meta" ] && grep -qi "$q" "$d/meta"; then
          echo "$rel"
        fi
      done | LC_ALL=C sort -u
}

cmd_info() {
  [ $# -eq 1 ] || die "Uso: info <pkg>"
  id=$(pkg_resolve "$1")
  meta_load "$id"

  echo "PKGID: $id"
  echo "CATEGORY: $(pkg_cat "$id")"
  echo "NAME: $PKGNAME"
  echo "VER: $PKGVER"
  echo "DEPS: ${DEPS:-}"
  echo "DESC: ${DESC:-}"

  if db_is_installed "$id"; then
    inst_meta="$(db_installed_dir "$id")/meta"
    echo "INSTALLED: yes"
    echo "INST_VER: $(db_get_kv "$inst_meta" PKGVER 2>/dev/null || true)"
    echo "RECIPE_HASH: $(db_get_kv "$inst_meta" RECIPE_HASH 2>/dev/null || true)"
    echo "DEP_SNAPSHOT_HASH: $(db_deps_snapshot_hash "$id" 2>/dev/null || true)"
  else
    echo "INSTALLED: no"
  fi
}

cmd_list() {
  find "$DB_DIR/installed" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | while IFS= read -r d; do
        id=$(basename -- "$d")
        v=$(db_get_kv "$d/meta" PKGVER 2>/dev/null || true)
        echo "$id $v"
      done | LC_ALL=C sort
}

cmd_upgrade() {
  lock=$(acquire_lock "pm")
  trap 'release_lock "$lock"' EXIT INT TERM

  find "$DB_DIR/installed" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | while IFS= read -r d; do basename -- "$d"; done \
    | LC_ALL=C sort \
    | while IFS= read -r id; do
        pm_install_one "$id"
      done
}

cmd_rebuild_all() {
  lock=$(acquire_lock "pm")
  trap 'release_lock "$lock"' EXIT INT TERM

  pkgs=$(find "$DB_DIR/installed" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | while IFS= read -r d; do basename -- "$d"; done)

  [ -n "${pkgs:-}" ] || die "Nenhum pacote instalado."

  order=$(solve_deps $pkgs)
  printf "%s\n" "$order" | while IFS= read -r id; do
    meta_load "$id" || true
    tb=$(cache_tarball_path "$id" "${PKGVER:-}")
    rm -f -- "$tb" "$tb.sha256" 2>/dev/null || true
    pm_install_one "$id"
  done
}

cmd_clean() {
  safe_rm_rf "$BUILD_ROOT"
  mkdir -p "$BUILD_ROOT"
  log "INFO" "Build root limpo: $BUILD_ROOT"
}

cmd_gc() {
  # remove revdeps vazios + compacta owners removendo entradas para arquivos inexistentes
  find "$DB_DIR/revdeps" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r d; do
    f="$d/list"
    [ -f "$f" ] || continue
    if ! [ -s "$f" ]; then
      safe_rm_rf "$d"
    fi
  done

  if [ -f "$OWNERS_FILE" ]; then
    awk -F '\t' 'NF==2 {print $0}' "$OWNERS_FILE" >"$OWNERS_FILE.tmp" || true
    mv -f "$OWNERS_FILE.tmp" "$OWNERS_FILE"
  fi

  log "INFO" "GC concluído."
}

cmd_sync() {
  command -v git >/dev/null 2>&1 || die "git não encontrado"
  (cd "$PM_ROOT" && git rev-parse --is-inside-work-tree >/dev/null 2>&1) || die "Este diretório não é um repo git."
  log "INFO" "Git pull ($PM_GIT_REMOTE)..."
  (cd "$PM_ROOT" && git pull "$PM_GIT_REMOTE" 2>&1) | tee -a "$LOG_DIR/git.log" >&2
  log "INFO" "Sync concluído."
}

cmd_push() {
  command -v git >/dev/null 2>&1 || die "git não encontrado"
  (cd "$PM_ROOT" && git rev-parse --is-inside-work-tree >/dev/null 2>&1) || die "Este diretório não é um repo git."
  log "INFO" "Git push ($PM_GIT_REMOTE)..."
  (cd "$PM_ROOT" && git push "$PM_GIT_REMOTE" 2>&1) | tee -a "$LOG_DIR/git.log" >&2
  log "INFO" "Push concluído."
}

cmd_help() {
  cat <<EOF
pm.sh - gerenciador de pacotes POSIX sh (pkgs/<categoria>/<pacote>)

Config:
  PM_PREFIX=/usr/local
  PM_JOBS=1
  PM_STRIP=1
  PM_GIT_REMOTE=origin
  PM_UPGRADE_REBUILD_ON_DEP_CHANGE=1
  PM_ASSUME_TAR_SAFE=0
  PM_LOCK_TIMEOUT=0

Comandos:
  help
  install <pkg|cat/pkg> [..]
  remove  <pkg|cat/pkg> [..]
  upgrade
  rebuild-all
  search <termo>
  info <pkg|cat/pkg>
  list
  clean
  gc
  sync
  push

Receita:
  pkgs/<cat>/<pkg>/meta:
    PKGNAME=<pkg>        (opcional; default = nome do diretório)
    PKGVER=<versão>      (obrigatório)
    DEPS="dep1 dep2 ..." (opcional; pode usar cat/pkg ou apenas pkg se único)
    DESC="..."           (opcional)

  pkgs/<cat>/<pkg>/build.sh deve definir:
    pkg_fetch
    pkg_unpack
    pkg_build
    pkg_install     (instala em DESTDIR; nunca em /)

Hooks opcionais na receita (build.sh):
  hook_pre_install
  hook_post_install
  hook_pre_remove
  hook_post_remove

Extras:
  pkgs/<cat>/<pkg>/files/  -> overlay copiado para DESTDIR
  pkgs/<cat>/<pkg>/patch/  -> patches aplicados automaticamente (patch -p1)
EOF
}

main() {
  cmd=${1:-help}; shift || true
  case "$cmd" in
    help) cmd_help ;;
    install) cmd_install "$@" ;;
    remove) cmd_remove "$@" ;;
    upgrade) cmd_upgrade ;;
    rebuild-all) cmd_rebuild_all ;;
    search) cmd_search "$@" ;;
    info) cmd_info "$@" ;;
    list) cmd_list ;;
    clean) cmd_clean ;;
    gc) cmd_gc ;;
    sync) cmd_sync ;;
    push) cmd_push ;;
    *) die "Comando desconhecido: $cmd (use: help)" ;;
  esac
}

main "$@"
