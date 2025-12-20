#!/bin/sh
# pm.sh - gerenciador de pacotes minimalista (POSIX sh), foco musl
#
# Layout de receitas: pkgs/<categoria>/<programa>/
#   meta, build.sh, files/, patch/
#
# Requisitos esperados (BusyBox OK):
#   sh, find, sort, awk, sed, tar, xz, sha256sum, mkdir, rm, mv, date, tee
# Opcionais conforme uso:
#   git (sync/push), patch (patch/), strip (PM_STRIP=1), wget/curl (nas receitas)

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
  # tee pode não existir em busybox ultra-minimal; se faltar, cai em stderr apenas.
  if command -v tee >/dev/null 2>&1; then
    printf "%s [%s] %s\n" "$ts" "$lvl" "$*" | tee -a "$LOG_DIR/pm.log" >&2
  else
    printf "%s [%s] %s\n" "$ts" "$lvl" "$*" >&2
    printf "%s [%s] %s\n" "$ts" "$lvl" "$*" >>"$LOG_DIR/pm.log" 2>/dev/null || true
  fi
}

die() { log "ERROR" "$*"; exit 1; }

need_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Comando requerido não encontrado: $c"
  done
}

# Remoção segura: apenas dentro do STATE_DIR.
safe_rm_rf() {
  p=$1
  [ -n "$p" ] || die "safe_rm_rf: path vazio"

  # normaliza para path absoluto
  case "$p" in
    /*) ap="$p" ;;
    *) ap="$PWD/$p" ;;
  esac

  # protege contra remoção fora do state
  case "$ap" in
    "$STATE_DIR"|"${STATE_DIR}/"*) ;;
    *) die "safe_rm_rf: recusando apagar fora do STATE_DIR: $ap" ;;
  esac

  # não remover o próprio STATE_DIR raiz (evita apagar DB/cache por engano)
  [ "$ap" != "$STATE_DIR" ] || die "safe_rm_rf: recusando apagar STATE_DIR raiz"

  rm -rf -- "$ap"
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
  [ -n "${lock:-}" ] || return 0
  rmdir "$lock" 2>/dev/null || true
}

# -------------------------
# Resolução de receita: ID = "categoria/pacote"
# Permite chamar por "pacote" se for único.
# -------------------------
pkg_resolve() {
  q=$1
  case "$q" in
    */*)
      [ -d "$PKGS_DIR/$q" ] || die "Receita não encontrada: $q"
      printf "%s\n" "$q"
      return 0
      ;;
  esac

  found=""
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

pkg_path() { printf "%s/%s\n" "$PKGS_DIR" "$1"; }
pkg_cat()  { echo "$1" | awk -F/ '{print $1}'; }
pkg_name() { echo "$1" | awk -F/ '{print $2}'; }

# -------------------------
# Meta
# -------------------------
meta_load() {
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

# Hash determinístico da receita (inclui meta/build.sh/files/patch)
# Implementação sem '\0' (mais portável).
pkg_recipe_hash() {
  id=$1
  pdir=$(pkg_path "$id")
  [ -d "$pdir" ] || die "Pacote inexistente: $id"
  (
    cd "$pdir"
    # lista determinística e hasheia conteúdo + caminho
    # formato: "<sha256>  <path>"
    find . -maxdepth 4 -type f 2>/dev/null \
      | LC_ALL=C sort \
      | while IFS= read -r f; do
          [ -f "$f" ] || continue
          h=$(sha256sum "$f" | awk '{print $1}')
          printf "%s  %s\n" "$h" "$f"
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

# Política corrigida: "último instalador vence"
owners_set_force() {
  path=$1 pkgid=$2
  mkdir -p "$(dirname -- "$OWNERS_FILE")"
  if [ -f "$OWNERS_FILE" ]; then
    awk -v P="$path" -F '\t' '$1!=P' "$OWNERS_FILE" >"$OWNERS_FILE.tmp" || true
    mv -f "$OWNERS_FILE.tmp" "$OWNERS_FILE"
  fi
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
  owners_set_force "$file" "$pkgid"
}

# deps snapshot: installed/<id>/deps.snapshot (+ hash)
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

  # registra DEPS do momento (para uninstall correto mesmo se receita mudar)
  depsfile="$idir/deps.list"
  : >"$depsfile"
  for d in $DEPS; do
    printf "%s\n" "$(pkg_resolve "$d")" >>"$depsfile"
  done

  for depid in $(cat "$depsfile" 2>/dev/null || true); do
    db_track_revdep_add "$pkgid" "$depid"
  done

  db_write_deps_snapshot "$pkgid"

  # finaliza pendência
  rm -f -- "$idir/PENDING" 2>/dev/null || true
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
  find "$pdir" -maxdepth 1 -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r pf; do
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

# Hooks opcionais na receita (host):
#   hook_pre_install, hook_post_install
run_hook() {
  pkgid=$1 hookname=$2
  pdir=$(pkg_path "$pkgid")
  [ -f "$pdir/build.sh" ] || return 0
  (
    meta_load "$pkgid"
    export PM_ROOT PM_PREFIX PM_JOBS PKGNAME PKGVER
    # shellcheck disable=SC1090
    . "$pdir/build.sh"
    command -v "$hookname" >/dev/null 2>&1 || exit 0
    "$hookname"
  ) >>"$LOG_DIR/hooks.$(pkg_cat "$pkgid").$(pkg_name "$pkgid").log" 2>&1 || die "Hook $hookname falhou para $pkgid"
}

pkg_build() {
  pkgid=$1
  meta_load "$pkgid"
  pdir=$(pkg_path "$pkgid")
  bdir="$BUILD_ROOT/$pkgid"

  # sempre limpar antes de construir
  if [ -d "$bdir" ]; then
    safe_rm_rf "$bdir"
  fi
  mkdir -p "$bdir"

  logf="$LOG_DIR/build.$(pkg_cat "$pkgid").$(pkg_name "$pkgid").log"
  : >"$logf"

  WORKDIR="$bdir/work"
  SRCDIR="$bdir/src"
  DESTDIR="$bdir/dest"
  mkdir -p "$WORKDIR" "$SRCDIR" "$DESTDIR"

  export PM_ROOT PM_PREFIX PM_JOBS WORKDIR SRCDIR DESTDIR PKGNAME PKGVER

  [ -f "$pdir/build.sh" ] || die "build.sh não encontrado para $pkgid"

  log "INFO" "Build iniciado: $pkgid-$PKGVER"

  # Executa em subshell para não poluir ambiente global e para preservar erros do source
  (
    # shellcheck disable=SC1090
    . "$pdir/build.sh"

    command -v pkg_fetch   >/dev/null 2>&1 || die "$pkgid: build.sh deve definir função pkg_fetch"
    command -v pkg_unpack  >/dev/null 2>&1 || die "$pkgid: build.sh deve definir função pkg_unpack"
    command -v pkg_build   >/dev/null 2>&1 || die "$pkgid: build.sh deve definir função pkg_build"
    command -v pkg_install >/dev/null 2>&1 || die "$pkgid: build.sh deve definir função pkg_install"

    pkg_fetch
    pkg_unpack
    apply_patches "$pkgid" "$SRCDIR"
    pkg_build
    pkg_install
    copy_files_overlay "$pkgid" "$DESTDIR"
    strip_binaries_in_destdir "$DESTDIR"
  ) >>"$logf" 2>&1 || die "Falha no build de $pkgid. Veja: $logf"

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
  tar -tf "$tb" \
    | awk '
        function bad() { exit 2 }
        {
          f=$0
          sub(/^\.\//, "", f)
          if (f == "") next
          if (substr(f,1,1) == "/") bad()
          if (f ~ /(^|\/)\.\.(\/|$)/) bad()
        }
        END { exit 0 }
      '
}

install_tarball() {
  pkgid=$1 tarball=$2
  cache_verify "$tarball"

  if [ "$PM_ASSUME_TAR_SAFE" != "1" ]; then
    tarball_is_safe "$tarball" || die "Tarball potencialmente inseguro (path traversal): $tarball"
  fi

  run_hook "$pkgid" hook_pre_install

  idir=$(db_installed_dir "$pkgid")
  mkdir -p "$idir"
  : >"$idir/files.list"
  : >"$idir/PENDING"

  log "INFO" "Instalando: $pkgid a partir de $tarball (extraindo em /)"
  tar -C / -xJpf "$tarball"

  # registra arquivos instalados + owners (último instalador vence)
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
      if [ "$PM_UPGRADE_REBUILD_ON_DEP_CHANGE" = "1" ]; then
        old_snap=$(db_deps_snapshot_hash "$pkgid" 2>/dev/null || echo "")
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

  if cache_has_pkgver "$pkgid" "$PKGVER"; then
    tb=$(cache_tarball_path "$pkgid" "$PKGVER")
    install_tarball "$pkgid" "$tb"
  else
    pkg_build "$pkgid"
    tb=$(pkg_pack "$pkgid")
    install_tarball "$pkgid" "$tb"
  fi

  db_mark_installed "$pkgid"
}

# -------------------------
# Uninstall (corrigido)
# - remove somente arquivos cujo owner==pkgid
# - agora owners reflete "último instalador vence", então colisões são tratadas corretamente
# Hooks opcionais: hook_pre_remove, hook_post_remove
# -------------------------
run_remove_hook() {
  pkgid=$1 hookname=$2
  pdir=$(pkg_path "$pkgid")
  [ -f "$pdir/build.sh" ] || return 0
  (
    meta_load "$pkgid" || true
    export PM_ROOT PM_PREFIX PM_JOBS PKGNAME PKGVER
    # shellcheck disable=SC1090
    . "$pdir/build.sh" || true
    command -v "$hookname" >/dev/null 2>&1 || exit 0
    "$hookname"
  ) >>"$LOG_DIR/hooks.remove.$(pkg_cat "$pkgid").$(pkg_name "$pkgid").log" 2>&1 || die "Hook $hookname falhou para $pkgid"
}

cmd_remove() {
  [ $# -ge 1 ] || die "Uso: remove <pkg> [pkg...]"
  lock=$(acquire_lock "pm")
  trap 'release_lock "$lock"' EXIT INT TERM

  for q in "$@"; do
    pkgid=$(pkg_resolve "$q")
    db_is_installed "$pkgid" || die "$pkgid não está instalado."

    r=$(revdeps_list "$pkgid" 2>/dev/null || true)
    if [ -n "${r:-}" ]; then
      die "Não é possível remover $pkgid: requerido por:\n$r"
    fi

    idir=$(db_installed_dir "$pkgid")
    files="$idir/files.list"
    depslist="$idir/deps.list"

    run_remove_hook "$pkgid" hook_pre_remove

    if [ -f "$files" ]; then
      rev=$(awk '{a[NR]=$0} END{for(i=NR;i>=1;i--)print a[i]}' "$files")

      # remove arquivos
      printf "%s\n" "$rev" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in "/"|"") continue ;; esac
        owner=$(owners_get "$f" 2>/dev/null || true)
        if [ "$owner" = "$pkgid" ]; then
          rm -f -- "$f" 2>/dev/null || true
          owners_remove_if_owner "$f" "$pkgid"
        fi
      done

      # remove dirs vazios ascendentes (conservador)
      printf "%s\n" "$rev" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        d=$(dirname -- "$f")
        while [ "$d" != "/" ] && [ -n "$d" ]; do
          rmdir -- "$d" 2>/dev/null || break
          d=$(dirname -- "$d")
        done
      done
    fi

    # atualiza revdeps usando deps.list instalado
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
        rel=${d#"$PKGS_DIR"/}
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
    if [ -f "$(db_installed_dir "$id")/PENDING" ]; then
      echo "STATE: PENDING (instalação anterior pode ter falhado)"
    fi
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
  if [ -d "$BUILD_ROOT" ]; then
    safe_rm_rf "$BUILD_ROOT"
  fi
  mkdir -p "$BUILD_ROOT"
  log "INFO" "Build root limpo: $BUILD_ROOT"
}

cmd_gc() {
  # remove revdeps vazios
  find "$DB_DIR/revdeps" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r d; do
    f="$d/list"
    [ -f "$f" ] || continue
    if ! [ -s "$f" ]; then
      safe_rm_rf "$d"
    fi
  done

  # Reconstrói owners.tsv a partir das listas de arquivos instalados (fonte da verdade).
  tmp="$BUILD_ROOT/.gc.$$"
  mkdir -p "$tmp"
  newowners="$tmp/owners.tsv"
  : >"$newowners"

  if [ -d "$DB_DIR/installed" ]; then
    find "$DB_DIR/installed" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r idir; do
      pkgid=$(basename -- "$idir")
      fl="$idir/files.list"
      [ -f "$fl" ] || continue
      # para cada arquivo, último instalador vence (aqui, "installed state" já reflete isso)
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        printf "%s\t%s\n" "$p" "$pkgid" >>"$newowners"
      done <"$fl"
    done
  fi

  # Dedup: se um arquivo aparecer múltiplas vezes, mantém a última ocorrência (compatível com "último vence")
  # Implementação simples: percorre do fim para o começo e mantém primeiro visto (portável com awk).
  if [ -s "$newowners" ]; then
    awk -F '\t' '
      { a[NR]=$0; k[NR]=$1 }
      END{
        for(i=NR;i>=1;i--){
          if(!(k[i] in seen)){
            seen[k[i]]=1
            out[++n]=a[i]
          }
        }
        for(i=n;i>=1;i--) print out[i]
      }' "$newowners" >"$newowners.dedup" || true
    mv -f "$newowners.dedup" "$newowners"
  fi

  mkdir -p "$(dirname -- "$OWNERS_FILE")"
  mv -f "$newowners" "$OWNERS_FILE"
  safe_rm_rf "$tmp"

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
    DEPS="dep1 dep2 ..." (opcional; cat/pkg ou apenas pkg se único)
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
