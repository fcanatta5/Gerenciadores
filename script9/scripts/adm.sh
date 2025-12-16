#!/bin/sh
set -eu

ADM_VERSION="0.1"

PORTS_DIR="${PORTS_DIR:-/usr/local/ports}"
DB_DIR="${DB_DIR:-/var/db/adm}"
PKG_DB="${DB_DIR}/pkgs"
WORLD_FILE="${DB_DIR}/world"
CACHE_DIR="${CACHE_DIR:-/var/cache/adm}"
DISTFILES="${CACHE_DIR}/distfiles"
BUILDROOT="${CACHE_DIR}/build"
PKGROOT="${CACHE_DIR}/pkg"
LOG_DIR="${LOG_DIR:-/var/log/adm}"
LOCK_FILE="${LOCK_FILE:-/run/adm.lock}"

JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"

umask 022

die() { echo "adm: erro: $*" >&2; exit 1; }
msg() { echo "adm: $*" >&2; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "precisa ser root"
}

ensure_dirs() {
  mkdir -p "$PORTS_DIR" "$PKG_DB" "$CACHE_DIR" "$DISTFILES" "$BUILDROOT" "$PKGROOT" "$LOG_DIR"
  mkdir -p "$DB_DIR"
  [ -f "$WORLD_FILE" ] || : >"$WORLD_FILE"
}

lock() {
  # lock simples por mkdir (atômico)
  if mkdir "$LOCK_FILE" 2>/dev/null; then
    trap 'rmdir "$LOCK_FILE" 2>/dev/null || true' EXIT INT TERM
  else
    die "lock ativo ($LOCK_FILE). outro adm em execução?"
  fi
}

# -------- utilidades seguras --------

is_nonempty() { [ -n "${1:-}" ]; }

safe_rm_rf() {
  p="${1:-}"
  is_nonempty "$p" || die "safe_rm_rf: caminho vazio"
  case "$p" in
    "/"|"/bin"|"/sbin"|"/lib"|"/lib64"|"/usr"|"/usr/bin"|"/usr/lib"|"/etc"|"/var"|"/home")
      die "safe_rm_rf: recusando remover caminho crítico: $p"
      ;;
  esac
  rm -rf -- "$p"
}

sha256_file() {
  # imprime "hash  filename"
  sha256sum "$1"
}

fetch_one() {
  url="$1"
  fname="$(basename "$url")"
  out="${DISTFILES}/${fname}"

  if [ -f "$out" ]; then
    msg "distfile já existe: $fname"
    return 0
  fi

  msg "baixando: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 3 -o "$out" "$url" || die "falha no download: $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url" || die "falha no download: $url"
  else
    die "precisa de curl ou wget para download"
  fi
}

verify_checksums() {
  portdir="$1"
  [ -f "${portdir}/checksums" ] || return 0
  ( cd "$DISTFILES" && sha256sum -c "${portdir}/checksums" ) || die "checksum inválido"
}

extract_distfiles() {
  workdir="$1"
  shift
  mkdir -p "$workdir"
  for url in "$@"; do
    fname="$(basename "$url")"
    file="${DISTFILES}/${fname}"
    [ -f "$file" ] || die "distfile ausente: $file"
    msg "extraindo: $fname"
    case "$file" in
      *.tar.gz|*.tgz)  tar -xzf "$file" -C "$workdir" ;;
      *.tar.xz)        tar -xJf "$file" -C "$workdir" ;;
      *.tar.zst)       tar --zstd -xf "$file" -C "$workdir" ;;
      *.tar.bz2)       tar -xjf "$file" -C "$workdir" ;;
      *.zip)           unzip -q "$file" -d "$workdir" ;;
      *) die "formato desconhecido para extração: $file" ;;
    esac
  done
}

# -------- carregamento do port --------

reset_port_env() {
  unset name version release sources depends makedepends srcdir_name
  # hooks opcionais e obrigatórios
  unset -f pre_fetch post_fetch pre_prepare prepare post_prepare pre_build build post_build \
          pre_package package post_package pre_install post_install pre_remove post_remove \
          pre_upgrade post_upgrade 2>/dev/null || true
}

load_port() {
  pkg="$1"
  portdir="${PORTS_DIR}/${pkg}"
  [ -d "$portdir" ] || die "port não encontrado: $pkg"
  [ -f "${portdir}/build.sh" ] || die "build.sh ausente: $pkg"

  reset_port_env
  # shellcheck source=/dev/null
  . "${portdir}/build.sh"

  is_nonempty "${name:-}" || die "port $pkg: variável 'name' não definida"
  is_nonempty "${version:-}" || die "port $pkg: variável 'version' não definida"
  is_nonempty "${sources:-}" || die "port $pkg: variável 'sources' não definida"

  : "${release:=1}"
  : "${depends:=}"
  : "${makedepends:=}"

  command -v prepare >/dev/null 2>&1 || die "port $pkg: função prepare() obrigatória"
  command -v build   >/dev/null 2>&1 || die "port $pkg: função build() obrigatória"
  command -v package >/dev/null 2>&1 || die "port $pkg: função package() obrigatória"
}

port_vars() {
  pkg="$1"
  PKGNAME="$name"
  PKGVERSION="$version"
  PKGRELEASE="$release"
  PORTDIR="${PORTS_DIR}/${pkg}"
  WORKDIR="${BUILDROOT}/${PKGNAME}-${PKGVERSION}"
  PKGDIR="${PKGROOT}/${PKGNAME}-${PKGVERSION}"
  SRCDIR="${WORKDIR}/src"
  LOGFILE="${LOG_DIR}/${PKGNAME}-${PKGVERSION}.log"

  export JOBS WORKDIR SRCDIR PKGDIR DESTDIR
  DESTDIR="$PKGDIR"

  # Flags padrão: razoáveis e ajustáveis
  export CFLAGS="${CFLAGS:--O2 -pipe}"
  export CXXFLAGS="${CXXFLAGS:--O2 -pipe}"
  export LDFLAGS="${LDFLAGS:-}"

  # Sanitiza PATH (não deve depender de /usr/local do host fora do seu sistema)
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
}

run_hook() {
  hook="$1"
  if command -v "$hook" >/dev/null 2>&1; then
    msg "hook: $hook"
    "$hook"
  fi
}

# -------- dependências: DFS simples (sem SAT) --------

_seen=""
_stack=""

in_list() { echo " $_seen " | grep -q " $1 " 2>/dev/null; }
in_stack() { echo " $_stack " | grep -q " $1 " 2>/dev/null; }

resolve_deps() {
  pkg="$1"
  if in_list "$pkg"; then return 0; fi
  if in_stack "$pkg"; then die "ciclo de dependências detectado envolvendo: $pkg"; fi

  _stack="$_stack $pkg"
  load_port "$pkg"

  # runtime + build-time (para build)
  deps="${makedepends} ${depends}"
  for d in $deps; do
    resolve_deps "$d"
  done

  _stack="$(echo "$_stack" | sed "s/ $pkg//")"
  _seen="$_seen $pkg"
}

# -------- banco --------

pkg_is_installed() {
  pkg="$1"
  [ -d "${PKG_DB}/${pkg}" ]
}

pkg_installed_version() {
  pkg="$1"
  [ -f "${PKG_DB}/${pkg}/version" ] && cat "${PKG_DB}/${pkg}/version" || true
}

db_write_pkg() {
  pkg="$1"
  ver="$2"
  files="$3"
  deps="$4"

  dir="${PKG_DB}/${pkg}"
  mkdir -p "$dir"

  printf "%s\n" "$ver" > "${dir}/version"
  printf "%s\n" "$deps" > "${dir}/meta"
  cat "$files" > "${dir}/files"
}

world_add() {
  pkg="$1"
  grep -qx "$pkg" "$WORLD_FILE" 2>/dev/null || echo "$pkg" >>"$WORLD_FILE"
}

world_remove() {
  pkg="$1"
  [ -f "$WORLD_FILE" ] || return 0
  grep -vx "$pkg" "$WORLD_FILE" > "${WORLD_FILE}.tmp" || true
  mv -f "${WORLD_FILE}.tmp" "$WORLD_FILE"
}

# -------- build / package / install --------

do_fetch() {
  pkg="$1"
  load_port "$pkg"
  port_vars "$pkg"

  run_hook pre_fetch

  # fetch distfiles
  # shellcheck disable=SC2086
  for url in $sources; do
    fetch_one "$url"
  done

  verify_checksums "$PORTDIR"
  run_hook post_fetch
}

do_build() {
  pkg="$1"
  load_port "$pkg"
  port_vars "$pkg"

  mkdir -p "$WORKDIR" "$SRCDIR" "$PKGDIR"
  safe_rm_rf "$WORKDIR"
  safe_rm_rf "$PKGDIR"
  mkdir -p "$WORKDIR" "$SRCDIR" "$PKGDIR"

  : >"$LOGFILE"

  (
    exec >>"$LOGFILE" 2>&1

    run_hook pre_fetch
    for url in $sources; do fetch_one "$url"; done
    verify_checksums "$PORTDIR"
    run_hook post_fetch

    extract_distfiles "$SRCDIR" $sources

    # entra no srcdir correto
    if [ -n "${srcdir_name:-}" ] && [ -d "${SRCDIR}/${srcdir_name}" ]; then
      cd "${SRCDIR}/${srcdir_name}"
    else
      # heurística: se houver exatamente 1 dir extraído, entra nele
      set -- "$SRCDIR"/*
      if [ "$#" -eq 1 ] && [ -d "$1" ]; then
        cd "$1"
      else
        cd "$SRCDIR"
      fi
    fi

    run_hook pre_prepare
    prepare
    run_hook post_prepare

    run_hook pre_build
    build
    run_hook post_build

    run_hook pre_package
    package
    run_hook post_package

  ) || die "build falhou (veja $LOGFILE)"

  msg "build ok: $pkg ($LOGFILE)"
}

# Gera lista de arquivos a partir do PKGDIR com caminhos absolutos reais
pkg_filelist() {
  pkgdir="$1"
  out="$2"
  ( cd "$pkgdir" && find . -type f -o -type l -o -type d ) \
    | sed 's#^\.$##; s#^\./#/#' \
    | sed '/^$/d' \
    | sort > "$out"
}

# Instala do PKGDIR para / e registra tudo o que foi instalado.
# OBS: sem fakeroot; exige root e cuida de permissões preservando atributos.
do_install() {
  need_root
  pkg="$1"

  load_port "$pkg"
  port_vars "$pkg"

  [ -d "$PKGDIR" ] || die "não existe staging para $pkg. rode: adm build $pkg"

  run_hook pre_install

  filelist_tmp="$(mktemp)"
  pkg_filelist "$PKGDIR" "$filelist_tmp"

  # Copia para / preservando atributos; cria diretórios necessários.
  # Diretórios devem existir antes; então copiamos árvore.
  msg "instalando em /: $pkg"
  ( cd "$PKGDIR" && tar -cpf - . ) | ( cd / && tar -xpf - ) || die "falha ao instalar arquivos"

  # Registra no DB
  deps_line="depends=$depends; makedepends=$makedepends"
  db_write_pkg "$pkg" "${PKGVERSION}-${PKGRELEASE}" "$filelist_tmp" "$deps_line"
  world_add "$pkg"

  rm -f "$filelist_tmp"

  run_hook post_install
  msg "instalado: $pkg"
}

do_remove() {
  need_root
  pkg="$1"

  pkg_is_installed "$pkg" || die "não instalado: $pkg"

  load_port "$pkg"
  port_vars "$pkg"

  run_hook pre_remove

  files="${PKG_DB}/${pkg}/files"
  [ -f "$files" ] || die "db corrompido: sem lista de arquivos"

  msg "removendo: $pkg"
  # Remove arquivos e links; diretórios serão limpos depois se vazios.
  # Só remove paths sob / (a lista é absoluta).
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      /*) : ;;
      *) continue ;;
    esac
    # não remove diretórios aqui (limpeza depois)
    if [ -f "$p" ] || [ -L "$p" ]; then
      rm -f -- "$p" || true
    fi
  done < "$files"

  # Remove diretórios vazios (ordem reversa)
  tac "$files" 2>/dev/null | while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -d "$p" ]; then
      rmdir --ignore-fail-on-non-empty "$p" 2>/dev/null || true
    fi
  done

  safe_rm_rf "${PKG_DB:?}/${pkg}"
  world_remove "$pkg"

  run_hook post_remove
  msg "removido: $pkg"
}

do_upgrade() {
  need_root
  pkg="$1"

  run_hook pre_upgrade || true
  do_build "$pkg"
  if pkg_is_installed "$pkg"; then
    do_remove "$pkg"
  fi
  do_install "$pkg"
  run_hook post_upgrade || true
}

# -------- sync (Git) --------

do_sync() {
  ensure_dirs
  if [ -d "$PORTS_DIR/.git" ]; then
    msg "atualizando ports: $PORTS_DIR"
    ( cd "$PORTS_DIR" && git pull --ff-only ) || die "falha no git pull"
  else
    die "PORTS_DIR não é um repositório git. clone seus ports em $PORTS_DIR"
  fi
}

# -------- comandos --------

cmd_list() {
  ls -1 "$PORTS_DIR" 2>/dev/null || true
}

cmd_info() {
  pkg="$1"
  load_port "$pkg"
  echo "name=$name"
  echo "version=$version"
  echo "release=${release:-1}"
  echo "depends=${depends:-}"
  echo "makedepends=${makedepends:-}"
  echo "sources=$(echo "$sources" | tr '\n' ' ')"
  if pkg_is_installed "$pkg"; then
    echo "installed=$(pkg_installed_version "$pkg")"
  else
    echo "installed=no"
  fi
}

cmd_build() {
  pkg="$1"
  ensure_dirs
  lock
  resolve_deps "$pkg"
  for p in $_seen; do
    do_build "$p"
  done
}

cmd_install() {
  pkg="$1"
  ensure_dirs
  lock
  resolve_deps "$pkg"
  for p in $_seen; do
    # instala deps primeiro se não estiverem instaladas
    if ! pkg_is_installed "$p"; then
      do_install "$p"
    fi
  done
}

cmd_remove() {
  pkg="$1"
  ensure_dirs
  lock
  do_remove "$pkg"
}

cmd_upgrade() {
  ensure_dirs
  lock
  # upgrade do "world" (o que o usuário pediu explicitamente)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    do_upgrade "$p"
  done < "$WORLD_FILE"
}

usage() {
  cat >&2 <<EOF
adm $ADM_VERSION
uso:
  adm sync
  adm list
  adm info <pkg>
  adm fetch <pkg>
  adm build <pkg>
  adm install <pkg>
  adm remove <pkg>
  adm upgrade
EOF
  exit 2
}

main() {
  [ "$#" -ge 1 ] || usage
  ensure_dirs

  cmd="$1"; shift
  case "$cmd" in
    sync)    do_sync ;;
    list)    cmd_list ;;
    info)    [ "$#" -eq 1 ] || usage; cmd_info "$1" ;;
    fetch)   [ "$#" -eq 1 ] || usage; do_fetch "$1" ;;
    build)   [ "$#" -eq 1 ] || usage; cmd_build "$1" ;;
    install) [ "$#" -eq 1 ] || usage; cmd_install "$1" ;;
    remove)  [ "$#" -eq 1 ] || usage; cmd_remove "$1" ;;
    upgrade) [ "$#" -eq 0 ] || usage; cmd_upgrade ;;
    *) usage ;;
  esac
}

main "$@"
