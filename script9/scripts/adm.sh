#!/bin/sh
set -eu

ADM_VERSION="0.3"

PORTS_DIR="${PORTS_DIR:-/usr/local/ports}"

DB_DIR="${DB_DIR:-/var/db/adm}"
PKG_DB="${DB_DIR}/pkgs"
WORLD_FILE="${DB_DIR}/world"
OWNERS_DB="${DB_DIR}/owners"       # arquivo texto: "path<TAB>pkgref"
LOCK_DIR="${LOCK_DIR:-/run/adm.lock}"

CACHE_DIR="${CACHE_DIR:-/var/cache/adm}"
DISTFILES="${CACHE_DIR}/distfiles"
SRCCACHE="${CACHE_DIR}/src"
BUILDROOT="${CACHE_DIR}/build"
PKGROOT="${CACHE_DIR}/pkg"
PACKAGES="${CACHE_DIR}/packages"

LOG_DIR="${LOG_DIR:-/var/log/adm}"

REPO_URL="${REPO_URL:-}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"

umask 022

die(){ printf '%s\n' "adm: erro: $*" >&2; exit 1; }
msg(){ printf '%s\n' "adm: $*" >&2; }

need_root(){ [ "$(id -u)" -eq 0 ] || die "precisa ser root"; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

ensure_dirs() {
  mkdir -p "$PORTS_DIR" "$PKG_DB" "$CACHE_DIR" "$DISTFILES" "$SRCCACHE" "$BUILDROOT" "$PKGROOT" "$PACKAGES" "$LOG_DIR"
  mkdir -p "$DB_DIR"
  [ -f "$WORLD_FILE" ] || : >"$WORLD_FILE"
  [ -f "$OWNERS_DB" ] || : >"$OWNERS_DB"
}

lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
  else
    die "lock ativo ($LOCK_DIR). outro adm em execução?"
  fi
}

safe_rm_rf() {
  p="${1:-}"
  [ -n "$p" ] || die "safe_rm_rf: caminho vazio"
  case "$p" in
    "/"|"/bin"|"/sbin"|"/lib"|"/lib64"|"/usr"|"/usr/bin"|"/usr/lib"|"/etc"|"/var"|"/home")
      die "safe_rm_rf: recusando remover caminho crítico: $p"
      ;;
  esac
  rm -rf -- "$p"
}

# -------------------- Ports index / resolução --------------------

list_all_ports() {
  find "$PORTS_DIR" -mindepth 2 -maxdepth 2 -type f -name build.sh 2>/dev/null \
    | sed "s#^${PORTS_DIR}/##" \
    | sed "s#/build\.sh$##" \
    | sort
}

resolve_pkgref() {
  in="$1"
  case "$in" in
    */*)
      [ -f "${PORTS_DIR}/${in}/build.sh" ] || die "port não encontrado: $in"
      printf '%s\n' "$in"
      ;;
    *)
      matches="$(list_all_ports | awk -F/ -v p="$in" '$2==p {print $0}')"
      count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"
      [ "$count" -ge 1 ] || die "port não encontrado: $in"
      if [ "$count" -gt 1 ]; then
        msg "ambíguo: '$in' existe em múltiplas categorias:"
        printf '%s\n' "$matches" >&2
        die "use categoria/pacote"
      fi
      printf '%s\n' "$matches"
      ;;
  esac
}

# -------------------- Carregamento do port --------------------

reset_port_env() {
  unset name version release source_urls sources depends makedepends srcdir_name
  unset -f pre_fetch post_fetch pre_prepare prepare post_prepare pre_build build post_build \
          pre_package package post_package pre_install post_install pre_remove post_remove \
          pre_upgrade post_upgrade 2>/dev/null || true
}

load_port() {
  pkgref="$(resolve_pkgref "$1")"
  PORTDIR="${PORTS_DIR}/${pkgref}"
  [ -f "${PORTDIR}/build.sh" ] || die "build.sh ausente: ${pkgref}"

  reset_port_env
  # shellcheck source=/dev/null
  . "${PORTDIR}/build.sh"

  [ -n "${name:-}" ] || die "port ${pkgref}: variável 'name' não definida"
  [ -n "${version:-}" ] || die "port ${pkgref}: variável 'version' não definida"

  # compat
  if [ -n "${source_urls:-}" ]; then
    :
  elif [ -n "${sources:-}" ]; then
    source_urls="${sources}"
  else
    die "port ${pkgref}: defina 'source_urls' (ou 'sources' por compat)"
  fi

  : "${release:=1}"
  : "${depends:=}"
  : "${makedepends:=}"

  have_cmd prepare || die "port ${pkgref}: função prepare() obrigatória"
  have_cmd build   || die "port ${pkgref}: função build() obrigatória"
  have_cmd package || die "port ${pkgref}: função package() obrigatória"

  export PORTDIR
  export PATCHDIR="${PORTDIR}/patches"
  export FILESDIR="${PORTDIR}/files"

  printf '%s\n' "$pkgref"
}

port_vars() {
  PKGREF="$1"
  PKGNAME="$name"
  PKGVERSION="$version"
  PKGRELEASE="$release"

  WORKDIR="${BUILDROOT}/${PKGREF//\//_}-${PKGVERSION}"
  SRCDIR="${WORKDIR}/src"
  PKGDIR="${PKGROOT}/${PKGREF//\//_}-${PKGVERSION}"
  LOGFILE="${LOG_DIR}/${PKGREF//\//_}-${PKGVERSION}.log"

  # FIX CRÍTICO: atribuir antes de exportar
  DESTDIR="$PKGDIR"
  SRCDIR_NAME="${srcdir_name:-}"

  export JOBS WORKDIR SRCDIR PKGDIR DESTDIR LOGFILE SRCDIR_NAME
  export CFLAGS="${CFLAGS:--O2 -pipe}"
  export CXXFLAGS="${CXXFLAGS:--O2 -pipe}"
  export LDFLAGS="${LDFLAGS:-}"
  export CPPFLAGS="${CPPFLAGS:-}"
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
}

run_hook() {
  hook="$1"
  if have_cmd "$hook"; then
    msg "hook: $hook"
    "$hook"
  fi
}

# -------------------- Fetch / checksums --------------------

fetch_one() {
  url="$1"
  fname="$(basename "$url")"
  out="${DISTFILES}/${fname}"

  [ -f "$out" ] && return 0

  msg "baixando: $url"
  if have_cmd curl; then
    curl -L --fail --retry 3 -o "$out" "$url" || die "falha no download: $url"
  elif have_cmd wget; then
    wget -O "$out" "$url" || die "falha no download: $url"
  else
    die "precisa de curl ou wget"
  fi
}

verify_checksums() {
  [ -f "${PORTDIR}/checksums" ] || return 0
  ( cd "$DISTFILES" && sha256sum -c "${PORTDIR}/checksums" ) || die "checksum inválido"
}

cmd_checksum() {
  pkgref="$(load_port "$1")"
  port_vars "$pkgref"

  run_hook pre_fetch
  for url in $source_urls; do fetch_one "$url"; done

  tmp="$(mktemp)"
  for url in $source_urls; do
    f="$(basename "$url")"
    [ -f "${DISTFILES}/${f}" ] || die "distfile ausente: ${f}"
    sha256sum "${DISTFILES}/${f}" | awk '{print $1 "  " $2}' >>"$tmp"
  done
  mv -f "$tmp" "${PORTDIR}/checksums"
  run_hook post_fetch
  msg "checksums atualizados: ${pkgref}"
}

# -------------------- Source cache --------------------

extract_one() {
  file="$1"
  outdir="$2"

  case "$file" in
    *.tar.zst)
      have_cmd zstd || die "zstd necessário para extrair: $file"
      zstd -d -q -c "$file" | tar -xpf - -C "$outdir" || die "falha ao extrair: $file"
      ;;
    *.tar.xz)  tar -xJf "$file" -C "$outdir" ;;
    *.tar.gz|*.tgz) tar -xzf "$file" -C "$outdir" ;;
    *.tar.bz2) tar -xjf "$file" -C "$outdir" ;;
    *.zip)
      have_cmd unzip || die "unzip necessário para extrair: $file"
      unzip -q "$file" -d "$outdir"
      ;;
    *) die "formato desconhecido: $file" ;;
  esac
}

prepare_src_cache() {
  cache="${SRCCACHE}/${PKGREF//\//_}-${PKGVERSION}"
  [ -d "$cache" ] && return 0

  mkdir -p "$cache"
  for url in $source_urls; do
    f="$(basename "$url")"
    file="${DISTFILES}/${f}"
    [ -f "$file" ] || die "distfile ausente: $file"
    msg "extraindo p/ cache: $f"
    extract_one "$file" "$cache"
  done
}

populate_work_src_from_cache() {
  cache="${SRCCACHE}/${PKGREF//\//_}-${PKGVERSION}"
  [ -d "$cache" ] || die "src cache ausente: $cache"
  mkdir -p "$SRCDIR"
  if have_cmd rsync; then
    rsync -a --delete "$cache"/ "$SRCDIR"/
  else
    ( cd "$cache" && tar -cpf - . ) | ( cd "$SRCDIR" && tar -xpf - )
  fi
}

apply_default_patches() {
  [ -d "$PATCHDIR" ] || return 0
  have_cmd patch || die "precisa de 'patch' para aplicar patches"

  patches="$(find "$PATCHDIR" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) 2>/dev/null | sort || true)"
  [ -n "${patches:-}" ] || return 0

  for p in $patches; do
    msg "aplicando patch: $(basename "$p")"
    patch -Np1 < "$p" || die "falha ao aplicar patch: $p"
  done
}

# -------------------- Deps (DFS simples) --------------------

_seen=""
_stack=""

in_seen(){ echo " $_seen " | grep -q " $1 " 2>/dev/null; }
in_stack(){ echo " $_stack " | grep -q " $1 " 2>/dev/null; }

resolve_deps() {
  pkgref="$(resolve_pkgref "$1")"
  if in_seen "$pkgref"; then return 0; fi
  if in_stack "$pkgref"; then die "ciclo de dependências detectado: $pkgref"; fi

  _stack="$_stack $pkgref"
  load_port "$pkgref" >/dev/null

  deps="${makedepends} ${depends}"
  for d in $deps; do
    resolve_deps "$d"
  done

  _stack="$(echo "$_stack" | sed "s/ $pkgref//")"
  _seen="$_seen $pkgref"
}

# -------------------- DB helpers --------------------

pkg_db_dir(){ printf '%s\n' "${PKG_DB}/$1"; }
pkg_is_installed(){ [ -d "$(pkg_db_dir "$1")" ]; }
pkg_installed_version(){
  f="$(pkg_db_dir "$1")/version"
  [ -f "$f" ] && cat "$f" || true
}

world_add() {
  pkgref="$1"
  grep -qx "$pkgref" "$WORLD_FILE" 2>/dev/null || echo "$pkgref" >>"$WORLD_FILE"
}
world_remove() {
  pkgref="$1"
  [ -f "$WORLD_FILE" ] || return 0
  grep -vx "$pkgref" "$WORLD_FILE" > "${WORLD_FILE}.tmp" || true
  mv -f "${WORLD_FILE}.tmp" "$WORLD_FILE"
}

db_write_pkg() {
  pkgref="$1"
  ver="$2"
  files="$3"
  depsline="$4"

  dir="$(pkg_db_dir "$pkgref")"
  mkdir -p "$dir"
  printf '%s\n' "$ver" > "${dir}/version"
  printf '%s\n' "$depsline" > "${dir}/meta"
  cat "$files" > "${dir}/files"
}

# -------------------- Owners DB (anti-colisão) --------------------

owners_set() {
  pkgref="$1"
  filelist="$2"

  # Remove entradas antigas desse pkgref
  awk -F'\t' -v p="$pkgref" '$2!=p {print $0}' "$OWNERS_DB" > "${OWNERS_DB}.tmp" || true

  # Adiciona novas: apenas paths absolutos e não vazios
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      /*)
        # não registrar "/" em si
        [ "$path" = "/" ] && continue
        printf '%s\t%s\n' "$path" "$pkgref" >> "${OWNERS_DB}.tmp"
        ;;
    esac
  done < "$filelist"

  mv -f "${OWNERS_DB}.tmp" "$OWNERS_DB"
}

owners_owner_of() {
  path="$1"
  # retorna o último owner registrado (caso duplicado) — simples e suficiente
  awk -F'\t' -v x="$path" '$1==x {o=$2} END{if(o!="") print o}' "$OWNERS_DB" 2>/dev/null || true
}

owners_remove_pkg() {
  pkgref="$1"
  awk -F'\t' -v p="$pkgref" '$2!=p {print $0}' "$OWNERS_DB" > "${OWNERS_DB}.tmp" || true
  mv -f "${OWNERS_DB}.tmp" "$OWNERS_DB"
}

# -------------------- Empacotamento binário --------------------

pkg_archive_paths() {
  base="${PACKAGES}/${PKGREF//\//_}-${PKGVERSION}-${PKGRELEASE}"
  printf '%s\n' "${base}.tar.zst" "${base}.tar.xz"
}

make_package_archive() {
  [ -d "$PKGDIR" ] || die "staging ausente: rode adm build primeiro"
  zst="$(pkg_archive_paths | awk 'NR==1{print $0}')"
  xz="$(pkg_archive_paths | awk 'NR==2{print $0}')"

  mkdir -p "$PACKAGES"
  msg "empacotando: ${PKGREF}"

  if have_cmd zstd; then
    ( cd "$PKGDIR" && tar -cpf - . ) | zstd -T0 -19 -q -o "$zst" || die "falha ao gerar tar.zst"
    rm -f "$xz" 2>/dev/null || true
  else
    msg "zstd ausente, fallback tar.xz"
    ( cd "$PKGDIR" && tar -cJf "$xz" . ) || die "falha ao gerar tar.xz"
    rm -f "$zst" 2>/dev/null || true
  fi
}

find_best_package_archive() {
  zst="$(pkg_archive_paths | awk 'NR==1{print $0}')"
  xz="$(pkg_archive_paths | awk 'NR==2{print $0}')"
  [ -f "$zst" ] && { printf '%s\n' "$zst"; return 0; }
  [ -f "$xz" ] && { printf '%s\n' "$xz"; return 0; }
  printf '%s\n' ""
}

install_archive_to_root() {
  need_root
  archive="$1"
  [ -f "$archive" ] || die "arquivo de pacote não existe: $archive"

  msg "instalando pacote binário: $(basename "$archive")"
  case "$archive" in
    *.tar.zst)
      have_cmd zstd || die "zstd necessário para instalar tar.zst"
      zstd -d -q -c "$archive" | tar -xpf - -C / || die "falha ao extrair tar.zst"
      ;;
    *.tar.xz)
      tar -xJpf "$archive" -C / || die "falha ao extrair tar.xz"
      ;;
    *) die "formato desconhecido: $archive" ;;
  esac
}

# -------------------- Filelist / install / remove --------------------

pkg_filelist() {
  pkgdir="$1"
  out="$2"
  ( cd "$pkgdir" && find . -type f -o -type l -o -type d ) \
    | sed 's#^\.$##; s#^\./#/#' | sed '/^$/d' | sort > "$out"
}

do_fetch() {
  pkgref="$(load_port "$1")"
  port_vars "$pkgref"

  run_hook pre_fetch
  for url in $source_urls; do fetch_one "$url"; done
  verify_checksums
  run_hook post_fetch
}

do_build() {
  pkgref="$(load_port "$1")"
  port_vars "$pkgref"

  safe_rm_rf "$WORKDIR"
  safe_rm_rf "$PKGDIR"
  mkdir -p "$WORKDIR" "$SRCDIR" "$PKGDIR"
  : >"$LOGFILE"

  (
    exec >>"$LOGFILE" 2>&1

    run_hook pre_fetch
    for url in $source_urls; do fetch_one "$url"; done
    verify_checksums
    run_hook post_fetch

    prepare_src_cache
    populate_work_src_from_cache

    # entra no src principal
    if [ -n "${SRCDIR_NAME:-}" ] && [ -d "${SRCDIR}/${SRCDIR_NAME}" ]; then
      cd "${SRCDIR}/${SRCDIR_NAME}"
    else
      cd "$SRCDIR"
      set -- "$SRCDIR"/*
      if [ "$#" -eq 1 ] && [ -d "$1" ]; then cd "$1"; fi
    fi

    apply_default_patches

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

  make_package_archive
  msg "build ok: ${pkgref} (log: $LOGFILE)"
}

do_install_one() {
  need_root
  pkgref="$(load_port "$1")"
  port_vars "$pkgref"

  archive="$(find_best_package_archive)"
  if [ -z "$archive" ]; then
    msg "sem pacote binário em cache; construindo: ${pkgref}"
    do_build "$pkgref"
    archive="$(find_best_package_archive)"
    [ -n "$archive" ] || die "pacote binário não foi gerado"
  fi

  run_hook pre_install

  # garante staging para filelist (extraindo o pacote para PKGDIR se necessário)
  if [ ! -d "$PKGDIR" ] || [ -z "$(ls -A "$PKGDIR" 2>/dev/null || true)" ]; then
    safe_rm_rf "$PKGDIR"
    mkdir -p "$PKGDIR"
    case "$archive" in
      *.tar.zst) zstd -d -q -c "$archive" | tar -xpf - -C "$PKGDIR" ;;
      *.tar.xz)  tar -xJpf "$archive" -C "$PKGDIR" ;;
    esac
  fi

  filelist_tmp="$(mktemp)"
  pkg_filelist "$PKGDIR" "$filelist_tmp"

  install_archive_to_root "$archive"

  depsline="depends=$depends; makedepends=$makedepends"
  db_write_pkg "$pkgref" "${PKGVERSION}-${PKGRELEASE}" "$filelist_tmp" "$depsline"
  owners_set "$pkgref" "$filelist_tmp"
  world_add "$pkgref"

  rm -f "$filelist_tmp"

  run_hook post_install
  msg "instalado: ${pkgref}"
}

do_remove_one() {
  need_root
  pkgref="$(resolve_pkgref "$1")"
  pkg_is_installed "$pkgref" || die "não instalado: $pkgref"

  # hooks se port ainda existe
  if [ -f "${PORTS_DIR}/${pkgref}/build.sh" ]; then
    load_port "$pkgref" >/dev/null
    port_vars "$pkgref"
    run_hook pre_remove
  fi

  files="$(pkg_db_dir "$pkgref")/files"
  [ -f "$files" ] || die "db corrompido: sem lista de arquivos"

  msg "removendo: $pkgref (respeitando owners)"
  # remove apenas se ainda for owner
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in /*) : ;; *) continue ;; esac
    [ "$p" = "/" ] && continue

    owner="$(owners_owner_of "$p")"
    if [ -n "$owner" ] && [ "$owner" != "$pkgref" ]; then
      continue
    fi

    if [ -f "$p" ] || [ -L "$p" ]; then
      rm -f -- "$p" || true
    fi
  done < "$files"

  # tenta limpar diretórios vazios (ordem reversa sem tac)
  awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' "$files" 2>/dev/null | while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in /*) : ;; *) continue ;; esac
    if [ -d "$p" ]; then
      rmdir --ignore-fail-on-non-empty "$p" 2>/dev/null || true
    fi
  done

  owners_remove_pkg "$pkgref"
  safe_rm_rf "$(pkg_db_dir "$pkgref")"
  world_remove "$pkgref"

  if [ -f "${PORTS_DIR}/${pkgref}/build.sh" ]; then
    run_hook post_remove
  fi

  msg "removido: $pkgref"
}

# upgrade seguro: build OK -> remove antigo -> install novo
do_upgrade_one() {
  need_root
  pkgref="$(resolve_pkgref "$1")"
  installed_before=0
  pkg_is_installed "$pkgref" && installed_before=1

  # build sempre usa port atual
  load_port "$pkgref" >/dev/null
  port_vars "$pkgref"

  run_hook pre_upgrade || true
  do_build "$pkgref"      # se falhar, não remove nada
  run_hook post_upgrade || true

  if [ "$installed_before" -eq 1 ]; then
    do_remove_one "$pkgref"
  fi
  do_install_one "$pkgref"
}

# -------------------- Comandos --------------------

cmd_sync() {
  ensure_dirs
  if [ -d "$PORTS_DIR/.git" ]; then
    msg "atualizando ports: $PORTS_DIR"
    ( cd "$PORTS_DIR" && git pull --ff-only ) || die "falha no git pull"
  else
    [ -n "$REPO_URL" ] || die "PORTS_DIR não é git. Defina REPO_URL para clone automático."
    msg "clonando ports de $REPO_URL em $PORTS_DIR"
    git clone "$REPO_URL" "$PORTS_DIR" || die "falha no git clone"
  fi
}

cmd_list() { list_all_ports; }

cmd_search() {
  q="$1"
  list_all_ports | while IFS= read -r pkgref; do
    case "$pkgref" in
      *"$q"*)
        if pkg_is_installed "$pkgref"; then
          printf '%s\n' "$pkgref [ ✔️]"
        else
          printf '%s\n' "$pkgref"
        fi
        ;;
    esac
  done
}

cmd_info() {
  pkgref="$(resolve_pkgref "$1")"
  mark=""
  installed="no"
  if pkg_is_installed "$pkgref"; then
    installed="yes"
    mark="[ ✔️]"
  fi

  if [ -f "${PORTS_DIR}/${pkgref}/build.sh" ]; then
    load_port "$pkgref" >/dev/null
    echo "${pkgref} ${mark}"
    echo "  name=$name"
    echo "  version=$version"
    echo "  release=${release:-1}"
    echo "  depends=${depends:-}"
    echo "  makedepends=${makedepends:-}"
    echo "  installed=$installed $(pkg_installed_version "$pkgref")"
  else
    echo "${pkgref} ${mark}"
    echo "  installed=$installed $(pkg_installed_version "$pkgref")"
    echo "  obs: port não está mais presente em $PORTS_DIR"
  fi
}

cmd_build() {
  ensure_dirs
  lock
  _seen=""; _stack=""
  resolve_deps "$1"
  for p in $_seen; do do_build "$p"; done
}

cmd_install() {
  ensure_dirs
  lock
  _seen=""; _stack=""
  resolve_deps "$1"
  for p in $_seen; do
    if ! pkg_is_installed "$p"; then
      do_install_one "$p"
    fi
  done
}

cmd_remove() {
  ensure_dirs
  lock
  do_remove_one "$1"
}

cmd_upgrade() {
  ensure_dirs
  lock
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    do_upgrade_one "$p"
  done < "$WORLD_FILE"
}

cmd_rebuild_installed() {
  # reconstrói e “troca” em ordem topológica do world (deps primeiro)
  ensure_dirs
  lock
  _seen=""; _stack=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    resolve_deps "$p"
  done < "$WORLD_FILE"

  for p in $_seen; do
    pkg_is_installed "$p" && do_upgrade_one "$p"
  done
}

usage() {
  cat >&2 <<EOF
adm $ADM_VERSION
uso:
  adm sync
  adm list
  adm search <texto>
  adm info <pkg|cat/pkg>
  adm fetch <pkg|cat/pkg>
  adm checksum <pkg|cat/pkg>
  adm build <pkg|cat/pkg>
  adm install <pkg|cat/pkg>
  adm remove <pkg|cat/pkg>
  adm upgrade
  adm rebuild-installed
EOF
  exit 2
}

main() {
  [ "$#" -ge 1 ] || usage
  ensure_dirs
  cmd="$1"; shift
  case "$cmd" in
    sync)              cmd_sync ;;
    list)              cmd_list ;;
    search)            [ "$#" -eq 1 ] || usage; cmd_search "$1" ;;
    info)              [ "$#" -eq 1 ] || usage; cmd_info "$1" ;;
    fetch)             [ "$#" -eq 1 ] || usage; do_fetch "$1" ;;
    checksum)          [ "$#" -eq 1 ] || usage; cmd_checksum "$1" ;;
    build)             [ "$#" -eq 1 ] || usage; cmd_build "$1" ;;
    install)           [ "$#" -eq 1 ] || usage; cmd_install "$1" ;;
    remove)            [ "$#" -eq 1 ] || usage; cmd_remove "$1" ;;
    upgrade)           [ "$#" -eq 0 ] || usage; cmd_upgrade ;;
    rebuild-installed) [ "$#" -eq 0 ] || usage; cmd_rebuild_installed ;;
    *) usage ;;
  esac
}

main "$@"
