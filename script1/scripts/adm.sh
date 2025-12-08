#!/usr/bin/env bash
# ADM - Simple source-based package/build manager

set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Cores e logging
###############################################################################
if [[ -t 2 ]]; then
  _C_RESET="\033[0m"
  _C_BLUE="\033[34m"
  _C_YELLOW="\033[33m"
  _C_RED="\033[31m"
  _C_GREEN="\033[32m"
else
  _C_RESET=""
  _C_BLUE=""
  _C_YELLOW=""
  _C_RED=""
  _C_GREEN=""
fi

log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()  { printf '%s %b[INFO ]%b %s\n'  "$(log_ts)" "${_C_BLUE}"   "${_C_RESET}" "$*" >&2; }
log_warn()  { printf '%s %b[WARN ]%b %s\n'  "$(log_ts)" "${_C_YELLOW}" "${_C_RESET}" "$*" >&2; }
log_error() { printf '%s %b[ERROR]%b %s\n'  "$(log_ts)" "${_C_RED}"    "${_C_RESET}" "$*" >&2; }
log_ok()    { printf '%s %b[ OK  ]%b %s\n'  "$(log_ts)" "${_C_GREEN}"  "${_C_RESET}" "$*" >&2; }

run_cmd() {
  log_info "Executando: $*"
  "$@"
  local rc=$?
  if (( rc != 0 )); then
    log_error "Comando falhou (exit=${rc}): $*"
    return "$rc"
  fi
}

###############################################################################
# Configuração de diretórios
###############################################################################
ADM_ROOT="${ADM_ROOT:-/opt/adm}"

# Diretório de receitas
ADM_PACKAGES_DIR="${ADM_PACKAGES_DIR:-${ADM_ROOT}/packages}"

# Build e estado
ADM_BUILD_ROOT="${ADM_BUILD_ROOT:-${ADM_ROOT}/build}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_ROOT}/log}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_ROOT}/db}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"

# Cache (sources)
ADM_CACHE_DIR="${ADM_CACHE_DIR:-${ADM_ROOT}/cache}"

# Cache binário (tarballs)
ADM_PKG_OUTPUT_DIR="${ADM_PKG_OUTPUT_DIR:-${ADM_ROOT}/pkgs}"

# Rootfs alvo
ADM_ROOTFS="${ADM_ROOTFS:-${ADM_ROOT}/rootfs}"

# Toolchain e perfil
ADM_TOOLCHAIN_PREFIX="${ADM_TOOLCHAIN_PREFIX:-${ADM_ROOT}/toolchain}"
ADM_PROFILE="${ADM_PROFILE:-glibc}"
ADM_USE_NATIVE="${ADM_USE_NATIVE:-0}"

# Controle de cache e strip
ADM_ENABLE_BIN_CACHE="${ADM_ENABLE_BIN_CACHE:-1}"
ADM_STRIP_BINARIES="${ADM_STRIP_BINARIES:-1}"

# Paralelismo
ADM_JOBS="${ADM_JOBS:-}"

mkdir -p \
  "${ADM_PACKAGES_DIR}" \
  "${ADM_BUILD_ROOT}" \
  "${ADM_CACHE_DIR}" \
  "${ADM_PKG_OUTPUT_DIR}" \
  "${ADM_LOG_DIR}" \
  "${ADM_DB_DIR}" \
  "${ADM_STATE_DIR}" \
  "${ADM_ROOTFS}"

###############################################################################
# Checagem de dependências
###############################################################################
check_dependencies() {
  local required=(
    git tar patch rsync find xargs file
  )
  local at_least_one_downloader=0

  for cmd in curl wget; do
    if command -v "$cmd" >/dev/null 2>&1; then
      at_least_one_downloader=1
      break
    fi
  done

  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_error "Comando obrigatório não encontrado: ${cmd}"
      exit 1
    fi
  done

  if (( at_least_one_downloader == 0 )); then
    log_error "Nem curl nem wget encontrados; é necessário pelo menos um."
    exit 1
  fi

  if ! command -v zstd >/dev/null 2>&1; then
    log_warn "zstd não encontrado; cache binário não funcionará com compressão. (recomendado instalar zstd)"
  fi
}

###############################################################################
# Perfil / toolchain / flags
###############################################################################
setup_profiles() {
  ADM_PROFILE="${ADM_PROFILE:-glibc}"
  ADM_TARGET_ARCH="${ADM_TARGET_ARCH:-x86_64}"

  case "${ADM_PROFILE}" in
    glibc|aggressive) ADM_TARGET_LIBC="${ADM_TARGET_LIBC:-glibc}" ;;
    musl)             ADM_TARGET_LIBC="${ADM_TARGET_LIBC:-musl}"  ;;
    *)
      log_error "[setup_profiles] Perfil desconhecido: ${ADM_PROFILE}"
      exit 1
      ;;
  esac

  if [[ -z "${TARGET_TRIPLET:-}" ]]; then
    case "${ADM_TARGET_LIBC}" in
      glibc) TARGET_TRIPLET="${ADM_TARGET_ARCH}-pc-linux-gnu" ;;
      musl)  TARGET_TRIPLET="${ADM_TARGET_ARCH}-unknown-linux-musl" ;;
    esac
  fi

  ADM_SYSROOT="${ADM_SYSROOT:-${ADM_ROOTFS}}"

  SYS_INC_DIR="${ADM_SYSROOT}/usr/include"
  SYS_LIB_DIR="${ADM_SYSROOT}/usr/lib"
  SYS_LIB64_DIR="${ADM_SYSROOT}/usr/lib64"

  CFLAGS_COMMON="-pipe"
  CXXFLAGS_COMMON="-pipe"
  CPPFLAGS_COMMON="-I${SYS_INC_DIR}"
  LDFLAGS_COMMON="-L${SYS_LIB_DIR} -L${SYS_LIB64_DIR}"

  case "${ADM_PROFILE}" in
    glibc)
      CFLAGS_OPT="-O2"
      CXXFLAGS_OPT="-O2"
      LDFLAGS_OPT="-Wl,-O1,-z,relro,-z,now -Wl,--as-needed"
      ;;
    musl)
      CFLAGS_OPT="-O2 -fstack-protector-strong"
      CXXFLAGS_OPT="-O2 -fstack-protector-strong"
      LDFLAGS_OPT="-Wl,-O1,-z,relro,-z,now -Wl,--as-needed"
      ;;
    aggressive)
      CFLAGS_OPT="-O3 -march=native -mtune=native -fomit-frame-pointer -flto=auto"
      CXXFLAGS_OPT="-O3 -march=native -mtune=native -fomit-frame-pointer -flto=auto"
      LDFLAGS_OPT="-flto=auto -Wl,-O2,-z,relro,-z,now -Wl,--as-needed"
      ;;
  esac

  export TARGET_TRIPLET
  export CFLAGS="${CFLAGS_COMMON} ${CFLAGS_OPT}"
  export CXXFLAGS="${CXXFLAGS_COMMON} ${CXXFLAGS_OPT}"
  export CPPFLAGS="${CPPFLAGS_COMMON}"
  export LDFLAGS="${LDFLAGS_COMMON} ${LDFLAGS_OPT}"

  if [[ "${ADM_USE_NATIVE}" = "1" ]]; then
    export CC="${CC:-gcc}"
    export CXX="${CXX:-g++}"
    export AR="${AR:-ar}"
    export RANLIB="${RANLIB:-ranlib}"
    export LD="${LD:-ld}"
    export AS="${AS:-as}"
    export STRIP="${STRIP:-strip}"
  else
    export CC="${CC:-${ADM_TOOLCHAIN_PREFIX}/bin/${TARGET_TRIPLET}-gcc}"
    export CXX="${CXX:-${ADM_TOOLCHAIN_PREFIX}/bin/${TARGET_TRIPLET}-g++}"
    export AR="${AR:-${ADM_TOOLCHAIN_PREFIX}/bin/${TARGET_TRIPLET}-ar}"
    export RANLIB="${RANLIB:-${ADM_TOOLCHAIN_PREFIX}/bin/${TARGET_TRIPLET}-ranlib}"
    export LD="${LD:-${ADM_TOOLCHAIN_PREFIX}/bin/${TARGET_TRIPLET}-ld}"
    export AS="${AS:-${ADM_TOOLCHAIN_PREFIX}/bin/${TARGET_TRIPLET}-as}"
    export STRIP="${STRIP:-${ADM_TOOLCHAIN_PREFIX}/bin/${TARGET_TRIPLET}-strip}"
  fi

  export PKG_CONFIG="${PKG_CONFIG:-${ADM_TOOLCHAIN_PREFIX}/bin/${TARGET_TRIPLET}-pkg-config}"
  if [[ ! -x "${PKG_CONFIG}" ]]; then
    PKG_CONFIG="pkg-config"
  fi
  export PKG_CONFIG

  export PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR:-${SYS_LIB_DIR}/pkgconfig:${SYS_LIB64_DIR}/pkgconfig}"
  export PKG_CONFIG_SYSROOT_DIR="${PKG_CONFIG_SYSROOT_DIR:-${ADM_SYSROOT}}"

  if [[ "${ADM_USE_NATIVE}" != "1" ]]; then
    case ":$PATH:" in
      *:"${ADM_TOOLCHAIN_PREFIX}/bin":*) ;;
      *) export PATH="${ADM_TOOLCHAIN_PREFIX}/bin:${PATH}" ;;
    esac
  fi
}

###############################################################################
# Usage / argumentos globais
###############################################################################
usage() {
  cat <<EOF
Uso: $(basename "$0") [opções] <comando> [args...]

Opções globais:
  -P, --profile PERFIL      Perfil de build (glibc, musl, aggressive)
  -n, --dry-run             Não executar comandos, apenas simular

Comandos principais:
  update                    Atualiza receitas a partir do repositório git
  build   <cat/pkg|pkg>     Constrói (e instala no rootfs) um pacote
  install <cat/pkg|pkg>     Alias para build
  uninstall <cat/pkg|pkg>   Remove um pacote (com resolução reversa de deps)
  rebuild [world|pkg]       Rebuild do sistema inteiro ou de um pacote
  info   <cat/pkg|pkg>      Mostra informações do pacote
  search <padrão>           Procura por pacotes pelo nome
  list-installed            Lista pacotes instalados
  graph-deps <pkg>          Mostra ordem de build por dependências
  dry-run <...>             Executa um comando em dry-run temporário

Exemplos:
  ADM_PROFILE=aggressive $(basename "$0") build core/gzip
  $(basename "$0") -P musl build gzip
  $(basename "$0") uninstall core/gzip

EOF
}

parse_global_args() {
  ADM_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -P|--profile)
        if [[ $# -lt 2 ]]; then
          log_error "Faltando argumento para $1"
          exit 1
        fi
        ADM_PROFILE="$2"
        shift 2
        ;;
      -n|--dry-run)
        ADM_DRY_RUN=1
        shift
        ;;
      --)
        shift
        ADM_ARGS+=("$@")
        break
        ;;
      -*)
        log_error "Opção desconhecida: $1"
        usage
        exit 1
        ;;
      *)
        ADM_ARGS+=("$@")
        break
        ;;
    esac
  done
}

###############################################################################
# Helpers de pacote / caminhos
###############################################################################
normalize_pkg_name() {
  local input="$1"

  if [[ "$input" == */* ]]; then
    echo "$input"
    return 0
  fi

  if [[ ! -d "${ADM_PACKAGES_DIR}" ]]; then
    log_error "Diretório de pacotes não existe: ${ADM_PACKAGES_DIR}"
    exit 1
  fi

  local matches=()
  while IFS= read -r d; do
    matches+=("$d")
  done < <(find "${ADM_PACKAGES_DIR}" -mindepth 2 -maxdepth 2 -type d -name "$input" 2>/dev/null | sort)

  if (( ${#matches[@]} == 1 )); then
    local abs="${matches[0]}"
    echo "${abs#${ADM_PACKAGES_DIR}/}"
    return 0
  elif (( ${#matches[@]} == 0 )); then
    log_error "Pacote '$input' não encontrado em ${ADM_PACKAGES_DIR}"
    exit 1
  else
    log_error "Nome de pacote ambíguo para '$input'. Use cat/pkg:"
    printf '  %s\n' "${matches[@]#${ADM_PACKAGES_DIR}/}" >&2
    exit 1
  fi
}

pkg_script_path() {
  local full="$1"
  echo "${ADM_PACKAGES_DIR}/${full}/build.sh"
}

pkg_hook_path() {
  local full="$1"
  local hook="$2"
  echo "${ADM_PACKAGES_DIR}/${full}/hooks/${hook}.sh"
}

pkg_patch_path() {
  local full="$1"
  echo "${ADM_PACKAGES_DIR}/${full}/patches"
}

pkg_db_dir() {
  local full="$1"
  echo "${ADM_DB_DIR}/${full}"
}

pkg_state_dir() {
  local full="$1"
  echo "${ADM_STATE_DIR}/${full}"
}

pkg_build_dir() {
  local full="$1"
  echo "${ADM_BUILD_ROOT}/build/${full}"
}

pkg_destdir() {
  local full="$1"
  echo "${ADM_BUILD_ROOT}/dest/${full}"
}

pkg_tarball_path() {
  local full="$1"
  local version="$2"
  local cat="${full%/*}"
  local name="${full##*/}"
  local profile="${ADM_PROFILE:-default}"
  local triplet="${TARGET_TRIPLET:-native}"
  echo "${ADM_PKG_OUTPUT_DIR}/${cat}/${name}-${version}-${profile}-${triplet}.tar.zst"
}

###############################################################################
# Metadata do pacote
###############################################################################
load_pkg_metadata() {
  local full="$1"
  local script
  script=$(pkg_script_path "$full")

  if [[ ! -f "$script" ]]; then
    log_error "Arquivo de receita não encontrado: ${script}"
    exit 1
  fi

  # Limpa PKG_* anteriores
  while IFS= read -r v; do
    unset "$v"
  done < <(compgen -v PKG_ || true)

  # Defaults
  PKG_NAME=""
  PKG_VERSION=""
  PKG_URL=""
  PKG_URLS=()
  PKG_DEPENDS=()

  # shellcheck source=/dev/null
  # (Receitas são consideradas confiáveis)
  source "$script"

  if [[ -z "${PKG_NAME:-}" || -z "${PKG_VERSION:-}" ]]; then
    log_error "Receita ${script} não definiu PKG_NAME/PKG_VERSION corretamente"
    exit 1
  fi

  if ! declare -p PKG_DEPENDS >/dev/null 2>&1; then
    PKG_DEPENDS=()
  fi

  if ! declare -p PKG_URLS >/dev/null 2>&1; then
    if [[ -n "${PKG_URL:-}" ]]; then
      PKG_URLS=("${PKG_URL}")
    else
      PKG_URLS=()
    fi
  fi
}

###############################################################################
# Download / cache de sources
###############################################################################
is_git_url() {
  local url="$1"
  [[ "$url" =~ ^git:// ]] || [[ "$url" =~ \.git$ ]] || [[ "$url" =~ ^ssh:// ]]
}

verify_checksum() {
  local file="$1"
  local sha256="$2"
  local md5="$3"

  if [[ -n "$sha256" ]]; then
    if ! command -v sha256sum >/dev/null 2>&1; then
      log_error "sha256sum não encontrado para verificar checksum."
      exit 1
    fi
    echo "${sha256}  ${file}" | sha256sum -c -
  elif [[ -n "$md5" ]]; then
    if ! command -v md5sum >/dev/null 2>&1; then
      log_error "md5sum não encontrado para verificar checksum."
      exit 1
    fi
    echo "${md5}  ${file}" | md5sum -c -
  fi
}

download_one_source() {
  local full="$1"
  local url="$2"
  local idx="$3"
  local sha256="$4"
  local md5="$5"

  mkdir -p "${ADM_CACHE_DIR}"

  if is_git_url "$url"; then
    log_info "Fonte git detectada (idx=${idx}) para ${full}: ${url}"
    return 0
  fi

  local tarball_basename
  tarball_basename="${url##*/}"
  tarball_basename="${tarball_basename%%\?*}"

  if [[ -z "$tarball_basename" || "$tarball_basename" = "." || "$tarball_basename" = "/" ]]; then
    log_error "Não foi possível determinar nome de arquivo para URL: ${url}"
    exit 1
  fi

  local tarball_path="${ADM_CACHE_DIR}/${tarball_basename}"

  if [[ -f "$tarball_path" ]]; then
    log_info "Tarball já em cache (idx=${idx}): ${tarball_path}"
  else
    log_info "Baixando (idx=${idx}) ${url} -> ${tarball_path}"
    if command -v curl >/dev/null 2>&1; then
      run_cmd curl -fL "$url" -o "$tarball_path"
    elif command -v wget >/dev/null 2>&1; then
      run_cmd wget -c "$url" -O "$tarball_path"
    else
      log_error "Nem curl nem wget encontrados para download."
      exit 1
    fi
  fi

  if [[ -n "$sha256" || -n "$md5" ]]; then
    verify_checksum "${tarball_path}" "${sha256}" "${md5}"
  else
    log_warn "Nenhum checksum (SHA256/MD5) definido para ${tarball_basename}"
  fi
}

fetch_source() {
  local full="$1"

  local urls=()
  if declare -p PKG_URLS >/dev/null 2>&1; then
    urls=("${PKG_URLS[@]}")
  elif [[ -n "${PKG_URL:-}" ]]; then
    urls=("${PKG_URL}")
  fi

  if [[ "${#urls[@]}" -eq 0 ]]; then
    log_error "Nenhuma PKG_URL ou PKG_URLS definida para ${full}"
    exit 1
  fi

  local sha256s=()
  local md5s=()
  if declare -p PKG_SHA256S >/dev/null 2>&1; then
    sha256s=("${PKG_SHA256S[@]}")
  fi
  if declare -p PKG_MD5S >/dev/null 2>&1; then
    md5s=("${PKG_MD5S[@]}")
  fi

  for idx in "${!urls[@]}"; do
    local url="${urls[$idx]}"
    local sha256_for_this=""
    local md5_for_this=""

    if [[ "${#sha256s[@]}" -gt "$idx" ]]; then
      sha256_for_this="${sha256s[$idx]}"
    elif [[ -n "${PKG_SHA256:-}" && "$idx" -eq 0 ]]; then
      sha256_for_this="${PKG_SHA256}"
    fi

    if [[ "${#md5s[@]}" -gt "$idx" ]]; then
      md5_for_this="${md5s[$idx]}"
    elif [[ -n "${PKG_MD5:-}" && "$idx" -eq 0 ]]; then
      md5_for_this="${PKG_MD5}"
    fi

    download_one_source "$full" "$url" "$idx" "$sha256_for_this" "$md5_for_this"
  done
}

extract_source() {
  local full="$1"

  local build_dir
  build_dir=$(pkg_build_dir "$full")

  local main_url=""
  if [[ -n "${PKG_URL:-}" ]]; then
    main_url="${PKG_URL}"
  elif declare -p PKG_URLS >/dev/null 2>&1 && [[ ${#PKG_URLS[@]:-0} -gt 0 ]]; then
    main_url="${PKG_URLS[0]}"
  fi

  if [[ -z "$main_url" ]]; then
    log_error "Nenhuma URL principal (PKG_URL ou PKG_URLS[0]) definida para extração de ${full}"
    exit 1
  fi

  if [[ -d "$build_dir" ]]; then
    log_info "Diretório de build já existe: ${build_dir} (retomando)"
    return 0
  fi

  run_cmd mkdir -p "$build_dir"

  if is_git_url "$main_url"; then
    log_info "Clonando fonte git principal para diretório de build: ${main_url}"
    if [[ "${ADM_DRY_RUN:-0}" = "1" ]]; then
      log_warn "[DRY-RUN] git clone '${main_url}' '${build_dir}'"
      if [[ -n "${PKG_GIT_REF:-}" ]]; then
        log_warn "[DRY-RUN] (cd '${build_dir}' && git checkout '${PKG_GIT_REF}')"
      fi
    else
      git clone "${main_url}" "${build_dir}"
      if [[ -n "${PKG_GIT_REF:-}" ]]; then
        ( cd "${build_dir}" && git checkout "${PKG_GIT_REF}" )
      fi
    fi
  else
    local tarball_basename
    tarball_basename="${main_url##*/}"
    tarball_basename="${tarball_basename%%\?*}"
    local tarball_path="${ADM_CACHE_DIR}/${tarball_basename}"

    if [[ ! -f "$tarball_path" ]]; then
      log_error "Tarball principal não encontrado no cache: ${tarball_path}"
      log_error "Certifique-se de chamar fetch_source antes de extract_source."
      exit 1
    fi

    log_info "Extraindo ${tarball_path} para ${build_dir}"
    run_cmd tar -xf "$tarball_path" -C "$build_dir" --strip-components=1
  fi

  local patch_dir
  patch_dir=$(pkg_patch_path "$full")
  if [[ -d "$patch_dir" ]]; then
    log_info "Aplicando patches em ${build_dir}"
    for p in "${patch_dir}"/*.patch; do
      [[ -e "$p" ]] || continue
      log_info "Aplicando patch: $p"
      ( cd "$build_dir" && run_cmd patch -p1 < "$p" )
    done
  fi
}

###############################################################################
# Hooks / registro
###############################################################################
run_hook() {
  local full="$1"
  local hook="$2"

  local hook_path
  hook_path=$(pkg_hook_path "$full" "$hook")

  if [[ -x "$hook_path" ]]; then
    log_info "Executando hook '${hook}' para ${full}"
    ADM_HOOK_PKG="$full" \
    ADM_HOOK_ROOTFS="$ADM_ROOTFS" \
    "$hook_path"
  fi
}

register_install() {
  local full="$1"
  local destdir="$2"

  local dbdir
  dbdir=$(pkg_db_dir "$full")
  mkdir -p "$dbdir"

  local meta="${dbdir}/meta"
  local files="${dbdir}/files.list"

  {
    echo "name=${PKG_NAME}"
    echo "version=${PKG_VERSION}"
    echo "profile=${ADM_PROFILE}"
    echo "triplet=${TARGET_TRIPLET}"
    printf "depends="
    if declare -p PKG_DEPENDS >/dev/null 2>&1; then
      printf "%s " "${PKG_DEPENDS[@]}"
    fi
    echo
    printf "urls="
    if declare -p PKG_URLS >/dev/null 2>&1; then
      printf "%s " "${PKG_URLS[@]}"
    elif [[ -n "${PKG_URL:-}" ]]; then
      printf "%s " "${PKG_URL}"
    fi
    echo
    echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${meta}"

  find "${destdir}" -type f -o -type l | sed "s|^${destdir}||" | sort > "${files}"

  log_ok "Registro de instalação atualizado em ${dbdir}"
}

###############################################################################
# Build + cache binário + retomada
###############################################################################
build_and_install_pkg() {
  local full="$1"

  load_pkg_metadata "$full"

  if [[ -n "${PKG_TARGET_TRIPLET:-}" ]]; then
    TARGET_TRIPLET="${PKG_TARGET_TRIPLET}"
  else
    unset TARGET_TRIPLET
  fi

  setup_profiles

  # Diretórios básicos
  local state_dir build_dir destdir
  state_dir=$(pkg_state_dir "$full")
  build_dir=$(pkg_build_dir "$full")
  destdir=$(pkg_destdir "$full")
  mkdir -p "$state_dir"

  # Lock simples por pacote
  local lock_dir="${state_dir}/.build.lock"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    log_error "Outro build de ${full} parece estar em andamento (lock: ${lock_dir})"
    exit 1
  fi
  trap 'rmdir "'"$lock_dir"'" 2>/dev/null || true' EXIT

  # Stamps de fase (para retomada)
  local stamp_prefix="${state_dir}/${PKG_VERSION}-${ADM_PROFILE}-${TARGET_TRIPLET}"
  local stamp_fetch="${stamp_prefix}.fetch"
  local stamp_extract="${stamp_prefix}.extract"
  local stamp_configure="${stamp_prefix}.configure"
  local stamp_build="${stamp_prefix}.build"
  local stamp_install="${stamp_prefix}.install"

  # Caminho do tarball (cache binário)
  local tarball
  tarball=$(pkg_tarball_path "$full" "${PKG_VERSION}")

  # Se binário já está em cache e não há rebuild forçado, reutiliza
  if [[ "${ADM_ENABLE_BIN_CACHE}" = "1" && "${ADM_FORCE_REBUILD:-0}" != "1" && -f "${tarball}" ]]; then
    log_info "Encontrado pacote binário em cache: ${tarball}"
    log_info "Reinstalando ${PKG_NAME}-${PKG_VERSION} a partir do cache binário"

    if [[ "${ADM_DRY_RUN:-0}" = "1" ]]; then
      log_warn "[DRY-RUN] rm -rf '${destdir}'"
      log_warn "[DRY-RUN] mkdir -p '${destdir}'"
      log_warn "[DRY-RUN] zstd -d -c '${tarball}' | tar -xf - -C '${destdir}'"
      log_warn "[DRY-RUN] rsync -a '${destdir}/' '${ADM_ROOTFS}/'"
    else
      rm -rf "${destdir}"
      mkdir -p "${destdir}"

      if command -v zstd >/dev/null 2>&1; then
        zstd -d -c "${tarball}" | tar -xf - -C "${destdir}"
      else
        log_error "zstd não encontrado para descompactar cache binário."
        exit 1
      fi

      run_cmd rsync -a "${destdir}/" "${ADM_ROOTFS}/"
    fi

    register_install "$full" "$destdir"
    run_hook "$full" "post_install"
    log_ok "Instalação de ${full} concluída via cache binário."
    return 0
  fi

  # Flags extras da receita
  if [[ -n "${PKG_CFLAGS_EXTRA:-}" ]]; then
    CFLAGS="${CFLAGS} ${PKG_CFLAGS_EXTRA}"
    CXXFLAGS="${CXXFLAGS} ${PKG_CFLAGS_EXTRA}"
  fi
  if [[ -n "${PKG_LDFLAGS_EXTRA:-}" ]]; then
    LDFLAGS="${LDFLAGS} ${PKG_LDFLAGS_EXTRA}"
  fi

  mkdir -p "${build_dir}" "${destdir}"

  # FETCH
  if [[ ! -f "${stamp_fetch}" ]]; then
    log_info "Buscando fontes para ${PKG_NAME}-${PKG_VERSION}..."
    fetch_source "$full"
    [[ "${ADM_DRY_RUN:-0}" = "1" ]] || touch "${stamp_fetch}"
  else
    log_info "Fase FETCH já concluída (retomando)."
  fi

  # EXTRACT
  if [[ ! -f "${stamp_extract}" ]]; then
    log_info "Extraindo fontes para ${build_dir}..."
    extract_source "$full"
    [[ "${ADM_DRY_RUN:-0}" = "1" ]] || touch "${stamp_extract}"
  else
    log_info "Fase EXTRACT já concluída (retomando)."
  fi

  run_hook "$full" "pre_build"

  # CONFIGURE
  if [[ ! -f "${stamp_configure}" ]]; then
    log_info "Configurando ${PKG_NAME}-${PKG_VERSION}..."

    if [[ "${ADM_DRY_RUN:-0}" = "1" ]]; then
      local cfg_preview=" ./configure"
      cfg_preview+=" --host='${TARGET_TRIPLET}' --build='${TARGET_TRIPLET}' --prefix=/usr --sysconfdir=/etc --localstatedir=/var"
      if declare -p PKG_CONFIGURE_OPTS >/dev/null 2>&1; then
        cfg_preview+=" ${PKG_CONFIGURE_OPTS[*]}"
      fi
      log_warn "[DRY-RUN] (cd '${build_dir}' &&${cfg_preview})"
    else
      (
        cd "$build_dir"
        local cfg_args=(
          "--host=${TARGET_TRIPLET}"
          "--build=${TARGET_TRIPLET}"
          "--prefix=/usr"
          "--sysconfdir=/etc"
          "--localstatedir=/var"
        )
        if declare -p PKG_CONFIGURE_OPTS >/dev/null 2>&1; then
          cfg_args+=("${PKG_CONFIGURE_OPTS[@]}")
        fi
        if [[ -x "./configure" ]]; then
          run_cmd ./configure "${cfg_args[@]}"
        else
          log_warn "Nenhum ./configure encontrado; pulando fase configure."
        fi
      )
      touch "${stamp_configure}"
    fi
  else
    log_info "Fase CONFIGURE já concluída (retomando)."
  fi

  # BUILD
  if [[ ! -f "${stamp_build}" ]]; then
    log_info "Compilando ${PKG_NAME}-${PKG_VERSION}..."

    # Determina número de jobs
    local jobs
    if [[ -n "${ADM_JOBS}" ]]; then
      jobs="${ADM_JOBS}"
    elif command -v nproc >/dev/null 2>&1; then
      jobs="$(nproc)"
    else
      jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    fi

    if [[ "${ADM_DRY_RUN:-0}" = "1" ]]; then
      local make_preview=" make -j'${jobs}'"
      if declare -p PKG_MAKE_OPTS >/dev/null 2>&1; then
        make_preview+=" ${PKG_MAKE_OPTS[*]}"
      fi
      log_warn "[DRY-RUN] (cd '${build_dir}' &&${make_preview})"
    else
      (
        cd "$build_dir"
        local make_args=( "-j${jobs}" )
        if declare -p PKG_MAKE_OPTS >/dev/null 2>&1; then
          make_args+=("${PKG_MAKE_OPTS[@]}")
        fi
        if command -v make >/dev/null 2>&1; then
          run_cmd make "${make_args[@]}"
        else
          log_warn "make não encontrado; assumindo build custom via hook."
        fi
      )
      touch "${stamp_build}"
    fi
  else
    log_info "Fase BUILD já concluída (retomando)."
  fi

  # INSTALL em DESTDIR
  if [[ ! -f "${stamp_install}" ]]; then
    log_info "Instalando ${PKG_NAME}-${PKG_VERSION} em DESTDIR..."

    if [[ "${ADM_DRY_RUN:-0}" = "1" ]]; then
      local make_install_preview=" make DESTDIR='${destdir}' install"
      if declare -p PKG_MAKE_INSTALL_OPTS >/dev/null 2>&1; then
        make_install_preview+=" ${PKG_MAKE_INSTALL_OPTS[*]}"
      fi
      log_warn "[DRY-RUN] (cd '${build_dir}' &&${make_install_preview})"
    else
      (
        cd "$build_dir"
        local install_args=( "DESTDIR=${destdir}" "install" )
        if declare -p PKG_MAKE_INSTALL_OPTS >/dev/null 2>&1; then
          install_args+=("${PKG_MAKE_INSTALL_OPTS[@]}")
        fi
        if command -v make >/dev/null 2>&1; then
          run_cmd make "${install_args[@]}"
        else
          log_warn "make não encontrado; assumindo instalação custom via hook."
        fi
      )
      touch "${stamp_install}"
    fi
  else
    log_info "Fase INSTALL já concluída (retomando)."
  fi

  run_hook "$full" "pre_install"

  # Strip de binários ELF (opcional)
  if [[ "${ADM_STRIP_BINARIES}" = "1" && "${ADM_DRY_RUN:-0}" != "1" ]]; then
    if command -v file >/dev/null 2>&1 && command -v "${STRIP:-strip}" >/dev/null 2>&1; then
      log_info "Executando strip em binários ELF instalados..."
      find "${destdir}" -type f -print0 | while IFS= read -r -d '' f; do
        if file "$f" | grep -q "ELF"; then
          "${STRIP:-strip}" --strip-unneeded "$f" 2>/dev/null || true
        fi
      done
    else
      log_warn "file/strip não encontrados; pulando strip de binários."
    fi
  fi

  # Geração de tarball (cache binário)
  log_info "Gerando tarball em cache: ${tarball}"
  if [[ "${ADM_DRY_RUN:-0}" = "1" ]]; then
    log_warn "[DRY-RUN] (cd '${destdir}' && tar -cf - . | zstd -19 -o '${tarball}')"
  else
    mkdir -p "$(dirname "${tarball}")"
    if command -v zstd >/dev/null 2>&1; then
      ( cd "${destdir}" && tar -cf - . ) | zstd -19 -o "${tarball}"
    else
      log_warn "zstd não encontrado; gerando tarball sem compressão."
      ( cd "${destdir}" && run_cmd tar -cf "${tarball%.zst}" . )
    fi
  fi

  # Instala em rootfs
  log_info "Instalando em rootfs: ${ADM_ROOTFS}"
  if [[ "${ADM_DRY_RUN:-0}" = "1" ]]; then
    log_warn "[DRY-RUN] rsync -a '${destdir}/' '${ADM_ROOTFS}/'"
  else
    run_cmd rsync -a "${destdir}/" "${ADM_ROOTFS}/"
  fi

  register_install "$full" "$destdir"
  run_hook "$full" "post_install"
  log_ok "Build e instalação de ${full} concluídos."
}

###############################################################################
# Dependências / grafos / uninstall / rebuild / comandos
###############################################################################
collect_deps_recursive() {
  local full="$1"
  local -n out_set="$2"

  load_pkg_metadata "$full"
  out_set["$full"]=1
  if ! declare -p PKG_DEPENDS >/dev/null 2>&1; then
    return 0
  fi

  for d in "${PKG_DEPENDS[@]}"; do
    local dep_full
    dep_full=$(normalize_pkg_name "$d")
    if [[ -z "${out_set[$dep_full]:-}" ]]; then
      collect_deps_recursive "$dep_full" out_set
    fi
  done
}

# Topological sort simples via DFS
topo_sort_dfs() {
  local pkgs=("$@")
  declare -A visited
  local stack=()

  _dfs() {
    local p="$1"
    if [[ "${visited[$p]:-}" = "2" ]]; then
      return
    fi
    if [[ "${visited[$p]:-}" = "1" ]]; then
      log_error "Ciclo de dependência detectado em ${p}"
      exit 1
    fi
    visited["$p"]=1

    load_pkg_metadata "$p"
    if declare -p PKG_DEPENDS >/dev/null 2>&1; then
      for d in "${PKG_DEPENDS[@]}"; do
        local dep_full
        dep_full=$(normalize_pkg_name "$d")
        _dfs "$dep_full"
      done
    fi

    visited["$p"]=2
    stack+=("$p")
  }

  local p
  for p in "${pkgs[@]}"; do
    if [[ -z "${visited[$p]:-}" ]]; then
      _dfs "$p"
    fi
  done

  # stack em ordem topológica (deps primeiro)
  printf '%s\n' "${stack[@]}"
}

build_with_deps() {
  local full
  full=$(normalize_pkg_name "$1")

  declare -A dep_set=()
  collect_deps_recursive "$full" dep_set

  local order=()
  while IFS= read -r p; do
    order+=("$p")
  done < <(topo_sort_dfs "${!dep_set[@]}")

  log_info "Ordem de build (deps primeiro):"
  printf '  - %s\n' "${order[@]}" >&2

  for p in "${order[@]}"; do
    log_info "=== Build de ${p} ==="
    build_and_install_pkg "$p"
  done
}

uninstall_pkg() {
  local full
  full=$(normalize_pkg_name "$1")
  local dbdir
  dbdir=$(pkg_db_dir "$full")

  if [[ ! -d "$dbdir" ]]; then
    log_warn "Pacote ${full} não está registrado como instalado."
    return 0
  fi

  local files="${dbdir}/files.list"
  if [[ ! -f "$files" ]]; then
    log_error "Arquivo de lista de arquivos ausente para ${full}: ${files}"
    exit 1
  fi

  log_info "Removendo arquivos de ${full}"
  if [[ "${ADM_DRY_RUN:-0}" = "1" ]]; then
    while IFS= read -r f; do
      log_warn "[DRY-RUN] rm -f '${ADM_ROOTFS}${f}'"
    done < "$files"
  else
    # Remove arquivos
    while IFS= read -r f; do
      rm -f "${ADM_ROOTFS}${f}" 2>/dev/null || true
    done < "$files"
    # Remove diretórios vazios (melhor esforço)
    tac "$files" 2>/dev/null | while IFS= read -r f; do
      local d
      d=$(dirname "${ADM_ROOTFS}${f}")
      rmdir "$d" 2>/dev/null || true
    done
    rm -rf "$dbdir"
  fi
  log_ok "Pacote ${full} removido."
}

uninstall_with_reverse_deps() {
  local full
  full=$(normalize_pkg_name "$1")

  if [[ ! -d "${ADM_DB_DIR}" ]]; then
    log_warn "Nenhum pacote instalado."
    return 0
  fi

  declare -A deps_of
  declare -A all_pkgs

  while IFS= read -r meta_file; do
    local pkg
    pkg="${meta_file%/meta}"
    pkg="${pkg#${ADM_DB_DIR}/}"
    all_pkgs["$pkg"]=1

    local depends_line
    depends_line=$(grep '^depends=' "$meta_file" || true)
    depends_line="${depends_line#depends=}"

    if [[ -n "$depends_line" ]]; then
      for d in $depends_line; do
        local dep_full
        if [[ "$d" == */* ]]; then
          dep_full="$d"
        else
          dep_full=$(normalize_pkg_name "$d")
        fi
        deps_of["$dep_full"]+="${pkg} "
      done
    fi
  done < <(find "${ADM_DB_DIR}" -mindepth 2 -maxdepth 2 -type f -name meta | sort)

  declare -A to_remove
  local queue=("$full")
  to_remove["$full"]=1

  local q
  while (( ${#queue[@]} > 0 )); do
    local cur="${queue[0]}"
    queue=("${queue[@]:1}")

    local rdeps="${deps_of[$cur]:-}"
    for rp in $rdeps; do
      if [[ -z "${to_remove[$rp]:-}" ]]; then
        to_remove["$rp"]=1
        queue+=("$rp")
      fi
    done
  done

  local ordered=()
  while IFS= read -r p; do
    ordered+=("$p")
  done < <(topo_sort_dfs "${!to_remove[@]}")

  log_warn "A remoção de ${full} afetará também (ordem de remoção):"
  printf '  - %s\n' "${ordered[@]}" >&2

  for (( i=${#ordered[@]}-1; i>=0; i-- )); do
    uninstall_pkg "${ordered[i]}"
  done
}

rebuild_world() {
  if [[ ! -d "${ADM_DB_DIR}" ]]; then
    log_warn "Nenhum pacote instalado."
    return 0
  fi

  local pkgs=()
  while IFS= read -r meta_file; do
    local pkg="${meta_file%/meta}"
    pkg="${pkg#${ADM_DB_DIR}/}"
    pkgs+=("$pkg")
  done < <(find "${ADM_DB_DIR}" -mindepth 2 -maxdepth 2 -type f -name meta | sort)

  if (( ${#pkgs[@]} == 0 )); then
    log_warn "Nenhum pacote instalado."
    return 0
  fi

  declare -A dep_set=()
  local p
  for p in "${pkgs[@]}"; do
    collect_deps_recursive "$p" dep_set
  done

  local order=()
  while IFS= read -r p; do
    order+=("$p")
  done < <(topo_sort_dfs "${!dep_set[@]}")

  log_info "Rebuild world em ordem:"
  printf '  - %s\n' "${order[@]}" >&2

  for p in "${order[@]}"; do
    log_info "=== Rebuild de ${p} ==="
    ADM_FORCE_REBUILD=1 build_and_install_pkg "$p"
  done
}

rebuild_pkg() {
  local full
  full=$(normalize_pkg_name "$1")
  log_info "Rebuild de pacote específico: ${full}"
  ADM_FORCE_REBUILD=1 build_with_deps "$full"
}

cmd_info() {
  local full
  full=$(normalize_pkg_name "$1")
  load_pkg_metadata "$full"

  echo "Pacote: ${full}"
  echo "Nome:   ${PKG_NAME}"
  echo "Versão: ${PKG_VERSION}"
  echo "Perfil: ${ADM_PROFILE}"
  echo "Triplet:${TARGET_TRIPLET}"
  echo "URL(s):"
  if declare -p PKG_URLS >/dev/null 2>&1; then
    printf '  - %s\n' "${PKG_URLS[@]}"
  elif [[ -n "${PKG_URL:-}" ]]; then
    printf '  - %s\n' "${PKG_URL}"
  fi
  echo "Dependências:"
  if declare -p PKG_DEPENDS >/dev/null 2>&1 && [[ ${#PKG_DEPENDS[@]} -gt 0 ]]; then
    printf '  - %s\n' "${PKG_DEPENDS[@]}"
  else
    echo "  (nenhuma)"
  fi
}

cmd_search() {
  local pattern="$1"
  if [[ ! -d "${ADM_PACKAGES_DIR}" ]]; then
    log_error "Diretório de pacotes não existe: ${ADM_PACKAGES_DIR}"
    exit 1
  fi
  find "${ADM_PACKAGES_DIR}" -mindepth 2 -maxdepth 2 -type d -print \
    | sed "s|^${ADM_PACKAGES_DIR}/||" \
    | grep -i --color=never -- "$pattern" || true
}

cmd_list_installed() {
  if [[ ! -d "${ADM_DB_DIR}" ]]; then
    log_warn "Nenhum pacote instalado."
    return 0
  fi
  find "${ADM_DB_DIR}" -mindepth 2 -maxdepth 2 -type f -name meta \
    | sed "s|^${ADM_DB_DIR}/||;s|/meta$||" \
    | sort
}

cmd_graph_deps() {
  local full
  full=$(normalize_pkg_name "$1")

  declare -A dep_set=()
  collect_deps_recursive "$full" dep_set

  topo_sort_dfs "${!dep_set[@]}"
}

cmd_update() {
  local repo="${ADM_GIT_REPO:-}"
  if [[ -z "$repo" ]]; then
    log_error "ADM_GIT_REPO não definido; não sei de onde atualizar receitas."
    exit 1
  fi

  if [[ -d "${ADM_PACKAGES_DIR}/.git" ]]; then
    log_info "Atualizando repositório de pacotes em ${ADM_PACKAGES_DIR}..."
    ( cd "${ADM_PACKAGES_DIR}" && run_cmd git pull --ff-only )
  else
    if [[ -e "${ADM_PACKAGES_DIR}" ]]; then
      if [[ -d "${ADM_PACKAGES_DIR}" && -z "$(ls -A "${ADM_PACKAGES_DIR}" 2>/dev/null)" ]]; then
        log_info "Clonando repositório de pacotes em diretório vazio ${ADM_PACKAGES_DIR}..."
        run_cmd git clone "${ADM_GIT_REPO}" "${ADM_PACKAGES_DIR}"
      else
        log_error "Diretório '${ADM_PACKAGES_DIR}' já existe e não é um repositório Git vazio."
        exit 1
      fi
    else
      log_info "Clonando repositório de pacotes em ${ADM_PACKAGES_DIR}..."
      run_cmd git clone "${ADM_GIT_REPO}" "${ADM_PACKAGES_DIR}"
    fi
  fi
}

###############################################################################
# main
###############################################################################
main() {
  ADM_DRY_RUN="${ADM_DRY_RUN:-0}"
  check_dependencies

  parse_global_args "$@"
  set -- "${ADM_ARGS[@]}"

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    ""|-h|--help|help)
      usage
      ;;
    update)
      cmd_update
      ;;
    build|install)
      if [[ $# -lt 1 ]]; then
        log_error "Informe o pacote para build/install."
        exit 1
      fi
      build_with_deps "$1"
      ;;
    uninstall)
      if [[ $# -lt 1 ]]; then
        log_error "Informe o pacote para uninstall."
        exit 1
      fi
      uninstall_with_reverse_deps "$1"
      ;;
    rebuild)
      if [[ $# -eq 0 || "$1" = "world" ]]; then
        rebuild_world
      else
        rebuild_pkg "$1"
      fi
      ;;
    info)
      if [[ $# -lt 1 ]]; then
        log_error "Informe o pacote para info."
        exit 1
      fi
      cmd_info "$1"
      ;;
    search)
      if [[ $# -lt 1 ]]; then
        log_error "Informe o padrão para search."
        exit 1
      fi
      cmd_search "$1"
      ;;
    list-installed)
      cmd_list_installed
      ;;
    graph-deps)
      if [[ $# -lt 1 ]]; then
        log_error "Informe o pacote para graph-deps."
        exit 1
      fi
      cmd_graph_deps "$1"
      ;;
    dry-run)
      ADM_DRY_RUN=1
      main "$@"
      ;;
    *)
      log_error "Comando desconhecido: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
