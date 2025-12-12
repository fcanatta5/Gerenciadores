#!/usr/bin/env bash
#
# adm_doctor.sh — prevenção, diagnóstico e manutenção para adm.sh
#
# Uso:
#   ./adm_doctor.sh                 # apenas checagens (read-only)
#   ./adm_doctor.sh --fix           # aplica correções seguras
#   ./adm_doctor.sh --fix --clean   # (opcional) limpeza segura de caches/builds
#
# Alinhado ao adm.sh:
# - ADM_ROOT padrão: /opt/adm
# - Profiles: $ADM_ROOT/profiles/<profile>/rootfs + env.sh
# - Receitas: $ADM_ROOT/packages/<categoria>/<nome>-<versao>.sh
# - DB: $ADM_ROOT/db/<profile>/<PKG_NAME>.meta + <PKG_NAME>.manifest
#
set -euo pipefail
set -o errtrace

ADM_ROOT="${ADM_ROOT:-/opt/adm}"

ADM_DB_DIR="${ADM_ROOT}/db"
ADM_PKG_DIR="${ADM_ROOT}/packages"
ADM_PROFILE_DIR="${ADM_ROOT}/profiles"
ADM_BIN_CACHE="${ADM_ROOT}/binaries"
ADM_SRC_CACHE="${ADM_ROOT}/sources"
ADM_BUILD_DIR="${ADM_ROOT}/build"
ADM_LOG_DIR="${ADM_ROOT}/log"
CURRENT_PROFILE_FILE="${ADM_ROOT}/current_profile"
LOCK_FILE="${ADM_ROOT}/adm.lock"

# flags
DO_FIX=0
DO_CLEAN=0
VERBOSE=0

# counters
errors=0
warnings=0
fixes=0

# colors
if [ -t 1 ]; then
  RED="\033[31m"
  YELLOW="\033[33m"
  GREEN="\033[32m"
  BLUE="\033[34m"
  RESET="\033[0m"
else
  RED=""; YELLOW=""; GREEN=""; BLUE=""; RESET=""
fi

ok()    { echo -e "${GREEN}[ OK ]${RESET} $*"; }
info()  { echo -e "${BLUE}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; warnings=$((warnings+1)); }
fail()  { echo -e "${RED}[FAIL]${RESET} $*"; errors=$((errors+1)); }
fixed() { echo -e "${GREEN}[FIX ]${RESET} $*"; fixes=$((fixes+1)); }

section() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

usage() {
  cat <<EOF
adm_doctor.sh — diagnóstico e manutenção preventiva para adm.sh

Uso:
  adm_doctor.sh [--fix] [--clean] [--verbose]

Opções:
  --fix       Aplica correções seguras e determinísticas
  --clean     Com --fix: também remove builds órfãos e caches temporários (conservador)
  --verbose   Saída mais detalhada

Variáveis:
  ADM_ROOT=/opt/adm (default)

Retorno:
  0  se não houver FAIL
  1  se houver FAIL

EOF
}

# -----------------------------------------------------------------------------
# Parse args
# -----------------------------------------------------------------------------
for a in "${@:-}"; do
  case "$a" in
    --fix) DO_FIX=1 ;;
    --clean) DO_CLEAN=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "Arg desconhecida: $a" >&2; usage; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# Safety: lock (avoid concurrent install/build while fixing)
# -----------------------------------------------------------------------------
acquire_lock() {
  mkdir -p "$ADM_ROOT"
  exec 9>"$LOCK_FILE"
  if command -v flock >/dev/null 2>&1; then
    flock -n 9 || fail "Outra instância do adm está rodando (lock: $LOCK_FILE). Feche antes de rodar --fix."
  else
    # fallback lockdir
    local lockdir="${LOCK_FILE}.d"
    if ! mkdir "$lockdir" 2>/dev/null; then
      fail "Outra instância do adm está rodando (lockdir: $lockdir). Feche antes de rodar --fix."
    fi
    trap 'rmdir "'"$lockdir"'" 2>/dev/null || true' EXIT
  fi
}

if [ "$DO_FIX" -eq 1 ]; then
  acquire_lock
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

ensure_dir() {
  local d="$1"
  if [ -d "$d" ]; then
    return 0
  fi
  if [ "$DO_FIX" -eq 1 ]; then
    mkdir -p "$d"
    fixed "Criado diretório: $d"
  else
    fail "Diretório ausente: $d"
  fi
}

ensure_file_with_content() {
  local f="$1"
  local content="$2"
  if [ -f "$f" ]; then
    return 0
  fi
  if [ "$DO_FIX" -eq 1 ]; then
    printf '%s\n' "$content" > "$f"
    fixed "Criado arquivo: $f"
  else
    fail "Arquivo ausente: $f"
  fi
}

chmod_if_needed() {
  local mode="$1" path="$2"
  if [ ! -e "$path" ]; then
    warn "Não existe para chmod: $path"
    return 0
  fi
  local current
  current="$(stat -c %a "$path" 2>/dev/null || echo unknown)"
  if [ "$current" = "$mode" ]; then
    return 0
  fi
  if [ "$DO_FIX" -eq 1 ]; then
    chmod "$mode" "$path"
    fixed "chmod $mode em $path (antes: $current)"
  else
    warn "$path permissões $current; esperado $mode"
  fi
}

# Extract (category, name, version) from recipe filename robustly:
# - split at first '-' where next char is digit (same logic as adm.sh corrigido)
recipe_parse_path() {
  local path="$1"
  local category base name ver i ch next
  category="$(basename "$(dirname "$path")")"
  base="${path##*/}"
  base="${base%.sh}"

  name="$base"
  ver=""
  for ((i=0; i<${#base}; i++)); do
    ch="${base:i:1}"
    next="${base:i+1:1}"
    if [ "$ch" = "-" ] && [[ "$next" =~ [0-9] ]]; then
      name="${base:0:i}"
      ver="${base:i+1}"
      break
    fi
  done
  printf '%s|%s|%s\n' "$category" "$name" "$ver"
}

# Detect profile type heuristically by profile name
profile_kind() {
  local p="$1"
  case "$p" in
    bootstrap) echo bootstrap ;;
    musl) echo musl ;;
    glibc) echo glibc ;;
    *) echo generic ;;
  esac
}

write_env_for_profile() {
  local prof="$1"
  local env_file="$2"
  local kind
  kind="$(profile_kind "$prof")"

  if [ "$kind" = "bootstrap" ]; then
    cat > "$env_file" <<'EOF'
# env.sh - profile "bootstrap"
# NÃO exporta CC/CXX/LD do target se ainda não existirem (evita quebrar bootstrap).
export LFS_TGT="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"
export PATH="${ADM_CURRENT_ROOTFS}/tools/bin:${ADM_CURRENT_ROOTFS}/usr/bin:${ADM_CURRENT_ROOTFS}/bin:${PATH}"
export CFLAGS="${CFLAGS:-"-O2 -pipe"}"
export CXXFLAGS="${CXXFLAGS:-"${CFLAGS}"}"
export PKG_CONFIG_PATH=
if [ -x "${ADM_CURRENT_ROOTFS}/tools/bin/${LFS_TGT}-gcc" ]; then
  export CC="${LFS_TGT}-gcc"
  export CXX="${LFS_TGT}-g++"
  export AR="${LFS_TGT}-ar"
  export AS="${LFS_TGT}-as"
  export RANLIB="${LFS_TGT}-ranlib"
  export LD="${LFS_TGT}-ld"
  export STRIP="${LFS_TGT}-strip"
else
  unset CC CXX AR AS RANLIB LD STRIP 2>/dev/null || true
fi
EOF
  elif [ "$kind" = "musl" ]; then
    cat > "$env_file" <<'EOF'
# env.sh - profile "musl"
export MUSL_TGT="${MUSL_TGT:-"$(uname -m)-lfs-linux-musl"}"
export PATH="${ADM_CURRENT_ROOTFS}/tools/bin:${ADM_CURRENT_ROOTFS}/usr/bin:${ADM_CURRENT_ROOTFS}/bin:${PATH}"
export CFLAGS="${CFLAGS:-"-O2 -pipe"}"
export CXXFLAGS="${CXXFLAGS:-"${CFLAGS}"}"
export PKG_CONFIG_PATH=
if [ -x "${ADM_CURRENT_ROOTFS}/tools/bin/${MUSL_TGT}-gcc" ]; then
  export CC="${MUSL_TGT}-gcc"
  export CXX="${MUSL_TGT}-g++"
  export AR="${MUSL_TGT}-ar"
  export AS="${MUSL_TGT}-as"
  export RANLIB="${MUSL_TGT}-ranlib"
  export LD="${MUSL_TGT}-ld"
  export STRIP="${MUSL_TGT}-strip"
else
  unset CC CXX AR AS RANLIB LD STRIP 2>/dev/null || true
fi
EOF
  elif [ "$kind" = "glibc" ]; then
    cat > "$env_file" <<'EOF'
# env.sh - profile "glibc"
export PATH="${ADM_CURRENT_ROOTFS}/tools/bin:${ADM_CURRENT_ROOTFS}/usr/bin:${ADM_CURRENT_ROOTFS}/bin:${PATH}"
export CC="${CC:-gcc}"
export CXX="${CXX:-g++}"
export AR="${AR:-ar}"
export AS="${AS:-as}"
export RANLIB="${RANLIB:-ranlib}"
export LD="${LD:-ld}"
export STRIP="${STRIP:-strip}"
export CFLAGS="${CFLAGS:-"-O2 -pipe"}"
export CXXFLAGS="${CXXFLAGS:-"${CFLAGS}"}"
EOF
  else
    cat > "$env_file" <<'EOF'
# env.sh - profile genérico
export PATH="${ADM_CURRENT_ROOTFS}/tools/bin:${ADM_CURRENT_ROOTFS}/usr/bin:${ADM_CURRENT_ROOTFS}/bin:${PATH}"
export CC="${CC:-gcc}"
export CXX="${CXX:-g++}"
export AR="${AR:-ar}"
export AS="${AS:-as}"
export RANLIB="${RANLIB:-ranlib}"
export LD="${LD:-ld}"
export STRIP="${STRIP:-strip}"
export CFLAGS="${CFLAGS:-"-O2 -pipe"}"
export CXXFLAGS="${CXXFLAGS:-"${CFLAGS}"}"
EOF
  fi
}

# Attempt to rebuild manifest:
# - If manifest missing, but meta exists: we cannot know exact installed files.
#   We provide a conservative manifest with *directories* known from the recipe install prefixes.
#   This is not perfect but helps detect/track; we also warn loudly.
rebuild_manifest_conservative() {
  local profile="$1" pkg="$2" meta="$3" manifest="$4"

  # shellcheck disable=SC1090
  source "$meta"

  local rootfs="${ROOTFS:-}"
  if [ -z "$rootfs" ] || [ ! -d "$rootfs" ]; then
    return 1
  fi

  # Conservative heuristic:
  # If category/toolchain and package is known toolchain, include likely paths.
  # Otherwise, cannot safely infer.
  local paths=()
  case "$pkg" in
    linux-headers)
      paths+=("usr/include")
      ;;
    binutils-bootstrap|gcc-bootstrap)
      paths+=("tools/bin" "tools/lib" "tools/include" "tools/libexec")
      ;;
    glibc|musl)
      paths+=("lib" "lib64" "usr/lib" "usr/include" "etc")
      ;;
    *)
      return 2
      ;;
  esac

  # write manifest with all files under those paths
  : > "$manifest"
  local p
  for p in "${paths[@]}"; do
    if [ -e "$rootfs/$p" ]; then
      (cd "$rootfs" && find "$p" -type f -o -type l 2>/dev/null) >> "$manifest" || true
    fi
  done

  return 0
}

# -----------------------------------------------------------------------------
# 1. Base structure checks
# -----------------------------------------------------------------------------
section "1) Estrutura base do ADM"

ensure_dir "$ADM_ROOT"
ensure_dir "$ADM_PKG_DIR"
ensure_dir "$ADM_PROFILE_DIR"
ensure_dir "$ADM_DB_DIR"
ensure_dir "$ADM_SRC_CACHE"
ensure_dir "$ADM_BIN_CACHE"
ensure_dir "$ADM_BUILD_DIR"
ensure_dir "$ADM_LOG_DIR"

# current_profile default
if [ ! -f "$CURRENT_PROFILE_FILE" ]; then
  if [ "$DO_FIX" -eq 1 ]; then
    echo "glibc" > "$CURRENT_PROFILE_FILE"
    fixed "Criado current_profile com valor 'glibc'"
  else
    warn "current_profile ausente (adm.sh assumirá glibc)"
  fi
else
  cpv="$(cat "$CURRENT_PROFILE_FILE" 2>/dev/null || true)"
  [ -n "$cpv" ] || warn "current_profile existe mas está vazio"
fi

ok "Estrutura base OK"

# -----------------------------------------------------------------------------
# 2. Profiles checks + fix
# -----------------------------------------------------------------------------
section "2) Profiles"

profiles_found=0
shopt -s nullglob
for p in "$ADM_PROFILE_DIR"/*; do
  [ -d "$p" ] || continue
  profiles_found=1
  prof="$(basename "$p")"
  rootfs="$p/rootfs"
  envsh="$p/env.sh"

  info "Profile: $prof"

  # rootfs dir
  if [ ! -d "$rootfs" ]; then
    if [ "$DO_FIX" -eq 1 ]; then
      mkdir -p "$rootfs"
      fixed "  Criado rootfs: $rootfs"
    else
      fail "  rootfs ausente: $rootfs"
      continue
    fi
  fi

  # minimal rootfs layout (safe to create)
  for d in bin sbin lib lib64 usr usr/bin usr/sbin usr/lib usr/include etc var tmp dev proc sys run home root tools; do
    if [ ! -d "$rootfs/$d" ]; then
      if [ "$DO_FIX" -eq 1 ]; then
        mkdir -p "$rootfs/$d"
        fixed "  Criado: $rootfs/$d"
      else
        warn "  Ausente: $rootfs/$d"
      fi
    fi
  done

  # /tmp perms
  chmod_if_needed 1777 "$rootfs/tmp"

  # db per profile
  if [ ! -d "$ADM_DB_DIR/$prof" ]; then
    if [ "$DO_FIX" -eq 1 ]; then
      mkdir -p "$ADM_DB_DIR/$prof"
      fixed "  Criado DB do profile: $ADM_DB_DIR/$prof"
    else
      warn "  DB do profile ausente: $ADM_DB_DIR/$prof"
    fi
  fi

  # env.sh
  if [ ! -f "$envsh" ]; then
    if [ "$DO_FIX" -eq 1 ]; then
      write_env_for_profile "$prof" "$envsh"
      fixed "  Criado env.sh: $envsh"
    else
      warn "  env.sh ausente: $envsh"
    fi
  else
    # sanity: env.sh deve ser sourceável
    if ! bash -n "$envsh" >/dev/null 2>&1; then
      fail "  env.sh tem erro de sintaxe: $envsh"
    else
      ok "  env.sh OK"
    fi
  fi
done
shopt -u nullglob

[ "$profiles_found" -eq 1 ] || fail "Nenhum profile encontrado em $ADM_PROFILE_DIR"

# -----------------------------------------------------------------------------
# 3. Recipes checks (semantic)
# -----------------------------------------------------------------------------
section "3) Receitas (packages) — validação"

recipes=0
bad_recipes=0

# Basic tools required to even validate recipes safely
if ! command -v bash >/dev/null 2>&1; then
  fail "bash não encontrado (impossível validar receitas)"
fi

shopt -s nullglob
for recipe in "$ADM_PKG_DIR"/*/*.sh; do
  [ -f "$recipe" ] || continue
  recipes=$((recipes+1))
  rel="${recipe#$ADM_ROOT/}"

  # filename parse sanity
  parsed="$(recipe_parse_path "$recipe")"
  catg="${parsed%%|*}"
  rest="${parsed#*|}"
  name="${rest%%|*}"
  ver="${rest##*|}"

  if [ -z "$name" ] || [ -z "$ver" ]; then
    warn "Receita com nome/versão não detectados pelo padrão: $rel"
  fi

  # Validate in subshell to avoid polluting environment.
  (
    set -euo pipefail
    unset PKG_NAME PKG_VERSION PKG_CATEGORY PKG_DESC PKG_DEPENDS PKG_LIBC
    unset -f build pre_build post_build pre_install post_install 2>/dev/null || true
    # shellcheck disable=SC1090
    source "$recipe"
    [ -n "${PKG_NAME:-}" ] || exit 10
    [ -n "${PKG_VERSION:-}" ] || exit 11
    type build >/dev/null 2>&1 || exit 12
  ) || {
    fail "Receita inválida (faltam variáveis/build): $rel"
    bad_recipes=$((bad_recipes+1))
  }

  # Optional: ensure PKG_CATEGORY matches folder (warning only)
  (
    set -euo pipefail
    unset PKG_CATEGORY PKG_NAME PKG_VERSION
    # shellcheck disable=SC1090
    source "$recipe"
    if [ -n "${PKG_CATEGORY:-}" ] && [ "${PKG_CATEGORY}" != "$catg" ]; then
      exit 21
    fi
  ) || warn "PKG_CATEGORY não bate com categoria do path: $rel (path=$catg)"

done
shopt -u nullglob

if [ "$recipes" -eq 0 ]; then
  warn "Nenhuma receita encontrada em $ADM_PKG_DIR"
else
  [ "$bad_recipes" -eq 0 ] && ok "Receitas OK: $recipes"
fi

# -----------------------------------------------------------------------------
# 4. DB + Manifests checks + fix
# -----------------------------------------------------------------------------
section "4) DB e Manifests"

db_profiles_found=0
shopt -s nullglob
for d in "$ADM_DB_DIR"/*; do
  [ -d "$d" ] || continue
  db_profiles_found=1
  prof="$(basename "$d")"
  info "DB profile: $prof"

  # Validate each meta
  for meta in "$d"/*.meta; do
    [ -f "$meta" ] || continue
    pkg="$(basename "$meta" .meta)"
    manifest="$d/$pkg.manifest"

    # load meta
    if ! bash -n "$meta" >/dev/null 2>&1; then
      fail "  meta com sintaxe inválida: $meta"
      continue
    fi

    # shellcheck disable=SC1090
    source "$meta"
    [ -n "${PKG_NAME:-}" ] || fail "  $pkg.meta sem PKG_NAME"
    [ -n "${VERSION:-}" ] || fail "  $pkg.meta sem VERSION"
    [ -n "${ROOTFS:-}" ] || fail "  $pkg.meta sem ROOTFS"

    if [ -n "${ROOTFS:-}" ] && [ ! -d "$ROOTFS" ]; then
      fail "  $pkg.meta aponta para ROOTFS inexistente: $ROOTFS"
    fi

    if [ ! -f "$manifest" ]; then
      warn "  Manifest ausente: $manifest"
      if [ "$DO_FIX" -eq 1 ]; then
        # Attempt conservative rebuild
        if rebuild_manifest_conservative "$prof" "$pkg" "$meta" "$manifest"; then
          fixed "  Manifest reconstruído (conservador) para $pkg -> $manifest"
          warn "  Manifest conservador pode não refletir todos os arquivos (reinstalar o pacote é o ideal)."
        else
          warn "  Não foi possível reconstruir manifest de $pkg com segurança. Sugestão: reinstale o pacote."
        fi
      fi
    else
      # quick manifest sanity
      if [ ! -s "$manifest" ]; then
        warn "  Manifest vazio: $manifest (pode indicar pacote vazio ou registro quebrado)"
      fi
    fi
  done
done
shopt -u nullglob

[ "$db_profiles_found" -eq 1 ] || warn "Nenhum DB de profile encontrado em $ADM_DB_DIR (ainda não instalou pacotes?)"

# -----------------------------------------------------------------------------
# 5. Toolchain health (per profile)
# -----------------------------------------------------------------------------
section "5) Saúde do toolchain (por profile)"

shopt -s nullglob
for p in "$ADM_PROFILE_DIR"/*; do
  [ -d "$p" ] || continue
  prof="$(basename "$p")"
  rootfs="$p/rootfs"

  info "Profile: $prof"

  # binutils presence
  if ls "$rootfs/tools/bin/"*-ld >/dev/null 2>&1; then
    ok "  binutils: OK (ld encontrado em tools/bin)"
  else
    warn "  binutils: ausente em $rootfs/tools/bin (binutils-bootstrap não instalado?)"
  fi

  # gcc presence
  if ls "$rootfs/tools/bin/"*-gcc >/dev/null 2>&1; then
    ok "  gcc: OK (gcc encontrado em tools/bin)"
  else
    warn "  gcc: ausente em $rootfs/tools/bin (gcc-bootstrap não instalado?)"
  fi

  # linux headers presence
  if [ -d "$rootfs/usr/include/linux" ]; then
    ok "  linux-headers: OK ($rootfs/usr/include/linux)"
  else
    warn "  linux-headers: ausente em $rootfs/usr/include/linux"
  fi

  # glibc presence
  if [ -f "$rootfs/lib/libc.so.6" ] || [ -f "$rootfs/lib64/libc.so.6" ]; then
    ok "  glibc: presente (libc.so.6 em /lib ou /lib64)"
  else
    # maybe not expected for all profiles
    if [ "$prof" = "glibc" ]; then
      warn "  glibc: ausente (esperado no profile glibc)"
    else
      info "  glibc: não detectada (ok se profile não for glibc)"
    fi
  fi

  # musl presence
  if ls "$rootfs/lib/ld-musl-*.so.1 >/dev/null 2>&1 || ls "$rootfs/lib64/ld-musl-*.so.1 >/dev/null 2>&1; then
    ok "  musl: loader encontrado"
  else
    if [ "$prof" = "musl" ]; then
      warn "  musl: loader ausente (esperado no profile musl)"
    else
      info "  musl: não detectada (ok se profile não for musl)"
    fi
  fi
done
shopt -u nullglob

# -----------------------------------------------------------------------------
# 6. Caches/build hygiene (optional fix)
# -----------------------------------------------------------------------------
section "6) Higiene de caches/builds"

# sizes (informational)
du_cmd=""
command -v du >/dev/null 2>&1 && du_cmd="du -sh"
if [ -n "$du_cmd" ]; then
  info "Tamanhos:"
  $du_cmd "$ADM_SRC_CACHE" 2>/dev/null || true
  $du_cmd "$ADM_BIN_CACHE" 2>/dev/null || true
  $du_cmd "$ADM_BUILD_DIR" 2>/dev/null || true
fi

if [ "$DO_FIX" -eq 1 ] && [ "$DO_CLEAN" -eq 1 ]; then
  info "Limpando builds órfãos (conservador)..."

  # Remove build dirs that don't match installed pkgs (heuristic):
  # build dir pattern: <PKG_NAME>-<PKG_VERSION>
  # If binary tar exists and package installed, keep; else remove.
  shopt -s nullglob
  for bd in "$ADM_BUILD_DIR"/*; do
    [ -d "$bd" ] || continue
    bn="$(basename "$bd")"
    # if there's a matching binary tar in cache, keep
    if ls "$ADM_BIN_CACHE/${bn}.tar.xz" >/dev/null 2>&1; then
      [ "$VERBOSE" -eq 1 ] && info "  Mantendo build: $bn (binário em cache)"
      continue
    fi
    rm -rf "$bd"
    fixed "Removido build órfão: $bd"
  done
  shopt -u nullglob
else
  info "Para limpeza opcional de builds órfãos: rode com --fix --clean"
fi

# -----------------------------------------------------------------------------
# Summary + exit code
# -----------------------------------------------------------------------------
section "Resumo"

echo "Fixes aplicados : $fixes"
echo "Warnings        : $warnings"
echo "Failures        : $errors"

if [ "$errors" -eq 0 ]; then
  ok "Sistema ADM aparentemente saudável."
  exit 0
else
  fail "Problemas detectados. Corrija os FAIL (ou rode com --fix, se aplicável)."
  exit 1
fi
