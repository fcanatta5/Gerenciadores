#!/bin/sh
# pm.sh - gerenciador de pacotes minimalista (POSIX sh), foco musl
#
# Layout de receitas: pkgs/<categoria>/<programa>/
#   meta, build.sh, files/, patch/
#
# Requisitos esperados (BusyBox OK):
#   sh, find, sort, awk, sed, tar, xz, sha256sum, mkdir, rm, mv, date
# Opcionais:
#   git (sync/push), patch (patch/), strip (PM_STRIP=1), wget/curl (nas receitas)

set -eu

PM_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKGS_DIR="$PM_ROOT/pkgs"
STATE_DIR="$PM_ROOT/state"
DB_DIR="$STATE_DIR/db"
CACHE_DIR="$STATE_DIR/cache"
LOG_DIR="$STATE_DIR/logs"
BUILD_ROOT="$STATE_DIR/build"
LOCK_DIR="$STATE_DIR/lock"

: "${PM_PREFIX:=/usr/local}"      # prefix alvo dentro de DESTDIR (receitas)
: "${PM_JOBS:=1}"
: "${PM_STRIP:=1}"
: "${PM_GIT_REMOTE:=origin}"
: "${PM_UPGRADE_REBUILD_ON_DEP_CHANGE:=1}"
: "${PM_ASSUME_TAR_SAFE:=0}"      # 0 = valida tarball antes de extrair em /
: "${PM_LOCK_TIMEOUT:=0}"

umask 022
mkdir -p "$PKGS_DIR" "$DB_DIR" "$CACHE_DIR" "$LOG_DIR" "$BUILD_ROOT" "$LOCK_DIR"

# -------------------------
# util
# -------------------------
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
    "/"|"/bin"|"/sbin"|"/usr"|"/etc"|"/var"|"/home"|"/root") die "safe_rm_rf: recusando apagar caminho crítico: $p" ;;
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
pkg_cat() { echo "$1" | awk -F/ '{print $1}'; }
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

# Hash determinístico do conteúdo da receita (inclui meta/build.sh/files/patch, sem maxdepth)
pkg_recipe_hash() {
  id=$1
  pdir=$(pkg_path "$id")
  [ -d "$pdir" ] || die "Pacote inexistente: $id"
  (
    cd "$pdir"
    find . -type f 2>/dev/null \
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

# enumerador correto de instalados (funciona com categoria/pacote)
installed_pkgids() {
  base="$DB_DIR/installed"
  [ -d "$base" ] || return 0
  find "$base" -type f -name meta 2>/dev/null \
    | LC_ALL=C sort \
    | while IFS= read -r mf; do
        id=$(db_get_kv "$mf" PKGID 2>/dev/null || true)
        if [ -n "$id" ]; then
          printf "%s\n" "$id"
        else
          # fallback: installed/<cat>/<pkg>/meta
          rel=${mf#"$base"/}
          catp=$(echo "$rel" | awk -F/ '{print $1"/"$2}')
          [ -n "$catp" ] && printf "%s\n" "$catp"
        fi
      done
}

# owners index: texto "path<TAB>pkgid"
OWNERS_FILE="$DB_DIR/owners.tsv"

owners_get() {
  path=$1
  [ -f "$OWNERS_FILE" ] || return 1
  awk -v P="$path" -F '\t' '$1==P{print $2; exit}' "$OWNERS_FILE"
}

owners_set() {
  path=$1 pkgid=$2
  mkdir -p "$(dirname -- "$OWNERS_FILE")"
  # remove entrada antiga e adiciona nova (último vence)
  if [ -f "$OWNERS_FILE" ]; then
    awk -v P="$path" -F '\t' '$1!=P{print}' "$OWNERS_FILE" >"$OWNERS_FILE.tmp" || true
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
  owners_set "$file" "$pkgid"
}

# deps snapshot
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

  depsfile="$idir/deps.list"
  : >"$depsfile"
  for d in $DEPS; do
    printf "%s\n" "$(pkg_resolve "$d")" >>"$depsfile"
  done

  # atualiza revdeps
  for depid in $(cat "$depsfile" 2>/dev/null || true); do
    db_track_revdep_add "$pkgid" "$depid"
  done

  db_write_deps_snapshot "$pkgid"
}

db_unmark_installed() {
  pkgid=$1
  idir=$(db_installed_dir "$pkgid")
  # remover relação revdeps baseada no deps.list salvo
  depsfile="$idir/deps.list"
  if [ -f "$depsfile" ]; then
    while IFS= read -r depid; do
      [ -n "$depid" ] || continue
      db_track_revdep_remove "$pkgid" "$depid"
    done <"$depsfile"
  fi
  safe_rm_rf "$idir"
}

# -------------------------
# Solver de dependências (DFS com detecção de ciclo)
# stdout: ordem topológica (pkgid por linha)
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
# tar/xz portável
# -------------------------
tar_list_xz() {
  tb=$1
  # tenta tar direto
  if tar -tf "$tb" >/dev/null 2>&1; then
    tar -tf "$tb"
    return 0
  fi
  # fallback: xz -dc | tar -tf -
  need_cmd xz
  xz -dc "$tb" | tar -tf -
}

tar_extract_xz_root() {
  tb=$1
  # tenta tar direto
  if tar -C / -xpf "$tb" >/dev/null 2>&1; then
    tar -C / -xpf "$tb"
    return 0
  fi
  need_cmd xz
  xz -dc "$tb" | tar -C / -xpf -
}

xz_best_compress() {
  # retorna flags adequadas para xz (sem depender de -T0/-e)
  # preferências: paralelismo se suportado; depois nível alto.
  if xz --help 2>/dev/null | grep -q -- "-T"; then
    # se suportar -e
    if xz --help 2>/dev/null | grep -q -- " -e"; then
      echo "-T0 -9e"
    else
      echo "-T0 -9"
    fi
  else
    if xz --help 2>/dev/null | grep -q -- " -e"; then
      echo "-9e"
    else
      echo "-9"
    fi
  fi
}

# -------------------------
# Build/Package/Install
# -------------------------
apply_patches() {
  pkgid=$1 srcdir=$2
  pdir="$(pkg_path "$pkgid")/patch"
  [ -d "$pdir" ] || return 0
  need_cmd patch
  find "$pdir" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r pf; do
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
# hook_pre_install/hook_post_install/hook_pre_remove/hook_post_remove
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

pkg_build_do() {
  pkgid=$1
  meta_load "$pkgid"
  pdir=$(pkg_path "$pkgid")
  bdir="$BUILD_ROOT/$pkgid"

  # sempre limpar antes de construir
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

pkg_pack_do() {
  pkgid=$1
  meta_load "$pkgid"
  bdir="$BUILD_ROOT/$pkgid"
  dest="$bdir/dest"
  [ -d "$dest" ] || die "DESTDIR não existe para $pkgid; rode build antes"
  out="$CACHE_DIR/$(pkg_cat "$pkgid")__$(pkg_name "$pkgid")-$PKGVER.tar.xz"
  log "INFO" "Empacotando: $out"

  flags=$(xz_best_compress)
  # shellcheck disable=SC2086
  (cd "$dest" && tar -c .) | xz $flags >"$out.tmp"
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
  tar_list_xz "$tb" | while IFS= read -r f; do
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
  tar_extract_xz_root "$tarball"

  # registra arquivos instalados e owners
  idir=$(db_installed_dir "$pkgid")
  mkdir -p "$idir"
  : >"$idir/files.list"
  tar_list_xz "$tarball" | while IFS= read -r f; do
    f=${f#./}
    [ -n "$f" ] || continue
    db_track_file "$pkgid" "/$f"
  done

  run_hook "$pkgid" hook_post_install
}

remove_empty_dirs_upward() {
  p=$1
  # remove diretórios vazios subindo até / (sem remover /)
  while :; do
    case "$p" in
      ""|"/") break ;;
    esac
    if [ -d "$p" ] && rmdir "$p" 2>/dev/null; then
      p=$(dirname -- "$p")
      continue
    fi
    break
  done
}

pm_remove_pkg() {
  pkgid=$(pkg_resolve "$1")
  db_is_installed "$pkgid" || { log "INFO" "Não instalado: $pkgid"; return 0; }

  # bloqueia se houver reverse deps instaladas
  revs=$(revdeps_list "$pkgid" | while IFS= read -r r; do
    [ -n "$r" ] || continue
    if db_is_installed "$r"; then printf "%s\n" "$r"; fi
  done || true)
  if [ -n "${revs:-}" ]; then
    die "Não é possível remover $pkgid; depende(m): $(printf "%s" "$revs" | tr '\n' ' ')"
  fi

  run_hook "$pkgid" hook_pre_remove

  idir=$(db_installed_dir "$pkgid")
  flist="$idir/files.list"
  [ -f "$flist" ] || die "DB corrompido: files.list ausente para $pkgid"

  log "INFO" "Removendo: $pkgid"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    owner=$(owners_get "$f" 2>/dev/null || true)
    if [ "$owner" = "$pkgid" ]; then
      rm -f -- "$f" 2>/dev/null || true
      owners_remove_if_owner "$f" "$pkgid"
      remove_empty_dirs_upward "$(dirname -- "$f")"
    fi
  done <"$flist"

  run_hook "$pkgid" hook_post_remove
  db_unmark_installed "$pkgid"
}

fileset_to_tmp_sorted() {
  infile=$1 out=$2
  [ -f "$infile" ] || { : >"$out"; return 0; }
  LC_ALL=C sort -u "$infile" >"$out"
}

diff_old_new_remove_obsolete() {
  pkgid=$1 oldlist=$2 newlist=$3
  tmpo="$BUILD_ROOT/.old.$$"
  tmpn="$BUILD_ROOT/.new.$$"
  fileset_to_tmp_sorted "$oldlist" "$tmpo"
  fileset_to_tmp_sorted "$newlist" "$tmpn"

  # arquivos no old que não estão no new
  # (comm -23 exige sort)
  if command -v comm >/dev/null 2>&1; then
    comm -23 "$tmpo" "$tmpn" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      owner=$(owners_get "$f" 2>/dev/null || true)
      if [ "$owner" = "$pkgid" ]; then
        rm -f -- "$f" 2>/dev/null || true
        owners_remove_if_owner "$f" "$pkgid"
        remove_empty_dirs_upward "$(dirname -- "$f")"
      fi
    done
  else
    # fallback sem comm
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if ! grep -qx -- "$f" "$tmpn" 2>/dev/null; then
        owner=$(owners_get "$f" 2>/dev/null || true)
        if [ "$owner" = "$pkgid" ]; then
          rm -f -- "$f" 2>/dev/null || true
          owners_remove_if_owner "$f" "$pkgid"
          remove_empty_dirs_upward "$(dirname -- "$f")"
        fi
      fi
    done <"$tmpo"
  fi

  rm -f "$tmpo" "$tmpn" 2>/dev/null || true
}

pm_install_one() {
  pkgid=$(pkg_resolve "$1")
  meta_load "$pkgid"

  idir=$(db_installed_dir "$pkgid")
  old_files="$BUILD_ROOT/.oldfiles.$$"
  new_files="$BUILD_ROOT/.newfiles.$$"
  : >"$old_files"; : >"$new_files"

  if db_is_installed "$pkgid"; then
    [ -f "$idir/files.list" ] && cp "$idir/files.list" "$old_files" 2>/dev/null || true
  fi

  # garante deps instaladas
  for dep in $DEPS; do
    depid=$(pkg_resolve "$dep")
    pm_install_one "$depid"
  done

  # decide usar cache ou rebuild
  need_rebuild=0
  if db_is_installed "$pkgid"; then
    old_ver=$(db_get_kv "$idir/meta" PKGVER 2>/dev/null || echo "")
    old_rhash=$(db_get_kv "$idir/meta" RECIPE_HASH 2>/dev/null || echo "")
    new_rhash=$(pkg_recipe_hash "$pkgid")
    if [ "$old_ver" != "$PKGVER" ] || [ "$old_rhash" != "$new_rhash" ]; then
      need_rebuild=1
    elif [ "$PM_UPGRADE_REBUILD_ON_DEP_CHANGE" = "1" ]; then
      old_dhash=$(db_deps_snapshot_hash "$pkgid" 2>/dev/null || echo "")
      db_write_deps_snapshot "$pkgid"
      new_dhash=$(db_deps_snapshot_hash "$pkgid" 2>/dev/null || echo "")
      if [ -n "$old_dhash" ] && [ -n "$new_dhash" ] && [ "$old_dhash" != "$new_dhash" ]; then
        need_rebuild=1
      fi
    fi
  else
    need_rebuild=1
  fi

  tb=$(cache_tarball_path "$pkgid" "$PKGVER")
  if [ "$need_rebuild" -eq 0 ] && cache_has_pkgver "$pkgid" "$PKGVER"; then
    log "INFO" "Usando cache: $pkgid-$PKGVER"
  else
    if cache_has_pkgver "$pkgid" "$PKGVER"; then
      # se cache existe, mas receita/dep mudou, podemos aceitar cache (se usuário desejar)
      # aqui escolhemos rebuild para consistência
      :
    fi
    pkg_build_do "$pkgid"
    pkg_pack_do "$pkgid" >/dev/null
  fi

  # instala tarball
  install_tarball "$pkgid" "$tb"

  # marca instalado (meta/deps/revdeps/snapshot)
  db_mark_installed "$pkgid"

  # coletar novo files.list e remover obsoletos (upgrade inteligente)
  [ -f "$idir/files.list" ] && cp "$idir/files.list" "$new_files" 2>/dev/null || true
  if [ -s "$old_files" ]; then
    diff_old_new_remove_obsolete "$pkgid" "$old_files" "$new_files"
  fi
  rm -f "$old_files" "$new_files" 2>/dev/null || true
}

# -------------------------
# Comandos
# -------------------------
cmd_install() {
  [ $# -ge 1 ] || die "Uso: install <pkg> [pkg...]"
  lock=$(acquire_lock pm)
  trap 'release_lock "$lock"' EXIT INT TERM

  # resolve deps e instala em ordem (topo)
  order=$(solve_deps "$@")
  # instala em ordem já topológica
  echo "$order" | while IFS= read -r id; do
    [ -n "$id" ] || continue
    pm_install_one "$id"
  done

  release_lock "$lock"
  trap - EXIT INT TERM
}

cmd_remove() {
  [ $# -ge 1 ] || die "Uso: remove <pkg> [pkg...]"
  lock=$(acquire_lock pm)
  trap 'release_lock "$lock"' EXIT INT TERM

  # remove na ordem inversa do que foi pedido (e das deps) para reduzir conflito
  # (melhor esforço)
  tmp="$BUILD_ROOT/.rm.$$"
  : >"$tmp"
  for q in "$@"; do
    solve_deps "$q" >>"$tmp"
  done
  LC_ALL=C sort -u "$tmp" | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--)print a[i]}' | while IFS= read -r id; do
    [ -n "$id" ] || continue
    pm_remove_pkg "$id"
  done
  rm -f "$tmp" 2>/dev/null || true

  release_lock "$lock"
  trap - EXIT INT TERM
}

cmd_list() {
  installed_pkgids | while IFS= read -r id; do
    [ -n "$id" ] || continue
    idir=$(db_installed_dir "$id")
    ver=$(db_get_kv "$idir/meta" PKGVER 2>/dev/null || echo "?")
    desc=$(db_get_kv "$idir/meta" DESC 2>/dev/null || echo "")
    printf "%-24s  %-10s  %s\n" "$id" "$ver" "$desc"
  done
}

cmd_info() {
  [ $# -ge 1 ] || die "Uso: info <pkg>"
  id=$(pkg_resolve "$1")
  meta_load "$id"
  printf "PKGID: %s\n" "$id"
  printf "PKGNAME: %s\n" "$PKGNAME"
  printf "PKGVER: %s\n" "$PKGVER"
  printf "DESC: %s\n" "$DESC"
  printf "DEPS: %s\n" "$DEPS"
  if db_is_installed "$id"; then
    idir=$(db_installed_dir "$id")
    printf "INSTALLED: yes\n"
    printf "INSTALLED_VER: %s\n" "$(db_get_kv "$idir/meta" PKGVER 2>/dev/null || echo "")"
    printf "INSTALLED_AT: %s\n" "$(db_get_kv "$idir/meta" INSTALLED_AT 2>/dev/null || echo "")"
  else
    printf "INSTALLED: no\n"
  fi
}

cmd_search() {
  [ $# -ge 1 ] || die "Uso: search <termo>"
  term=$1
  find "$PKGS_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null \
    | while IFS= read -r d; do
        id=${d#"$PKGS_DIR"/}
        # busca no id e no meta
        if echo "$id" | grep -qi -- "$term"; then
          printf "%s\n" "$id"
        else
          if [ -f "$d/meta" ] && grep -qi -- "$term" "$d/meta" 2>/dev/null; then
            printf "%s\n" "$id"
          fi
        fi
      done \
    | LC_ALL=C sort -u
}

cmd_clean() {
  log "INFO" "Limpando build/ temporário"
  safe_rm_rf "$BUILD_ROOT"
  mkdir -p "$BUILD_ROOT"
  log "INFO" "OK"
}

cmd_gc() {
  lock=$(acquire_lock pm)
  trap 'release_lock "$lock"' EXIT INT TERM

  log "INFO" "GC: reconstruindo owners.tsv"
  : >"$OWNERS_FILE"

  installed_pkgids | while IFS= read -r id; do
    [ -n "$id" ] || continue
    flist="$(db_installed_dir "$id")/files.list"
    [ -f "$flist" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      owners_set "$f" "$id"
    done <"$flist"
  done

  log "INFO" "GC: concluído"
  release_lock "$lock"
  trap - EXIT INT TERM
}

cmd_upgrade() {
  lock=$(acquire_lock pm)
  trap 'release_lock "$lock"' EXIT INT TERM

  installed_pkgids | while IFS= read -r id; do
    [ -n "$id" ] || continue
    # instala “um” (ele decide rebuild/cache)
    pm_install_one "$id"
  done

  release_lock "$lock"
  trap - EXIT INT TERM
}

cmd_rebuild_all() {
  lock=$(acquire_lock pm)
  trap 'release_lock "$lock"' EXIT INT TERM

  # rebuild-all: força rebuild apagando cache do pkgver atual (melhor esforço)
  installed_pkgids | while IFS= read -r id; do
    [ -n "$id" ] || continue
    if db_is_installed "$id"; then
      idir=$(db_installed_dir "$id")
      ver=$(db_get_kv "$idir/meta" PKGVER 2>/dev/null || echo "")
      if [ -n "$ver" ]; then
        rm -f "$(cache_tarball_path "$id" "$ver")" "$(cache_tarball_path "$id" "$ver").sha256" 2>/dev/null || true
      fi
    fi
    pm_install_one "$id"
  done

  release_lock "$lock"
  trap - EXIT INT TERM
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
pm.sh - gerenciador de pacotes POSIX sh

Config:
  PM_PREFIX=/usr/local   prefixo padrão para receitas (instala em DESTDIR+PM_PREFIX)
  PM_JOBS=1              paralelismo sugerido às receitas
  PM_STRIP=1             tenta strip em binários do DESTDIR
  PM_GIT_REMOTE=origin   remote do git
  PM_ASSUME_TAR_SAFE=0   valida tarball antes de extrair em /
  PM_LOCK_TIMEOUT=0      0=sem timeout

Comandos:
  help
  install <pkg> [pkg...]
  remove <pkg> [pkg...]
  upgrade
  rebuild-all
  search <termo>
  info <pkg>
  list
  clean
  gc
  sync
  push

Convenções de receita:
  pkgs/<cat>/<pkg>/meta:
    PKGNAME=<pkg> (opcional)
    PKGVER=<versão> (obrigatório)
    DEPS="dep1 dep2 ..." (opcional)
    DESC="..." (opcional)

  pkgs/<cat>/<pkg>/build.sh deve definir:
    pkg_fetch   - baixa fontes para WORKDIR
    pkg_unpack  - prepara SRCDIR (fonte pronta para patch/build)
    pkg_build   - compila
    pkg_install - instala em DESTDIR (NUNCA instala direto em /)

Extras:
  pkgs/<cat>/<pkg>/files/ -> overlay copiado para DESTDIR
  pkgs/<cat>/<pkg>/patch/ -> patches aplicados automaticamente (patch -p1)
Hooks opcionais na receita:
  hook_pre_install / hook_post_install / hook_pre_remove / hook_post_remove
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
