#!/usr/bin/env bash
# adm - Linux From Scratch manager (single-file)
# Root: /usr/adm
# Requires: bash>=4, coreutils, findutils, tar, zstd, curl, git (optional for git+ and sync), rsync
set -Eeuo pipefail
shopt -s nullglob

###############################################################################
# Defaults (expansíveis; podem ser sobrescritos por /usr/adm/conf/adm.conf,
# variáveis de ambiente e flags)
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/adm}"

ADM_CONF="${ADM_CONF:-$ADM_ROOT/conf/adm.conf}"

ADM_REPO_DIR="${ADM_REPO_DIR:-$ADM_ROOT/repo}"
ADM_REPO_URL="${ADM_REPO_URL:-}"
ADM_REPO_BRANCH="${ADM_REPO_BRANCH:-main}"

ADM_DISTFILES="${ADM_DISTFILES:-$ADM_ROOT/cache/distfiles}"
ADM_PKGCACHE="${ADM_PKGCACHE:-$ADM_ROOT/cache/pkg}"
ADM_GITCACHE="${ADM_GITCACHE:-$ADM_ROOT/cache/git}"

ADM_STATE="${ADM_STATE:-$ADM_ROOT/state}"
ADM_WORLD="${ADM_WORLD:-$ADM_STATE/world}"
ADM_INSTALLED_DB="${ADM_INSTALLED_DB:-$ADM_STATE/installed}"
ADM_LOGDIR="${ADM_LOGDIR:-$ADM_STATE/logs}"
ADM_LOCKDIR="${ADM_LOCKDIR:-$ADM_STATE/locks}"

ADM_BUILDROOT="${ADM_BUILDROOT:-$ADM_ROOT/build}"
ADM_STAGE="${ADM_STAGE:-$ADM_ROOT/stage}"

ADM_TOOLS="${ADM_TOOLS:-$ADM_ROOT/tools}"
ADM_ROOTFS="${ADM_ROOTFS:-$ADM_ROOT/rootfs}"

ADM_JOBS="${ADM_JOBS:-$(nproc 2>/dev/null || echo 1)}"
ADM_KEEP_BUILD="${ADM_KEEP_BUILD:-0}"
ADM_UMASK="${ADM_UMASK:-022}"
ADM_REQUIRE_HASH="${ADM_REQUIRE_HASH:-1}"

# Output formatting
ADM_COLOR="${ADM_COLOR:-1}"

###############################################################################
# UI / Logging
###############################################################################
adm_ts(){ date +"%Y-%m-%d %H:%M:%S"; }

adm_color(){
  local code="$1"; shift
  if [[ "${ADM_COLOR}" -eq 1 && -t 1 ]]; then
    printf "\033[%sm%s\033[0m" "$code" "$*"
  else
    printf "%s" "$*"
  fi
}

adm_info(){ echo "$(adm_color 1\;34 INFO) $*"; }
adm_warn(){ echo "$(adm_color 1\;33 WARN) $*"; }
adm_ok(){   echo "$(adm_color 1\;32 OK)   $*"; }
adm_fail(){ echo "$(adm_color 1\;31 FAIL) $*"; }

adm_die(){ adm_fail "$*"; exit 1; }

# Global log FD 3 (set per operation)
adm_log_init(){
  local logfile="$1"
  mkdir -p "$(dirname "$logfile")"
  : >"$logfile"
  exec 3>>"$logfile"
  adm_log "logfile=$logfile"
}
adm_log(){ echo "[$(adm_ts)] $*" >&3; }

# Trap for error context
adm_on_err(){
  local ec=$?
  local line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-?}"
  adm_fail "Falha (exit=$ec) na linha $line: $cmd"
  if [[ -n "${ADM_ACTIVE_LOG:-}" ]]; then
    adm_fail "Verifique o log: ${ADM_ACTIVE_LOG}"
  fi
  exit "$ec"
}
trap adm_on_err ERR

###############################################################################
# Helpers
###############################################################################
adm_need_cmd(){
  command -v "$1" >/dev/null 2>&1 || adm_die "Comando requerido não encontrado: $1"
}

adm_mkdir(){ mkdir -p "$@" || adm_die "Falha criando diretório: $*"; }

adm_realpath(){
  # compatível com busybox/coreutils
  python3 - <<'PY' "$1" 2>/dev/null || readlink -f "$1"
import os,sys
print(os.path.realpath(sys.argv[1]))
PY
}

adm_lock_acquire(){
  local key="$1"
  adm_mkdir "$ADM_LOCKDIR"
  local lock="$ADM_LOCKDIR/$key.lock"
  if mkdir "$lock" 2>/dev/null; then
    echo "$$" >"$lock/pid"
    echo "$lock"
  else
    adm_die "Lock ativo para '$key' (existe $lock). Se tiver certeza, remova manualmente."
  fi
}
adm_lock_release(){
  local lock="$1"
  [[ -n "$lock" && -d "$lock" ]] && rm -rf "$lock"
}

adm_load_conf(){
  [[ -f "$ADM_CONF" ]] || return 0
  # shellcheck disable=SC1090
  source "$ADM_CONF"
}

adm_init_tree(){
  adm_mkdir \
    "$ADM_ROOT/bin" "$ADM_ROOT/conf" "$ADM_ROOT/cache" "$ADM_ROOT/lib" \
    "$ADM_ROOT/packages" "$ADM_ROOT/profiles" \
    "$ADM_DISTFILES" "$ADM_PKGCACHE" "$ADM_GITCACHE" \
    "$ADM_STATE" "$ADM_INSTALLED_DB" "$ADM_LOGDIR" "$ADM_LOCKDIR" \
    "$ADM_BUILDROOT" "$ADM_STAGE" \
    "$ADM_TOOLS" "$ADM_ROOTFS" \
    "$ADM_REPO_DIR"

  [[ -f "$ADM_WORLD" ]] || : >"$ADM_WORLD"

  # Profiles padrão (arquivos simples; gerenciador continua um único programa)
  if [[ ! -f "$ADM_ROOT/profiles/glibc.default.profile" ]]; then
    cat >"$ADM_ROOT/profiles/glibc.default.profile" <<'EOF'
ADM_LIBC="glibc"
ADM_HOST_TRIPLET="${ADM_HOST_TRIPLET:-$(gcc -dumpmachine 2>/dev/null || echo x86_64-pc-linux-gnu)}"
ADM_LIBC_CFLAGS="${ADM_LIBC_CFLAGS:- -O2 -pipe}"
ADM_LIBC_LDFLAGS="${ADM_LIBC_LDFLAGS:- }"
EOF
  fi
  if [[ ! -f "$ADM_ROOT/profiles/musl.default.profile" ]]; then
    cat >"$ADM_ROOT/profiles/musl.default.profile" <<'EOF'
ADM_LIBC="musl"
ADM_HOST_TRIPLET="${ADM_HOST_TRIPLET:-$(gcc -dumpmachine 2>/dev/null || echo x86_64-pc-linux-gnu)}"
ADM_LIBC_CFLAGS="${ADM_LIBC_CFLAGS:- -O2 -pipe}"
ADM_LIBC_LDFLAGS="${ADM_LIBC_LDFLAGS:- }"
EOF
  fi

  # Config default se não existir
  if [[ ! -f "$ADM_CONF" ]]; then
    cat >"$ADM_CONF" <<EOF
ADM_ROOT="$ADM_ROOT"
ADM_REPO_DIR="$ADM_REPO_DIR"
ADM_REPO_URL="$ADM_REPO_URL"
ADM_REPO_BRANCH="$ADM_REPO_BRANCH"
ADM_DISTFILES="$ADM_DISTFILES"
ADM_PKGCACHE="$ADM_PKGCACHE"
ADM_GITCACHE="$ADM_GITCACHE"
ADM_STATE="$ADM_STATE"
ADM_WORLD="$ADM_WORLD"
ADM_INSTALLED_DB="$ADM_INSTALLED_DB"
ADM_LOGDIR="$ADM_LOGDIR"
ADM_BUILDROOT="$ADM_BUILDROOT"
ADM_STAGE="$ADM_STAGE"
ADM_TOOLS="$ADM_TOOLS"
ADM_ROOTFS="$ADM_ROOTFS"
ADM_JOBS="$ADM_JOBS"
ADM_KEEP_BUILD="$ADM_KEEP_BUILD"
ADM_UMASK="$ADM_UMASK"
ADM_REQUIRE_HASH="$ADM_REQUIRE_HASH"
ADM_COLOR="$ADM_COLOR"
EOF
  fi
}

###############################################################################
# World DB (word/world)
###############################################################################
adm_world_has(){ grep -Fxq "$1" "$ADM_WORLD" 2>/dev/null; }
adm_world_add(){
  local pkgid="$1"
  adm_world_has "$pkgid" && return 0
  echo "$pkgid" >>"$ADM_WORLD"
}
adm_world_remove(){
  local pkgid="$1"
  [[ -f "$ADM_WORLD" ]] || return 0
  grep -Fxv "$pkgid" "$ADM_WORLD" >"$ADM_WORLD.tmp" || true
  mv -f "$ADM_WORLD.tmp" "$ADM_WORLD"
}
adm_world_list(){ sort -u "$ADM_WORLD"; }

###############################################################################
# Profiles/Targets
###############################################################################
adm_profile_load(){
  local p="$1"
  local pf="$ADM_ROOT/profiles/${p}.profile"
  [[ -f "$pf" ]] || adm_die "Profile não encontrado: $p (esperado: $pf). Ex: glibc.default ou musl.default"
  # shellcheck disable=SC1090
  source "$pf"
  : "${ADM_LIBC:?Profile deve definir ADM_LIBC}"
  : "${ADM_HOST_TRIPLET:?Profile deve definir ADM_HOST_TRIPLET}"
}

adm_target_env(){
  local target="$1"
  local profile="$2"

  export ADM_TARGET_TRIPLET="$target"
  export ADM_PROFILE="$profile"

  export ADM_TARGET_TOOLS="$ADM_TOOLS/$ADM_TARGET_TRIPLET"
  export ADM_TARGET_ROOTFS="$ADM_ROOTFS/$ADM_LIBC/$ADM_TARGET_TRIPLET"

  adm_mkdir "$ADM_TARGET_TOOLS" "$ADM_TARGET_ROOTFS"

  export SYSROOT="$ADM_TARGET_ROOTFS"
  export TOOLSROOT="$ADM_TARGET_TOOLS"

  export PATH="$TOOLSROOT/bin:$PATH"
  export MAKEFLAGS="-j${ADM_JOBS}"
  export LC_ALL=C

  export CFLAGS="${CFLAGS:-${ADM_LIBC_CFLAGS:- -O2 -pipe}}"
  export CXXFLAGS="${CXXFLAGS:-${ADM_LIBC_CFLAGS:- -O2 -pipe}}"
  export LDFLAGS="${LDFLAGS:-${ADM_LIBC_LDFLAGS:- }}"

  # Triplet helpers
  export CHOST="${CHOST:-$ADM_HOST_TRIPLET}"
  export CTARGET="${CTARGET:-$ADM_TARGET_TRIPLET}"

  # Compiladores default (podem ser substituídos pelos packages)
  export CC="${CC:-${CTARGET}-gcc}"
  export CXX="${CXX:-${CTARGET}-g++}"
  export AR="${AR:-${CTARGET}-ar}"
  export RANLIB="${RANLIB:-${CTARGET}-ranlib}"
  export STRIP="${STRIP:-${CTARGET}-strip}"
}

###############################################################################
# Package scripts API
# Cada script em /usr/adm/packages/cat/name-ver.sh deve definir:
#   PKG_CATEGORY, PKG_NAME, PKG_VERSION
# Opcional:
#   PKG_RELEASE (default 1)
#   PKG_DESC, PKG_LICENSE, PKG_SITE
#   PKG_DEPENDS=( "cat/name-ver" ... )
#   PKG_URLS=( "https://..." ... )  # ou "git+https://..."
#   PKG_SHA256="..." ou PKG_MD5="..."
#   PKG_GIT_REF="tag/commit/branch" (se usar git+)
# Hooks opcionais:
#   pkg_prepare, pkg_configure, pkg_build, pkg_install, pkg_check
###############################################################################
# Globals per package load
PKG_CATEGORY="" PKG_NAME="" PKG_VERSION="" PKG_RELEASE="1"
PKG_DESC="" PKG_LICENSE="" PKG_SITE=""
declare -a PKG_URLS=()
declare -a PKG_DEPENDS=()
PKG_SHA256="" PKG_MD5="" PKG_GIT_REF=""

adm_pkg_path(){
  local spec="$1" # cat/name-ver
  local cat="${spec%%/*}"
  local nv="${spec#*/}"
  echo "$ADM_ROOT/packages/$cat/${nv}.sh"
}

adm_pkg_reset(){
  PKG_CATEGORY="" PKG_NAME="" PKG_VERSION="" PKG_RELEASE="1"
  PKG_DESC="" PKG_LICENSE="" PKG_SITE=""
  PKG_SHA256="" PKG_MD5="" PKG_GIT_REF=""
  PKG_URLS=()
  PKG_DEPENDS=()
  unset -f pkg_prepare pkg_configure pkg_build pkg_install pkg_check 2>/dev/null || true
}

adm_pkg_load(){
  local pkgfile="$1"
  [[ -f "$pkgfile" ]] || adm_die "Script de pacote não encontrado: $pkgfile"
  adm_pkg_reset
  # shellcheck disable=SC1090
  source "$pkgfile"
  : "${PKG_CATEGORY:?Pacote deve definir PKG_CATEGORY}"
  : "${PKG_NAME:?Pacote deve definir PKG_NAME}"
  : "${PKG_VERSION:?Pacote deve definir PKG_VERSION}"
  PKG_RELEASE="${PKG_RELEASE:-1}"
}

adm_pkg_id(){ echo "${PKG_CATEGORY}/${PKG_NAME}-${PKG_VERSION}"; }

adm_manifest_dir(){
  local pkgid="$1"
  echo "$ADM_INSTALLED_DB/${pkgid//\//_}"
}

adm_stage_dir(){
  local pkgid="$1"
  echo "$ADM_STAGE/$pkgid"
}

adm_env_signature(){
  # Assinatura para cache binário reprodutível por ambiente (simplificada)
  printf "%s\n" \
    "profile=$ADM_PROFILE" \
    "libc=$ADM_LIBC" \
    "target=$ADM_TARGET_TRIPLET" \
    "cflags=${CFLAGS}" \
    "cxxflags=${CXXFLAGS}" \
    "ldflags=${LDFLAGS}" | sha256sum | awk '{print $1}'
}

###############################################################################
# Download/caching (http/https/ftp e git+)
###############################################################################
adm_hash_ok_file(){
  local file="$1"
  if [[ -n "${PKG_SHA256:-}" ]]; then
    adm_need_cmd sha256sum
    echo "${PKG_SHA256}  $file" | sha256sum -c - >/dev/null 2>&1
    return $?
  elif [[ -n "${PKG_MD5:-}" ]]; then
    adm_need_cmd md5sum
    echo "${PKG_MD5}  $file" | md5sum -c - >/dev/null 2>&1
    return $?
  else
    [[ "$ADM_REQUIRE_HASH" -eq 1 ]] && adm_die "Hash ausente (sha256/md5) e ADM_REQUIRE_HASH=1 para $(adm_pkg_id)"
    return 0
  fi
}

adm_fetch_http(){
  local url="$1" out="$2"
  adm_need_cmd curl
  curl -L --fail --retry 3 --retry-delay 2 -o "$out" "$url"
}

adm_fetch_git_to_tar(){
  # git+URL => usa mirror cache e exporta tar (git archive)
  local giturl="$1" out="$2"
  adm_need_cmd git

  local real="${giturl#git+}"
  local key; key="$(echo "$real" | sed 's/[^A-Za-z0-9._-]/_/g')"
  local mirror="$ADM_GITCACHE/${key}.git"

  if [[ ! -d "$mirror" ]]; then
    adm_info "Clonando mirror git: $real"
    git clone --mirror "$real" "$mirror"
  else
    adm_info "Atualizando mirror git: $real"
    (cd "$mirror" && git fetch --all --prune)
  fi

  local ref="${PKG_GIT_REF:-HEAD}"
  # git archive via --git-dir
  adm_info "Gerando tar (git archive) ref=$ref"
  git --git-dir="$mirror" archive --format=tar "$ref" >"$out"
}

adm_fetch(){
  local pkgid; pkgid="$(adm_pkg_id)"

  adm_mkdir "$ADM_DISTFILES"

  # Nome “cache key” inclui git ref quando for git
  local refpart=""
  [[ -n "${PKG_GIT_REF:-}" ]] && refpart=".ref-${PKG_GIT_REF//\//_}"

  local base="${PKG_NAME}-${PKG_VERSION}${refpart}"
  local tarball="$ADM_DISTFILES/${base}.src.tar"

  if [[ -f "$tarball" ]]; then
    if adm_hash_ok_file "$tarball"; then
      adm_ok "Usando distfile do cache: $tarball"
      echo "$tarball"
      return 0
    else
      adm_warn "Distfile em cache com hash inválido. Rebaixando: $tarball"
      rm -f "$tarball"
    fi
  fi

  [[ "${#PKG_URLS[@]}" -ge 1 ]] || adm_die "PKG_URLS vazio em $pkgid"

  local tmp="$tarball.part"
  rm -f "$tmp"

  local u ok=0
  for u in "${PKG_URLS[@]}"; do
    adm_info "Tentando fonte: $u"
    if [[ "$u" == git+* ]]; then
      adm_fetch_git_to_tar "$u" "$tmp"
    else
      adm_fetch_http "$u" "$tmp"
    fi

    if adm_hash_ok_file "$tmp"; then
      mv -f "$tmp" "$tarball"
      ok=1
      break
    else
      adm_warn "Hash não confere para: $u"
      rm -f "$tmp"
    fi
  done

  [[ "$ok" -eq 1 ]] || adm_die "Não foi possível obter fonte válida (hash ok) para $pkgid"
  adm_ok "Fonte ok em cache: $tarball"
  echo "$tarball"
}

###############################################################################
# Unpack/build/install/package
###############################################################################
adm_run_hook(){
  local hook="$1"
  if declare -F "$hook" >/dev/null 2>&1; then
    adm_info "Hook: $hook"
    adm_log "hook=$hook"
    "$hook"
  fi
}

adm_unpack(){
  local tarball="$1" workdir="$2"
  adm_need_cmd tar
  rm -rf "$workdir"
  adm_mkdir "$workdir"
  tar -xf "$tarball" -C "$workdir"
}

adm_pkg_build(){
  local pkgfile="$1"

  adm_need_cmd tar
  adm_need_cmd zstd

  adm_pkg_load "$pkgfile"
  local pkgid; pkgid="$(adm_pkg_id)"

  local lock; lock="$(adm_lock_acquire "build_${pkgid//\//_}")"
  trap 'adm_lock_release "'"$lock"'"' RETURN

  local logfile="$ADM_LOGDIR/${PKG_NAME}-${PKG_VERSION}.${ADM_PROFILE}.${ADM_TARGET_TRIPLET}.build.log"
  ADM_ACTIVE_LOG="$logfile"
  adm_log_init "$logfile"

  umask "$ADM_UMASK"

  # Diretórios
  local work="$ADM_BUILDROOT/${PKG_NAME}-${PKG_VERSION}.work"
  local build="$ADM_BUILDROOT/${PKG_NAME}-${PKG_VERSION}.build"
  local stage; stage="$(adm_stage_dir "$pkgid")"

  rm -rf "$build" "$stage"
  adm_mkdir "$build" "$stage"

  adm_log "pkgid=$pkgid"
  adm_log "target=$ADM_TARGET_TRIPLET profile=$ADM_PROFILE libc=$ADM_LIBC"
  adm_log "sysroot=$SYSROOT toolsroot=$TOOLSROOT"
  adm_log "cflags=$CFLAGS cxxflags=$CXXFLAGS ldflags=$LDFLAGS"
  adm_log "makeflags=$MAKEFLAGS"

  # Cache binário: se existir e assinatura igual, podemos pular build
  local sig; sig="$(adm_env_signature)"
  local pkgout="$ADM_PKGCACHE/${PKG_NAME}-${PKG_VERSION}-${PKG_RELEASE}.${ADM_PROFILE}.${ADM_TARGET_TRIPLET}.tar.zst"
  local pkgmeta="${pkgout}.meta"
  if [[ -f "$pkgout" && -f "$pkgmeta" ]]; then
    if grep -Fxq "envsig=$sig" "$pkgmeta" 2>/dev/null; then
      adm_ok "Cache binário válido encontrado: $pkgout"
      adm_log "binary_cache_hit=1"
      # Ainda garantimos que stage existe ao instalar; aqui apenas sinaliza build ok
      if [[ "$ADM_KEEP_BUILD" -eq 0 ]]; then
        rm -rf "$work" "$build"
      fi
      return 0
    fi
  fi

  local tarball; tarball="$(adm_fetch)"
  adm_unpack "$tarball" "$work"

  # Expor diretórios para o pacote
  export PKG_WORKDIR="$work"
  export PKG_BUILDDIR="$build"
  export PKG_STAGEDIR="$stage"
  export PKGID="$pkgid"

  adm_run_hook "pkg_prepare"
  adm_run_hook "pkg_configure"
  adm_run_hook "pkg_build"
  adm_run_hook "pkg_install"
  adm_run_hook "pkg_check"

  # Manifest do stage
  local mdir; mdir="$(adm_manifest_dir "$pkgid")"
  rm -rf "$mdir"
  adm_mkdir "$mdir"
  (cd "$stage" && find . -mindepth 1 -print | sort) >"$mdir/manifest.files"
  printf "%s\n" "$pkgid" >"$mdir/pkgid"
  printf "%s\n" "$(adm_ts)" >"$mdir/built_at"
  printf "%s\n" "$ADM_TARGET_TRIPLET" >"$mdir/target"
  printf "%s\n" "$ADM_PROFILE" >"$mdir/profile"
  printf "%s\n" "$ADM_LIBC" >"$mdir/libc"
  printf "%s\n" "$sig" >"$mdir/envsig"
  # Registra deps (para orphans corretos)
  : >"$mdir/depends"
  local dep
  for dep in "${PKG_DEPENDS[@]:-}"; do
    echo "$dep" >>"$mdir/depends"
  done

  # Empacotar stage -> pkgcache
  adm_mkdir "$ADM_PKGCACHE"
  rm -f "$pkgout"
  (cd "$stage" && tar -cf - .) | zstd -19 -T0 -o "$pkgout"
  cat >"$pkgmeta" <<EOF
pkgid=$pkgid
built_at=$(adm_ts)
envsig=$sig
target=$ADM_TARGET_TRIPLET
profile=$ADM_PROFILE
libc=$ADM_LIBC
EOF

  adm_ok "Build concluído: $pkgid"
  adm_ok "Pacote binário: $pkgout"

  [[ "$ADM_KEEP_BUILD" -eq 1 ]] || rm -rf "$work" "$build"
}

adm_pkg_install(){
  local pkgfile="$1"
  adm_need_cmd rsync
  adm_need_cmd tar
  adm_need_cmd zstd

  adm_pkg_load "$pkgfile"
  local pkgid; pkgid="$(adm_pkg_id)"

  local lock; lock="$(adm_lock_acquire "install_${pkgid//\//_}")"
  trap 'adm_lock_release "'"$lock"'"' RETURN

  local logfile="$ADM_LOGDIR/${PKG_NAME}-${PKG_VERSION}.${ADM_PROFILE}.${ADM_TARGET_TRIPLET}.install.log"
  ADM_ACTIVE_LOG="$logfile"
  adm_log_init "$logfile"

  local stage; stage="$(adm_stage_dir "$pkgid")"
  local pkgout="$ADM_PKGCACHE/${PKG_NAME}-${PKG_VERSION}-${PKG_RELEASE}.${ADM_PROFILE}.${ADM_TARGET_TRIPLET}.tar.zst"

  # Se stage não existir, tente extrair do pkgcache; se não existir, build.
  if [[ ! -d "$stage" ]]; then
    if [[ -f "$pkgout" ]]; then
      adm_info "Extraindo de cache binário para stage: $pkgout"
      rm -rf "$stage"; adm_mkdir "$stage"
      zstd -dc "$pkgout" | tar -xf - -C "$stage"
    else
      adm_info "Cache binário ausente; realizando build: $pkgid"
      adm_pkg_build "$pkgfile"
      [[ -d "$stage" ]] || {
        # se build usou cache binário, stage pode não existir; extrair
        if [[ -f "$pkgout" ]]; then
          rm -rf "$stage"; adm_mkdir "$stage"
          zstd -dc "$pkgout" | tar -xf - -C "$stage"
        fi
      }
    fi
  fi

  [[ -d "$stage" ]] || adm_die "Stage não disponível para instalar: $pkgid"

  # Instala em SYSROOT (rootfs do target/profile)
  adm_info "Instalando $pkgid em: $SYSROOT"
  rsync -aHAX --delete-delay "$stage/." "$SYSROOT/."

  # Marca como instalado no world se o usuário quiser (regra: install => adiciona)
  adm_world_add "$pkgid"

  adm_ok "Instalado e registrado no world: $pkgid"
}

adm_pkg_remove(){
  local pkgid="$1"

  local mdir; mdir="$(adm_manifest_dir "$pkgid")"
  [[ -d "$mdir" ]] || adm_die "Manifest não encontrado (não registrado como instalado): $pkgid"
  [[ -f "$mdir/manifest.files" ]] || adm_die "Manifest inválido: $pkgid"

  local lock; lock="$(adm_lock_acquire "remove_${pkgid//\//_}")"
  trap 'adm_lock_release "'"$lock"'"' RETURN

  local logfile="$ADM_LOGDIR/${pkgid//\//_}.${ADM_PROFILE}.${ADM_TARGET_TRIPLET}.remove.log"
  ADM_ACTIVE_LOG="$logfile"
  adm_log_init "$logfile"

  adm_info "Removendo $pkgid (ordem reversa)"
  # Remoção reversa (arquivos primeiro, depois dirs)
  local tmp; tmp="$(mktemp)"
  tac "$mdir/manifest.files" >"$tmp"

  while IFS= read -r rel; do
    local p="${rel#./}"
    [[ -z "$p" ]] && continue
    local full="$SYSROOT/$p"
    if [[ -L "$full" || -f "$full" ]]; then
      rm -f "$full" || true
    elif [[ -d "$full" ]]; then
      rmdir "$full" 2>/dev/null || true
    fi
  done <"$tmp"
  rm -f "$tmp"

  # Remove do world (se estiver)
  adm_world_remove "$pkgid"
  rm -rf "$mdir"
  rm -rf "$(adm_stage_dir "$pkgid")" 2>/dev/null || true

  adm_ok "Removido: $pkgid"
}

###############################################################################
# Dependency resolution (DAG + ciclo)
###############################################################################
adm_resolve_deps(){
  # Entrada: specs "cat/name-ver" ... (targets a instalar/build)
  # Saída: lista pkgfiles em ordem topológica (deps primeiro)
  local -a specs=("$@")
  local -A temp perm
  local -a order

  _visit(){
    local spec="$1"
    local file; file="$(adm_pkg_path "$spec")"
    adm_pkg_load "$file"
    local node; node="$(adm_pkg_id)"

    if [[ "${perm[$node]:-0}" -eq 1 ]]; then return 0; fi
    if [[ "${temp[$node]:-0}" -eq 1 ]]; then
      adm_die "Ciclo de dependência detectado envolvendo: $node"
    fi

    temp["$node"]=1
    local dep
    for dep in "${PKG_DEPENDS[@]:-}"; do
      _visit "$dep"
    done
    temp["$node"]=0
    perm["$node"]=1
    order+=("$file")
  }

  local s
  for s in "${specs[@]}"; do
    _visit "$s"
  done

  printf "%s\n" "${order[@]}"
}

###############################################################################
# Orphans (real: a partir do world, manter deps transitivas instaladas)
###############################################################################
adm_list_installed_pkgids(){
  local d
  for d in "$ADM_INSTALLED_DB"/*; do
    [[ -d "$d" && -f "$d/pkgid" ]] || continue
    cat "$d/pkgid"
  done
}

adm_orphans_list(){
  # Constrói conjunto "keep" = world + deps transitivas (somente entre instalados)
  local -A installed keep
  local pkgid

  while IFS= read -r pkgid; do
    installed["$pkgid"]=1
  done < <(adm_list_installed_pkgids)

  # BFS/DFS a partir do world
  local -a stack=()
  while IFS= read -r pkgid; do
    [[ -n "$pkgid" ]] || continue
    if [[ "${installed[$pkgid]:-0}" -eq 1 ]]; then
      stack+=("$pkgid")
    fi
  done < <(adm_world_list)

  while [[ "${#stack[@]}" -gt 0 ]]; do
    local cur="${stack[-1]}"
    unset 'stack[-1]'
    [[ "${keep[$cur]:-0}" -eq 1 ]] && continue
    keep["$cur"]=1
    local mdir; mdir="$(adm_manifest_dir "$cur")"
    if [[ -f "$mdir/depends" ]]; then
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        if [[ "${installed[$dep]:-0}" -eq 1 && "${keep[$dep]:-0}" -ne 1 ]]; then
          stack+=("$dep")
        fi
      done <"$mdir/depends"
    fi
  done

  # Orphans = installed - keep
  for pkgid in "${!installed[@]}"; do
    [[ "${keep[$pkgid]:-0}" -eq 1 ]] && continue
    echo "$pkgid"
  done | sort
}

###############################################################################
# Check/Repair
###############################################################################
adm_check(){
  local fix="${1:-0}"

  adm_info "Check: valida manifests vs filesystem, e integridade mínima"
  local missing=0

  local d pkgid mf
  for d in "$ADM_INSTALLED_DB"/*; do
    [[ -d "$d" && -f "$d/pkgid" ]] || continue
    pkgid="$(cat "$d/pkgid")"
    mf="$d/manifest.files"
    [[ -f "$mf" ]] || { adm_warn "Manifest ausente: $pkgid"; missing=1; continue; }

    while IFS= read -r rel; do
      local p="${rel#./}"
      [[ -z "$p" ]] && continue
      local full="$SYSROOT/$p"
      if [[ ! -e "$full" && ! -L "$full" ]]; then
        adm_warn "Ausente: $pkgid :: $full"
        missing=1
      fi
    done <"$mf"
  done

  if [[ "$missing" -eq 0 ]]; then
    adm_ok "Check OK"
    return 0
  fi

  adm_fail "Inconsistências detectadas."
  if [[ "$fix" -eq 1 ]]; then
    adm_warn "--fix: reinstalando pacotes do world (repara por sobreposição rsync)"
    # Reinstala tudo do world na ordem de deps (quando scripts existirem)
    local -a specs=()
    while IFS= read -r pkgid; do
      specs+=("$pkgid")
    done < <(adm_world_list)

    if [[ "${#specs[@]}" -eq 0 ]]; then
      adm_warn "world vazio; nada para reinstalar."
      return 2
    fi

    # Para reinstalar precisamos mapear pkgid -> script
    # Aqui assumimos que pkgid está no formato cat/name-ver (igual ao spec)
    local -a files=()
    local s f
    for s in "${specs[@]}"; do
      f="$(adm_pkg_path "$s")"
      if [[ -f "$f" ]]; then
        files+=("$f")
      else
        adm_warn "Script ausente para $s (não consigo reparar automaticamente)."
      fi
    done

    # Resolução de deps a partir dos specs do world (pelo que os scripts declaram)
    mapfile -t files < <(adm_resolve_deps "${specs[@]}")
    for f in "${files[@]}"; do
      adm_pkg_install "$f"
    done
  fi

  return 2
}

###############################################################################
# Search/info/deps
###############################################################################
adm_is_installed_mark(){
  local pkgid="$1"
  if adm_world_has "$pkgid"; then
    printf "[ ✔️ ]"
  else
    printf "[    ]"
  fi
}

adm_cmd_search(){
  local q="$1"
  [[ -n "$q" ]] || adm_die "Uso: search <texto>"

  local f
  while IFS= read -r f; do
    adm_pkg_load "$f"
    local pkgid; pkgid="$(adm_pkg_id)"
    local mark; mark="$(adm_is_installed_mark "$pkgid")"
    echo "$mark $pkgid - ${PKG_DESC:-}"
  done < <(grep -RIl -- "$q" "$ADM_ROOT/packages" 2>/dev/null || true)
}

adm_cmd_info(){
  local spec="$1"
  local f; f="$(adm_pkg_path "$spec")"
  adm_pkg_load "$f"
  local pkgid; pkgid="$(adm_pkg_id)"
  local mark; mark="$(adm_is_installed_mark "$pkgid")"
  echo "$mark $pkgid"
  [[ -n "$PKG_DESC" ]] && echo "  desc: $PKG_DESC"
  [[ -n "$PKG_LICENSE" ]] && echo "  license: $PKG_LICENSE"
  [[ -n "$PKG_SITE" ]] && echo "  site: $PKG_SITE"
  echo "  depends:"
  if [[ "${#PKG_DEPENDS[@]}" -eq 0 ]]; then
    echo "    (none)"
  else
    local d; for d in "${PKG_DEPENDS[@]}"; do echo "    - $d"; done
  fi
  echo "  urls:"
  local u; for u in "${PKG_URLS[@]}"; do echo "    - $u"; done
  [[ -n "$PKG_SHA256" ]] && echo "  sha256: $PKG_SHA256"
  [[ -n "$PKG_MD5" ]] && echo "  md5: $PKG_MD5"
  [[ -n "$PKG_GIT_REF" ]] && echo "  git_ref: $PKG_GIT_REF"
}

adm_cmd_deps(){
  local spec="$1"
  mapfile -t files < <(adm_resolve_deps "$spec")
  adm_info "Ordem de build/install (deps primeiro):"
  local f
  for f in "${files[@]}"; do
    adm_pkg_load "$f"
    echo "  - $(adm_pkg_id)"
  done
}

###############################################################################
# Repo sync
###############################################################################
adm_cmd_sync(){
  [[ -n "$ADM_REPO_URL" ]] || adm_die "ADM_REPO_URL vazio em $ADM_CONF. Defina seu repo git."
  adm_need_cmd git

  if [[ ! -d "$ADM_REPO_DIR/.git" ]]; then
    adm_info "Clonando repo de scripts: $ADM_REPO_URL"
    git clone -b "$ADM_REPO_BRANCH" "$ADM_REPO_URL" "$ADM_REPO_DIR"
  else
    adm_info "Atualizando repo de scripts em $ADM_REPO_DIR"
    (cd "$ADM_REPO_DIR" && git fetch --all --prune && git reset --hard "origin/$ADM_REPO_BRANCH")
  fi
  adm_ok "Repo sincronizado."
}

###############################################################################
# Clean
###############################################################################
adm_cmd_clean(){
  adm_info "Limpeza: build/stage temporários e logs antigos"
  rm -rf "$ADM_BUILDROOT"/* "$ADM_STAGE"/* 2>/dev/null || true
  # Remove logs com mais de 60 dias
  find "$ADM_LOGDIR" -type f -name "*.log" -mtime +60 -delete 2>/dev/null || true
  adm_ok "Limpeza concluída."
}

###############################################################################
# CLI parsing
###############################################################################
usage(){
  cat <<'EOF'
adm - gerenciador LFS (single-file)

Uso:
  adm init
  adm sync
  adm build   --profile <glibc.default|musl.default> --target <triplet> <cat/name-ver>...
  adm install --profile <...> --target <...> <cat/name-ver>...
  adm remove  --profile <...> --target <...> <cat/name-ver|pkgid>...
  adm world add|remove|list [cat/name-ver]
  adm orphans --profile <...> --target <...> [--remove]
  adm clean
  adm check   --profile <...> --target <...> [--fix]
  adm search  <texto>
  adm info    <cat/name-ver>
  adm deps    <cat/name-ver>

Observações:
- Scripts de pacotes: /usr/adm/packages/categoria/programa-versao.sh
- "world" (você chamou de word) é: /usr/adm/state/world
EOF
}

# Common flags
PROFILE="" TARGET="" FIX=0 ORPH_REMOVE=0

parse_common(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) PROFILE="$2"; shift 2;;
      --target)  TARGET="$2"; shift 2;;
      --fix)     FIX=1; shift 1;;
      --remove)  ORPH_REMOVE=1; shift 1;;
      --no-color) ADM_COLOR=0; shift 1;;
      --) shift; break;;
      *) break;;
    esac
  done
  printf "%s\0" "$@"
}

require_env(){
  [[ -n "$PROFILE" && -n "$TARGET" ]] || adm_die "Use --profile e --target"
  adm_profile_load "$PROFILE"
  adm_target_env "$TARGET" "$PROFILE"
}

###############################################################################
# Main
###############################################################################
main(){
  adm_load_conf
  local cmd="${1:-}"; shift || true

  case "$cmd" in
    init)
      adm_init_tree
      adm_ok "Estrutura pronta em $ADM_ROOT"
      adm_ok "Edite config em: $ADM_CONF"
      ;;

    sync)
      adm_cmd_sync
      ;;

    build)
      eval "set -- \"\$(parse_common \"\$@\")\""
      require_env
      [[ $# -ge 1 ]] || adm_die "build exige pacotes: cat/name-ver ..."

      mapfile -t files < <(adm_resolve_deps "$@")
      adm_info "Ordem de build:"
      local f
      for f in "${files[@]}"; do
        adm_pkg_load "$f"
        echo "  - $(adm_pkg_id)"
      done

      for f in "${files[@]}"; do
        adm_pkg_build "$f"
      done
      ;;

    install)
      eval "set -- \"\$(parse_common \"\$@\")\""
      require_env
      [[ $# -ge 1 ]] || adm_die "install exige pacotes: cat/name-ver ..."

      mapfile -t files < <(adm_resolve_deps "$@")
      adm_info "Ordem de install:"
      local f
      for f in "${files[@]}"; do
        adm_pkg_load "$f"
        echo "  - $(adm_pkg_id)"
      done

      for f in "${files[@]}"; do
        adm_pkg_install "$f"
      done
      ;;

    remove)
      eval "set -- \"\$(parse_common \"\$@\")\""
      require_env
      [[ $# -ge 1 ]] || adm_die "remove exige pacotes: cat/name-ver ..."
      # Remove em ordem reversa do que foi passado
      local -a pkgs=("$@")
      local i
      for ((i=${#pkgs[@]}-1; i>=0; i--)); do
        adm_pkg_remove "${pkgs[$i]}"
      done
      ;;

    world)
      local op="${1:-}"; shift || true
      case "$op" in
        add)    [[ $# -ge 1 ]] || adm_die "world add <cat/name-ver>"; adm_world_add "$1";;
        remove) [[ $# -ge 1 ]] || adm_die "world remove <cat/name-ver>"; adm_world_remove "$1";;
        list)   adm_world_list;;
        *) adm_die "Uso: world add|remove|list";;
      esac
      ;;

    orphans)
      eval "set -- \"\$(parse_common \"\$@\")\""
      require_env
      adm_info "Órfãos (instalados mas não necessários ao world):"
      mapfile -t orph < <(adm_orphans_list)
      if [[ "${#orph[@]}" -eq 0 ]]; then
        adm_ok "Nenhum órfão encontrado."
        exit 0
      fi
      printf "  - %s\n" "${orph[@]}"
      if [[ "$ORPH_REMOVE" -eq 1 ]]; then
        adm_warn "Removendo órfãos..."
        # remove em ordem reversa alfabética (heurística); para perfeito, exigiria grafo reverso total.
        local -a rev=("${orph[@]}")
        local j
        for ((j=${#rev[@]}-1; j>=0; j--)); do
          adm_pkg_remove "${rev[$j]}"
        done
      fi
      ;;

    clean)
      adm_cmd_clean
      ;;

    check)
      eval "set -- \"\$(parse_common \"\$@\")\""
      require_env
      adm_check "$FIX"
      ;;

    search)
      [[ $# -ge 1 ]] || adm_die "Uso: search <texto>"
      adm_cmd_search "$*"
      ;;

    info)
      [[ $# -eq 1 ]] || adm_die "Uso: info <cat/name-ver>"
      adm_cmd_info "$1"
      ;;

    deps)
      [[ $# -eq 1 ]] || adm_die "Uso: deps <cat/name-ver>"
      adm_cmd_deps "$1"
      ;;

    ""|-h|--help)
      usage
      ;;

    *)
      adm_die "Comando inválido: $cmd (use --help)"
      ;;
  esac
}

main "$@"
