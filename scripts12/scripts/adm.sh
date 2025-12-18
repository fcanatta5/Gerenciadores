#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ADM - Rolling release source-based manager (Shell Script)
# Layout:
#   /var/lib/adm/packages/<categoria>/<programa>/{build,patch,files}
#
# Package build script (mandatory):
#   .../build/build.sh
###############################################################################

# =========================
# CONFIG (TOPO)
# =========================
ADM_ROOT="/var/lib/adm"
PKGROOT="$ADM_ROOT/packages"
CACHEDL="$ADM_ROOT/cache/sources"
CACHEPKG="$ADM_ROOT/cache/packages"
LOGROOT="$ADM_ROOT/logs"
DBROOT="$ADM_ROOT/db"
LOCKFILE="$ADM_ROOT/adm.lock"

# Chroot build environment
CHROOT_ROOT="$ADM_ROOT/chroot"
CHROOT_MOUNTS=( "dev" "dev/pts" "proc" "sys" "run" )
CHROOT_SHELL="/bin/bash"

# Tools / compression
ZSTD_LEVEL="${ZSTD_LEVEL:-19}"
XZ_LEVEL="${XZ_LEVEL:--9e}"

# Download settings
ARIA2C="${ARIA2C:-aria2c}"
ARIA2C_JOBS="${ARIA2C_JOBS:-8}"
ARIA2C_SPLIT="${ARIA2C_SPLIT:-8}"
ARIA2C_CONN="${ARIA2C_CONN:-16}"

# UI
USE_COLOR=1
CHECK_MARK="✔️"
CROSS_MARK="✖"
DRYRUN=0
QUIET=0

# Notify
NOTIFY_BIN="${NOTIFY_BIN:-notify-send}"

# Git sync
GIT_REMOTE="${GIT_REMOTE:-}"     # opcional: ex. https://seu.repo/adm-packages.git
GIT_BRANCH="${GIT_BRANCH:-main}"

# =========================
# UI / LOG
# =========================
if [[ -t 1 && "$USE_COLOR" -eq 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[1;31m'
  C_GRN=$'\033[1;32m'
  C_YLW=$'\033[1;33m'
  C_BLU=$'\033[1;34m'
  C_CYN=$'\033[1;36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GRN="" C_YLW="" C_BLU="" C_CYN=""
fi

ts() { date -Is; }

say()  { [[ "$QUIET" -eq 1 ]] || printf "%s\n" "$*"; }
info() { say "${C_CYN}${C_BOLD}==>${C_RESET} $*"; }
ok()   { say "${C_GRN}${C_BOLD}OK${C_RESET}  $*"; }
warn() { say "${C_YLW}${C_BOLD}WARN${C_RESET} $*"; }
err()  { say "${C_RED}${C_BOLD}ERRO${C_RESET} $*"; }
die()  { err "$*"; exit 1; }

run() {
  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} $*"
    return 0
  fi
  eval "$@"
}

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Execute como root."; }

mkdirs() {
  run "mkdir -p '$PKGROOT' '$CACHEDL' '$CACHEPKG' '$LOGROOT' '$DBROOT' '$CHROOT_ROOT'"
}

with_lock() {
  mkdir -p "$(dirname "$LOCKFILE")"
  exec 9>"$LOCKFILE"
  flock -n 9 || die "Outra operação do ADM já está em execução (lock: $LOCKFILE)."
  "$@"
}

# =========================
# PACKAGE HELPERS
# =========================
pkg_path_from_spec() {
  # spec: categoria/programa
  local spec="$1"
  [[ "$spec" == */* ]] || die "Especifique como categoria/programa. Ex: base/busybox"
  echo "$PKGROOT/$spec"
}

pkg_build_script() {
  local spec="$1"
  echo "$(pkg_path_from_spec "$spec")/build/build.sh"
}

pkg_db_dir() {
  local spec="$1"
  echo "$DBROOT/${spec//\//__}"
}

is_installed() {
  local spec="$1"
  [[ -f "$(pkg_db_dir "$spec")/installed" ]]
}

installed_mark() {
  local spec="$1"
  if is_installed "$spec"; then
    printf "< %s >" "$CHECK_MARK"
  else
    printf "<   >"
  fi
}

# =========================
# DEPENDENCY GRAPH
# =========================
# Build scripts must provide:
#   PKG_NAME, PKG_VERSION, PKG_RELEASE, PKG_DESC, PKG_LICENSE, PKG_URL
#   PKG_SOURCES (array of URLs)
#   PKG_SUMS (array of "sha256:<hex>" or "md5:<hex>" or "skip")
#   PKG_DEPS (array of "categoria/programa")
#   PKG_BUILD_DEPS (array) optional
# And functions:
#   pre_build/post_build/pre_install/post_install/pre_uninstall/post_uninstall optional
#   build() mandatory
#   install() mandatory (instalar em $DESTDIR)
#   upstream_check() optional (echo "version url" or empty)
#
declare -A SEEN
declare -a ORDER

reset_graph() { SEEN=(); ORDER=(); }

load_pkg_meta() {
  local spec="$1"
  local bs
  bs="$(pkg_build_script "$spec")"
  [[ -r "$bs" ]] || die "build.sh não encontrado: $bs"

  # shellcheck disable=SC1090
  source "$bs"

  : "${PKG_NAME:?PKG_NAME não definido em $bs}"
  : "${PKG_VERSION:?PKG_VERSION não definido em $bs}"
  : "${PKG_RELEASE:?PKG_RELEASE não definido em $bs}"
  : "${PKG_SOURCES:?PKG_SOURCES não definido (array) em $bs}"
  : "${PKG_SUMS:?PKG_SUMS não definido (array) em $bs}"
  : "${PKG_DESC:?PKG_DESC não definido em $bs}"

  # normaliza arrays opcionais
  PKG_DEPS=("${PKG_DEPS[@]:-}")
  PKG_BUILD_DEPS=("${PKG_BUILD_DEPS[@]:-}")
}

dfs() {
  local spec="$1"
  [[ -n "${SEEN[$spec]:-}" ]] && return 0
  SEEN["$spec"]=1

  load_pkg_meta "$spec"

  local dep
  for dep in "${PKG_DEPS[@]}" "${PKG_BUILD_DEPS[@]}"; do
    [[ -z "$dep" ]] && continue
    dfs "$dep"
  done

  ORDER+=( "$spec" )
}

resolve_deps_order() {
  reset_graph
  dfs "$1"
  printf "%s\n" "${ORDER[@]}"
}

# =========================
# DOWNLOAD & CHECKSUM
# =========================
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_download_tool() {
  have_cmd "$ARIA2C" || die "Requer aria2c para download com progresso. Instale aria2 (aria2c)."
}

cache_filename_from_url() {
  local url="$1"
  # remove querystring para nome estável
  local base="${url%%\?*}"
  echo "${base##*/}"
}

checksum_ok() {
  local file="$1"
  local sumspec="$2"

  [[ "$sumspec" == "skip" ]] && return 0

  if [[ "$sumspec" == sha256:* ]]; then
    local want="${sumspec#sha256:}"
    local got
    got="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$got" == "$want" ]]
    return
  fi

  if [[ "$sumspec" == md5:* ]]; then
    local want="${sumspec#md5:}"
    local got
    got="$(md5sum "$file" | awk '{print $1}')"
    [[ "$got" == "$want" ]]
    return
  fi

  # compatibilidade: se for hex puro, tenta sha256 primeiro, depois md5
  if [[ "$sumspec" =~ ^[a-fA-F0-9]{64}$ ]]; then
    local got
    got="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$got" == "$sumspec" ]]
    return
  fi
  if [[ "$sumspec" =~ ^[a-fA-F0-9]{32}$ ]]; then
    local got
    got="$(md5sum "$file" | awk '{print $1}')"
    [[ "$got" == "$sumspec" ]]
    return
  fi

  die "Formato de checksum inválido: $sumspec"
}

download_sources_parallel() {
  local spec="$1"
  local skip_verify="$2"   # 1/0
  local skip_if_cached="$3"

  load_pkg_meta "$spec"

  require_download_tool

  local pkgcache="$CACHEDL/${spec//\//__}"
  run "mkdir -p '$pkgcache'"

  local -a urls=("${PKG_SOURCES[@]}")
  local -a sums=("${PKG_SUMS[@]}")

  [[ "${#urls[@]}" -eq "${#sums[@]}" ]] || die "PKG_SOURCES e PKG_SUMS devem ter o mesmo tamanho em $spec"

  # prepara lista para aria2c
  local listfile
  listfile="$(mktemp)"
  trap 'rm -f "$listfile"' RETURN

  local i url sum name dest
  for i in "${!urls[@]}"; do
    url="${urls[$i]}"
    sum="${sums[$i]}"
    name="$(cache_filename_from_url "$url")"
    dest="$pkgcache/$name"

    if [[ "$skip_if_cached" -eq 1 && -f "$dest" ]]; then
      if [[ "$skip_verify" -eq 1 || "$sum" == "skip" || checksum_ok "$dest" "$sum" ]]; then
        ok "Source em cache: $name"
        continue
      else
        warn "Checksum falhou para $name (cache). Removendo e baixando novamente."
        run "rm -f '$dest'"
      fi
    fi

    # aria2c input format:
    # URL
    #  out=filename
    #  dir=/path
    {
      echo "$url"
      echo "  out=$name"
      echo "  dir=$pkgcache"
    } >> "$listfile"
  done

  if [[ -s "$listfile" ]]; then
    info "Baixando sources em paralelo (aria2c) para $spec"
    # --console-log-level=warn mantém output utilizável, com barra de progresso
    run "'$ARIA2C' --allow-overwrite=true --auto-file-renaming=false \
      --max-concurrent-downloads=$ARIA2C_JOBS --split=$ARIA2C_SPLIT --max-connection-per-server=$ARIA2C_CONN \
      --file-allocation=none --summary-interval=1 --console-log-level=warn \
      --input-file='$listfile'"
  else
    ok "Nada para baixar (tudo em cache)."
  fi

  if [[ "$skip_verify" -eq 1 ]]; then
    warn "Checksum SKIP habilitado: não verificando sources."
    return 0
  fi

  info "Verificando checksums"
  for i in "${!urls[@]}"; do
    url="${urls[$i]}"
    sum="${sums[$i]}"
    name="$(cache_filename_from_url "$url")"
    dest="$pkgcache/$name"

    [[ -f "$dest" ]] || die "Source ausente após download: $dest"

    if [[ "$sum" == "skip" ]]; then
      warn "Checksum skip para $name"
      continue
    fi

    if checksum_ok "$dest" "$sum"; then
      ok "Checksum OK: $name"
    else
      warn "Checksum FALHOU: $name. Rebaixando."
      run "rm -f '$dest'"
      # rebaixa individualmente
      local onefile
      onefile="$(mktemp)"
      echo "$url" > "$onefile"
      echo "  out=$name" >> "$onefile"
      echo "  dir=$pkgcache" >> "$onefile"
      run "'$ARIA2C' --allow-overwrite=true --auto-file-renaming=false \
        --split=$ARIA2C_SPLIT --max-connection-per-server=$ARIA2C_CONN \
        --file-allocation=none --summary-interval=1 --console-log-level=warn \
        --input-file='$onefile'"
      rm -f "$onefile"
      checksum_ok "$dest" "$sum" || die "Checksum continua falhando após redownload: $name"
      ok "Checksum OK após redownload: $name"
    fi
  done
}

# =========================
# CHROOT (BUILD)
# =========================
chroot_setup() {
  need_root
  mkdirs

  run "mkdir -p '$CHROOT_ROOT' '$CHROOT_ROOT/{dev,proc,sys,run,tmp,root}'"
  run "chmod 1777 '$CHROOT_ROOT/tmp' || true"

  # DNS
  run "mkdir -p '$CHROOT_ROOT/etc'"
  if [[ -r /etc/resolv.conf ]]; then
    run "cp -L /etc/resolv.conf '$CHROOT_ROOT/etc/resolv.conf'"
  fi

  # mounts
  if ! mounted "$CHROOT_ROOT/dev"; then run "mount --bind /dev '$CHROOT_ROOT/dev'"; fi
  if ! mounted "$CHROOT_ROOT/dev/pts"; then run "mount -t devpts devpts '$CHROOT_ROOT/dev/pts' -o gid=5,mode=620"; fi
  if ! mounted "$CHROOT_ROOT/proc"; then run "mount -t proc proc '$CHROOT_ROOT/proc'"; fi
  if ! mounted "$CHROOT_ROOT/sys";  then run "mount -t sysfs sysfs '$CHROOT_ROOT/sys'"; fi
  if ! mounted "$CHROOT_ROOT/run";  then run "mount --bind /run '$CHROOT_ROOT/run'"; fi

  # bind do root real (para acessar os scripts/build) e cache
  run "mkdir -p '$CHROOT_ROOT/adm' '$CHROOT_ROOT/cache' '$CHROOT_ROOT/out'"
  if ! mounted "$CHROOT_ROOT/adm"; then run "mount --bind '$ADM_ROOT' '$CHROOT_ROOT/adm'"; fi
  if ! mounted "$CHROOT_ROOT/cache"; then run "mount --bind '$ADM_ROOT/cache' '$CHROOT_ROOT/cache'"; fi
  if ! mounted "$CHROOT_ROOT/out"; then run "mount --bind '$ADM_ROOT/cache/packages' '$CHROOT_ROOT/out'"; fi

  # Tools (se você usa toolchain temporário em /mnt/adm/tools, ajuste)
  # Aqui suportamos /adm/tools -> /tools no chroot, caso exista.
  if [[ -d "/mnt/adm/tools" ]]; then
    run "mkdir -p '$CHROOT_ROOT/tools'"
    if ! mounted "$CHROOT_ROOT/tools"; then run "mount --bind '/mnt/adm/tools' '$CHROOT_ROOT/tools'"; fi
  fi

  # garante /bin/sh dentro do chroot (mínimo) – exige que você populou CHROOT_ROOT com base system.
  # Para ambientes iniciais, você pode bindar /bin e /lib do host, MAS isso reduz isolamento.
  if [[ ! -x "$CHROOT_ROOT/bin/sh" && ! -x "$CHROOT_ROOT/bin/bash" ]]; then
    warn "Chroot ainda não tem /bin/sh. Recomenda-se ter um base system no chroot. (Sem isso, build em chroot falhará.)"
  fi
}

chroot_teardown() {
  need_root
  # desmonta em ordem reversa
  local p
  for p in "$CHROOT_ROOT/tools" "$CHROOT_ROOT/out" "$CHROOT_ROOT/cache" "$CHROOT_ROOT/adm"; do
    if mounted "$p"; then run "umount '$p' || umount -l '$p'"; fi
  done

  local i
  for (( i=${#CHROOT_MOUNTS[@]}-1; i>=0; i-- )); do
    p="$CHROOT_ROOT/${CHROOT_MOUNTS[$i]}"
    if mounted "$p"; then run "umount '$p' || umount -l '$p'"; fi
  done
}

chroot_exec() {
  local cmd="$1"
  local -a envs=(
    "HOME=/root"
    "TERM=${TERM:-xterm-256color}"
    "PATH=/usr/bin:/usr/sbin:/bin:/sbin:/tools/bin"
    "LANG=C"
    "LC_ALL=C"
  )
  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} chroot '$CHROOT_ROOT' env -i ... $cmd"
    return 0
  fi
  chroot "$CHROOT_ROOT" /usr/bin/env -i "${envs[@]}" /bin/sh -lc "$cmd"
}

# =========================
# BUILD / INSTALL / PACKAGE
# =========================
pkg_log_dir() {
  local spec="$1"
  echo "$LOGROOT/${spec//\//__}"
}

pkg_work_dir() {
  local spec="$1"
  echo "$ADM_ROOT/work/${spec//\//__}"
}

pkg_pkgfile_name() {
  # nome padronizado: categoria__programa-version-release.tar.(zst|xz)
  local spec="$1" name ver rel
  load_pkg_meta "$spec"
  name="${spec//\//__}"
  ver="$PKG_VERSION"
  rel="$PKG_RELEASE"
  echo "${name}-${ver}-${rel}"
}

apply_patches() {
  local spec="$1" srcdir="$2"
  local pdir
  pdir="$(pkg_path_from_spec "$spec")/patch"
  [[ -d "$pdir" ]] || return 0

  shopt -s nullglob
  local patch
  for patch in "$pdir"/*.patch "$pdir"/*.diff; do
    info "Aplicando patch: $(basename "$patch")"
    run "patch -d '$srcdir' -p1 < '$patch'"
  done
  shopt -u nullglob
}

copy_files_overlay() {
  # Copia files/ para DESTDIR antes do empacotamento (config, dirs, etc.)
  local spec="$1" destdir="$2"
  local fdir
  fdir="$(pkg_path_from_spec "$spec")/files"
  [[ -d "$fdir" ]] || return 0
  info "Aplicando overlay files/ em DESTDIR"
  run "cp -a '$fdir'/.' '$destdir'/'"
}

make_pkg_tarball() {
  local spec="$1" destdir="$2"
  local outbase outdir
  outbase="$(pkg_pkgfile_name "$spec")"
  outdir="$CACHEPKG"

  run "mkdir -p '$outdir'"

  if have_cmd zstd; then
    local pkgfile="$outdir/${outbase}.tar.zst"
    info "Empacotando (tar.zst) -> $(basename "$pkgfile")"
    if [[ "$DRYRUN" -eq 1 ]]; then
      say "${C_BLU}(dry-run)${C_RESET} tar ... | zstd -$ZSTD_LEVEL"
    else
      tar -C "$destdir" -cf - . | zstd -T0 "-$ZSTD_LEVEL" -o "$pkgfile"
    fi
    echo "$pkgfile"
    return 0
  fi

  # fallback tar.xz
  local pkgfile="$outdir/${outbase}.tar.xz"
  info "Empacotando (tar.xz fallback) -> $(basename "$pkgfile")"
  run "tar -C '$destdir' -cJf '$pkgfile' ."
  echo "$pkgfile"
}

record_install_db() {
  local spec="$1" destdir="$2"
  local dbd
  dbd="$(pkg_db_dir "$spec")"
  run "mkdir -p '$dbd'"

  # lista de arquivos
  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} registrando DB para $spec"
    return 0
  fi

  ( cd "$destdir" && find . -type f -o -type l -o -type d | sed 's|^\./|/|' | sort ) > "$dbd/files"
  printf "%s\n" "$(ts)" > "$dbd/installed"
  printf "%s\n" "$spec" > "$dbd/spec"
  printf "%s\n" "$PKG_NAME" > "$dbd/name"
  printf "%s\n" "$PKG_VERSION" > "$dbd/version"
  printf "%s\n" "$PKG_RELEASE" > "$dbd/release"
  printf "%s\n" "$PKG_DESC" > "$dbd/desc"
}

install_pkg_tarball_to_root() {
  local pkgfile="$1"
  info "Instalando pacote no sistema: $(basename "$pkgfile")"
  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} extrair $pkgfile em /"
    return 0
  fi
  # assume rootfs real é /
  if [[ "$pkgfile" == *.tar.zst ]]; then
    zstd -dc "$pkgfile" | tar -xpf - -C /
  else
    tar -xpf "$pkgfile" -C /
  fi
}

uninstall_spec() {
  local spec="$1"
  local dbd
  dbd="$(pkg_db_dir "$spec")"
  [[ -f "$dbd/files" ]] || die "Programa não instalado (sem DB): $spec"

  local bs
  bs="$(pkg_build_script "$spec")"
  # shellcheck disable=SC1090
  source "$bs"

  # hook real
  if declare -F pre_uninstall >/dev/null; then
    info "Hook pre_uninstall: $spec"
    if [[ "$DRYRUN" -eq 1 ]]; then say "${C_BLU}(dry-run)${C_RESET} pre_uninstall"; else pre_uninstall; fi
  fi

  info "Removendo arquivos de $spec"
  # remove arquivos (ordem: files e symlinks, depois tenta dirs vazios)
  if [[ "$DRYRUN" -eq 1 ]]; then
    say "${C_BLU}(dry-run)${C_RESET} remover arquivos listados em $dbd/files"
  else
    # remove arquivos e links primeiro
    grep -E '^/' "$dbd/files" | while read -r p; do
      [[ "$p" == "/" ]] && continue
      if [[ -L "$p" || -f "$p" ]]; then rm -f -- "$p" || true; fi
    done
    # remove dirs vazios em ordem reversa (mais profundo primeiro)
    grep -E '^/' "$dbd/files" | awk 'BEGIN{FS="/"} {print length($0),$0}' | sort -nr | cut -d' ' -f2- \
      | while read -r p; do
          if [[ -d "$p" ]]; then rmdir --ignore-fail-on-non-empty "$p" 2>/dev/null || true; fi
        done
  fi

  if declare -F post_uninstall >/dev/null; then
    info "Hook post_uninstall: $spec"
    if [[ "$DRYRUN" -eq 1 ]]; then say "${C_BLU}(dry-run)${C_RESET} post_uninstall"; else post_uninstall; fi
  fi

  run "rm -rf '$dbd'"
  ok "Uninstall concluído: $spec"
}

build_one() {
  local spec="$1"
  local skip_verify="$2"
  local skip_if_cached="$3"

  mkdirs
  export PKGROOT CACHEDL CACHEPKG LOGROOT DBROOT ADM_ROOT

  local bs
  bs="$(pkg_build_script "$spec")"
  [[ -r "$bs" ]] || die "build.sh não encontrado: $bs"

  load_pkg_meta "$spec"

  local logd workd pkgcache srcdir destdir
  logd="$(pkg_log_dir "$spec")"
  workd="$(pkg_work_dir "$spec")"
  pkgcache="$CACHEDL/${spec//\//__}"

  run "mkdir -p '$logd' '$workd' '$pkgcache'"

  local op_log="$logd/$(date +%Y%m%d-%H%M%S).log"
  info "Logs: $op_log"

  # Redirect de logs (com tee)
  if [[ "$DRYRUN" -eq 0 ]]; then
    exec > >(tee -a "$op_log") 2>&1
  fi

  info "Iniciando build: $spec ($PKG_VERSION-$PKG_RELEASE)"

  download_sources_parallel "$spec" "$skip_verify" "$skip_if_cached"

  # prepara diretórios de build
  srcdir="$workd/src"
  destdir="$workd/dest"
  run "rm -rf '$srcdir' '$destdir'"
  run "mkdir -p '$srcdir' '$destdir'"

  # extrai sources (com heurística simples: tar.* / zip / git)
  # Para casos complexos, o próprio build() pode lidar.
  info "Preparando fontes no workdir"
  if [[ "$DRYRUN" -eq 0 ]]; then
    # extrai apenas arquivos compactados comuns; outros ficam para build()
    shopt -s nullglob
    for f in "$pkgcache"/*; do
      case "$f" in
        *.tar.gz|*.tgz) tar -xzf "$f" -C "$srcdir" ;;
        *.tar.xz)       tar -xJf "$f" -C "$srcdir" ;;
        *.tar.zst)      zstd -dc "$f" | tar -xf - -C "$srcdir" ;;
        *.tar.bz2)      tar -xjf "$f" -C "$srcdir" ;;
        *.zip)          unzip -q "$f" -d "$srcdir" ;;
        *)              : ;;
      esac
    done
    shopt -u nullglob
  fi

  # aplica patches (no primeiro diretório dentro de srcdir, se existir)
  local top
  top="$(find "$srcdir" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
  if [[ -n "${top:-}" ]]; then
    apply_patches "$spec" "$top"
  else
    warn "Nenhum diretório extraído automaticamente; patches podem ser aplicados pelo build()."
  fi

  # executa build + install em CHROOT (seguro)
  chroot_setup

  # cria um runner dentro do chroot para build() e install()
  local ch_cmd
  ch_cmd=$(
    cat <<EOF
set -euo pipefail
spec='$spec'
bs="/adm/packages/${spec}/build/build.sh"
work="/adm/work/${spec//\//__}"
src="\$work/src"
dest="\$work/dest"
export DESTDIR="\$dest"
export SRCROOT="\$src"
export PKGCACHE="/cache/sources/${spec//\//__}"
export MAKEFLAGS='${MAKEFLAGS}'

. "\$bs"

# Hooks reais
if command -v pre_build >/dev/null 2>&1; then pre_build; fi

# build() obrigatório
build

if command -v post_build >/dev/null 2>&1; then post_build; fi

if command -v pre_install >/dev/null 2>&1; then pre_install; fi

install

if command -v post_install >/dev/null 2>&1; then post_install; fi

EOF
  )

  info "Construindo no chroot"
  chroot_exec "$ch_cmd"

  # overlay files/ (fora ou dentro do chroot tanto faz; aqui fora)
  copy_files_overlay "$spec" "$destdir"

  # empacota
  local pkgfile
  pkgfile="$(make_pkg_tarball "$spec" "$destdir")"
  ok "Pacote gerado: $pkgfile"

  # registra DB com base no DESTDIR gerado
  record_install_db "$spec" "$destdir"

  ok "Build concluído: $spec"
}

install_spec() {
  local spec="$1"
  local skip_verify="$2"
  local skip_if_cached="$3"
  local upgrade_mode="$4" # 1/0: para upgrade seguro

  # resolve deps e instala na ordem
  local -a order
  mapfile -t order < <(resolve_deps_order "$spec")

  info "Ordem de instalação (deps resolvidas):"
  local s
  for s in "${order[@]}"; do
    say "  - $s"
  done

  # Para upgrade seguro: só remove o atual no final, se o novo ok
  # Aqui não removemos automaticamente algo “antigo” com mesmo spec; substitui arquivos pelo tar.
  # Se você quiser versões paralelas, o spec deve mudar.
  for s in "${order[@]}"; do
    if is_installed "$s"; then
      ok "Já instalado: $s"
      continue
    fi

    # se pacote binário em cache existe, instala direto
    local pattern="$CACHEPKG/${s//\//__}-"*.tar.*
    local latest
    latest="$(ls -1t $pattern 2>/dev/null | head -n1 || true)"

    if [[ -n "$latest" ]]; then
      info "Instalando do cache binário: $(basename "$latest")"
      install_pkg_tarball_to_root "$latest"
      # marca instalado (db já existe apenas se foi construído localmente; para binário, criamos db mínimo)
      local dbd
      dbd="$(pkg_db_dir "$s")"
      run "mkdir -p '$dbd'"
      if [[ "$DRYRUN" -eq 0 ]]; then
        printf "%s\n" "$(ts)" > "$dbd/installed"
        printf "%s\n" "$s" > "$dbd/spec"
        printf "%s\n" "installed-from-cache" > "$dbd/name"
        printf "%s\n" "unknown" > "$dbd/version"
        printf "%s\n" "unknown" > "$dbd/release"
        printf "%s\n" "Installed from binary cache (no file DB)" > "$dbd/desc"
        # sem files list = uninstall não é possível com segurança; forçamos rebuild para obter DB real.
      fi
      ok "Instalado do cache: $s (recomendado rebuild para DB completo)"
      continue
    fi

    # senão constrói
    build_one "$s" "$skip_verify" "$skip_if_cached"

    # instala o pacote recém-gerado
    local outbase
    outbase="$(pkg_pkgfile_name "$s")"
    local zst="$CACHEPKG/${outbase}.tar.zst"
    local xz="$CACHEPKG/${outbase}.tar.xz"
    if [[ -f "$zst" ]]; then
      install_pkg_tarball_to_root "$zst"
    elif [[ -f "$xz" ]]; then
      install_pkg_tarball_to_root "$xz"
    else
      die "Pacote não encontrado após build: $s"
    fi
  done

  ok "Instalação concluída: $spec"
}

upgrade_spec() {
  # Rebuild e instala; só remove anterior se o novo build/install ok.
  local spec="$1"
  local skip_verify="$2"
  local skip_if_cached="$3"

  if ! is_installed "$spec"; then
    info "Não instalado; fazendo install normal: $spec"
    install_spec "$spec" "$skip_verify" "$skip_if_cached" 0
    return 0
  fi

  info "Upgrade seguro: $spec"
  # build novo primeiro
  build_one "$spec" "$skip_verify" "$skip_if_cached"

  # instala novo
  local outbase
  outbase="$(pkg_pkgfile_name "$spec")"
  local zst="$CACHEPKG/${outbase}.tar.zst"
  local xz="$CACHEPKG/${outbase}.tar.xz"

  if [[ -f "$zst" ]]; then
    install_pkg_tarball_to_root "$zst"
  elif [[ -f "$xz" ]]; then
    install_pkg_tarball_to_root "$xz"
  else
    die "Upgrade falhou: pacote não encontrado após build: $spec"
  fi

  ok "Upgrade concluído: $spec"
}

# =========================
# SEARCH / INFO
# =========================
list_all_specs() {
  find "$PKGROOT" -mindepth 2 -maxdepth 2 -type d 2>/dev/null \
    | awk -v root="$PKGROOT/" '{sub(root,"",$0); print $0}' \
    | sort
}

cmd_search() {
  local q="${1:-}"
  [[ -n "$q" ]] || die "Uso: adm search <termo>"
  info "Procurando: $q"
  list_all_specs | grep -i -- "$q" | while read -r spec; do
    printf "%-6s %s\n" "$(installed_mark "$spec")" "$spec"
  done
}

cmd_info() {
  local spec="$1"
  local bs
  bs="$(pkg_build_script "$spec")"
  [[ -r "$bs" ]] || die "Pacote não encontrado: $spec"
  # shellcheck disable=SC1090
  source "$bs"

  say "${C_BOLD}${spec}${C_RESET} $(installed_mark "$spec")"
  say "  Nome     : ${PKG_NAME:-}"
  say "  Versão   : ${PKG_VERSION:-}"
  say "  Release  : ${PKG_RELEASE:-}"
  say "  Desc     : ${PKG_DESC:-}"
  say "  URL      : ${PKG_URL:-}"
  say "  Licença  : ${PKG_LICENSE:-}"
  say "  Deps     : ${PKG_DEPS[*]:-}"
  say "  BuildDeps: ${PKG_BUILD_DEPS[*]:-}"
  say "  Sources  :"
  local u
  for u in "${PKG_SOURCES[@]:-}"; do say "    - $u"; done
}

# =========================
# SYNC GIT
# =========================
cmd_sync() {
  need_root
  [[ -n "$GIT_REMOTE" ]] || die "Defina GIT_REMOTE no ambiente ou no topo do script."
  have_cmd git || die "git não encontrado."

  mkdirs
  if [[ -d "$PKGROOT/.git" ]]; then
    info "Atualizando repositório local em $PKGROOT"
    run "git -C '$PKGROOT' fetch --all --prune"
    run "git -C '$PKGROOT' checkout '$GIT_BRANCH'"
    run "git -C '$PKGROOT' pull --ff-only origin '$GIT_BRANCH'"
  else
    info "Clonando repositório em $PKGROOT"
    run "rm -rf '$PKGROOT'"
    run "git clone --branch '$GIT_BRANCH' '$GIT_REMOTE' '$PKGROOT'"
  fi
  ok "Sync concluído."
}

# =========================
# UPDATE (UPSTREAM)
# =========================
ver_gt() {
  # compara versões de forma razoável (sort -V)
  local a="$1" b="$2"
  [[ "$(printf "%s\n%s\n" "$a" "$b" | sort -V | tail -n1)" == "$a" && "$a" != "$b" ]]
}

cmd_update() {
  mkdirs
  local out="$ADM_ROOT/packages/updates"
  : > "$out"

  local count=0
  local spec
  while read -r spec; do
    local bs
    bs="$(pkg_build_script "$spec")"
    [[ -r "$bs" ]] || continue
    # shellcheck disable=SC1090
    source "$bs"

    if declare -F upstream_check >/dev/null 2>&1; then
      local line
      line="$(upstream_check 2>/dev/null || true)"
      [[ -z "$line" ]] && continue
      # esperado: "version url"
      local newver newurl
      newver="$(awk '{print $1}' <<<"$line")"
      newurl="$(awk '{print $2}' <<<"$line")"

      if [[ -n "$newver" && -n "${PKG_VERSION:-}" ]] && ver_gt "$newver" "$PKG_VERSION"; then
        printf "%s %s %s\n" "$spec" "$newver" "$newurl" >> "$out"
        count=$((count+1))
      fi
    fi
  done < <(list_all_specs)

  ok "Updates gerado: $out (total: $count)"

  if have_cmd "$NOTIFY_BIN" && [[ "$count" -gt 0 ]]; then
    run "'$NOTIFY_BIN' 'ADM Updates' '$count atualizações disponíveis (ver: $out)'"
  fi
}

# =========================
# REBUILD-ALL / CLEAN
# =========================
cmd_rebuild_all() {
  need_root
  mkdirs
  info "Rebuild-all: respeitando dependências"
  # pega specs instalados
  local spec
  local -a installed
  installed=()
  while IFS= read -r d; do
    local s
    s="$(basename "$d")"
    s="${s//__/\/}"
    installed+=( "$s" )
  done < <(find "$DBROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  # faz um “super alvo”: resolve e dedup ordenado
  # (na prática, re-resolve por pacote e agrega)
  local -A seen=()
  local -a final=()
  for spec in "${installed[@]}"; do
    local -a order
    mapfile -t order < <(resolve_deps_order "$spec")
    local s
    for s in "${order[@]}"; do
      if [[ -z "${seen[$s]:-}" ]]; then
        seen["$s"]=1
        final+=( "$s" )
      fi
    done
  done

  info "Ordem final (rebuild-all):"
  printf "  - %s\n" "${final[@]}"

  local s
  for s in "${final[@]}"; do
    info "Rebuild: $s"
    build_one "$s" 0 1
    upgrade_spec "$s" 0 1
  done

  ok "Rebuild-all concluído."
}

cmd_clean() {
  need_root
  mkdirs
  info "Limpeza inteligente"
  run "rm -rf '$ADM_ROOT/work' || true"
  run "find '$LOGROOT' -type f -name '*.log' -mtime +30 -delete || true"
  run "find '$CACHEDL' -type f -mtime +90 -delete || true"
  # não remove cache/packages por padrão (muito valioso); apenas arquivos antigos se quiser:
  run "find '$CACHEPKG' -type f -mtime +180 -delete || true"
  # desmonta chroot se algo ficou
  chroot_teardown || true
  ok "Clean concluído."
}

# =========================
# HELP
# =========================
usage() {
  cat <<EOF
${C_BOLD}ADM${C_RESET} - Rolling Release Source Manager (Shell)

${C_BOLD}Uso:${C_RESET}
  adm [opções] <comando> [args]

${C_BOLD}Opções globais:${C_RESET}
  --dry-run           Não executa (mostra o que faria)
  --quiet             Reduz saída
  --no-color          Desliga cores
  --skip-verify       Não confere checksums
  --skip-if-cached    Se já baixado e válido, não baixa de novo

${C_BOLD}Comandos:${C_RESET}
  search <termo>                 Procura pacotes (marca < ✔️ > se instalado)
  info <categoria/programa>      Informações completas (marca < ✔️ > se instalado)

  toolchain-chroot-setup         Prepara chroot de build (mounts e binds)
  chroot-teardown                Desmonta tudo do chroot

  build <categoria/programa>     Baixa/verifica, aplica patch, build em chroot, gera pacote
  install <categoria/programa>   Resolve deps, instala (cache binário ou build)
  upgrade <categoria/programa>   Upgrade seguro (novo build ok antes de substituir)
  uninstall <categoria/programa> Remove arquivos via DB (hooks)

  rebuild-all                    Recompila e reinstala tudo instalado (deps ordenadas)
  clean                          Limpeza inteligente (work, logs antigos, cache antigo)
  sync                           Git sync do repositório (GIT_REMOTE, GIT_BRANCH)
  update                         Checa upstream e gera ${ADM_ROOT}/packages/updates + notify-send

${C_BOLD}Exemplos:${C_RESET}
  adm search musl
  adm info base/busybox
  adm --skip-if-cached install base/busybox
  adm --dry-run upgrade base/zlib
  adm rebuild-all
EOF
}

###############################################################################
# MAIN
###############################################################################
parse_opts() {
  SKIP_VERIFY=0
  SKIP_IF_CACHED=0

  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --dry-run) DRYRUN=1 ;;
      --quiet) QUIET=1 ;;
      --no-color) USE_COLOR=0 ;;
      --skip-verify) SKIP_VERIFY=1 ;;
      --skip-if-cached) SKIP_IF_CACHED=1 ;;
      *) die "Opção inválida: $1" ;;
    esac
    shift
  done

  export SKIP_VERIFY SKIP_IF_CACHED
  echo "$@"
}

main() {
  mkdirs

  # reparsing após cores (se no-color)
  local args
  args="$(parse_opts "$@")"
  # shellcheck disable=SC2086
  set -- $args

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    ""|help|-h|--help) usage ;;
    search) cmd_search "${1:-}" ;;
    info) cmd_info "${1:-}" ;;
    toolchain-chroot-setup) with_lock chroot_setup ;;
    chroot-teardown) with_lock chroot_teardown ;;
    build) with_lock build_one "${1:-}" "$SKIP_VERIFY" "$SKIP_IF_CACHED" ;;
    install) with_lock install_spec "${1:-}" "$SKIP_VERIFY" "$SKIP_IF_CACHED" 0 ;;
    upgrade) with_lock upgrade_spec "${1:-}" "$SKIP_VERIFY" "$SKIP_IF_CACHED" ;;
    uninstall) with_lock uninstall_spec "${1:-}" ;;
    rebuild-all) with_lock cmd_rebuild_all ;;
    clean) with_lock cmd_clean ;;
    sync) with_lock cmd_sync ;;
    update) with_lock cmd_update ;;
    *) die "Comando inválido: $cmd (use: adm help)" ;;
  esac
}

main "$@"
