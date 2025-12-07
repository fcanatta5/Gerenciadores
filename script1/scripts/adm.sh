#!/usr/bin/env bash
# ADM - Simple source-based package/build manager for a from-scratch Linux
# Requisitos: bash, coreutils, curl ou wget, tar, zstd, patch, git, find, xargs

set -euo pipefail

###############################################################################
# Configuração geral
###############################################################################

ADM_ROOT="${ADM_ROOT:-/opt/adm}"
ADM_PACKAGES_DIR="${ADM_PACKAGES_DIR:-${ADM_ROOT}/packages}"
ADM_BUILD_ROOT="${ADM_BUILD_ROOT:-${ADM_ROOT}/build}"
ADM_CACHE_DIR="${ADM_CACHE_DIR:-${ADM_ROOT}/cache}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_ROOT}/log}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_ROOT}/db}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_ROOTFS="${ADM_ROOTFS:-${ADM_ROOT}/rootfs}"

# Repositório git das receitas
ADM_GIT_REPO="${ADM_GIT_REPO:-git@github.com:SEU_USUARIO/SEU_REPO_ADM.git}"

# Perfil: glibc | musl | aggressive
ADM_PROFILE="${ADM_PROFILE:-glibc}"

# Dry-run global
ADM_DRY_RUN="${ADM_DRY_RUN:-0}"

# Shell para executar hooks
ADM_HOOK_SHELL="${ADM_HOOK_SHELL:-/bin/bash}"

mkdir -p "${ADM_PACKAGES_DIR}" "${ADM_BUILD_ROOT}" "${ADM_CACHE_DIR}" \
         "${ADM_LOG_DIR}" "${ADM_DB_DIR}" "${ADM_STATE_DIR}" "${ADM_ROOTFS}"

###############################################################################
# Logging colorido
###############################################################################

COLOR_RESET="\033[0m"
COLOR_INFO="\033[1;34m"
COLOR_WARN="\033[1;33m"
COLOR_ERROR="\033[1;31m"
COLOR_OK="\033[1;32m"

log_ts() {
  date +"%Y-%m-%d %H:%M:%S"
}

log_info() {
  echo -e "$(log_ts) ${COLOR_INFO}[INFO]${COLOR_RESET} $*" >&2
}

log_warn() {
  echo -e "$(log_ts) ${COLOR_WARN}[WARN]${COLOR_RESET} $*" >&2
}

log_error() {
  echo -e "$(log_ts) ${COLOR_ERROR}[ERROR]${COLOR_RESET} $*" >&2
}

log_ok() {
  echo -e "$(log_ts) ${COLOR_OK}[OK]${COLOR_RESET} $*" >&2
}

run_cmd() {
  # Wrapper para honrar dry-run
  if [[ "${ADM_DRY_RUN}" = "1" ]]; then
    echo -e "${COLOR_WARN}[DRY-RUN]${COLOR_RESET} $*"
  else
    echo -e "${COLOR_INFO}[CMD]${COLOR_RESET} $*"
    eval "$@"
  fi
}

###############################################################################
# Perfis de compilação
###############################################################################
setup_profiles() {
  # Perfil atual (glibc | musl | aggressive)
  ADM_PROFILE="${ADM_PROFILE:-glibc}"

  #############################################################################
  # Configurações comuns
  #############################################################################

  # Arquitetura alvo (pode ser sobrescrita via ADM_TARGET_ARCH)
  ADM_TARGET_ARCH="${ADM_TARGET_ARCH:-x86_64}"

  # Tipo de libc (derivado do perfil, mas pode ser sobrescrito)
  case "${ADM_PROFILE}" in
    glibc|aggressive)
      ADM_TARGET_LIBC="${ADM_TARGET_LIBC:-glibc}"
      ;;
    musl)
      ADM_TARGET_LIBC="${ADM_TARGET_LIBC:-musl}"
      ;;
    *)
      echo "[setup_profiles] Perfil desconhecido: ${ADM_PROFILE}" >&2
      exit 1
      ;;
  esac

  # Triplet padrão (pode ser sobrescrito externamente)
  if [[ -z "${TARGET_TRIPLET:-}" ]]; then
    case "${ADM_TARGET_ARCH}-${ADM_TARGET_LIBC}" in
      x86_64-glibc) TARGET_TRIPLET="x86_64-linux-gnu"  ;;
      x86_64-musl)  TARGET_TRIPLET="x86_64-linux-musl" ;;
      aarch64-glibc) TARGET_TRIPLET="aarch64-linux-gnu" ;;
      aarch64-musl)  TARGET_TRIPLET="aarch64-linux-musl" ;;
      *)
        # fallback genérico
        TARGET_TRIPLET="${ADM_TARGET_ARCH}-linux-${ADM_TARGET_LIBC}"
        ;;
    esac
  fi

  # Diretório raiz de instalação (rootfs) e sysroot
  ADM_ROOT="${ADM_ROOT:-/opt/adm}"
  ADM_ROOTFS="${ADM_ROOTFS:-${ADM_ROOT}/rootfs}"
  ADM_SYSROOT="${ADM_SYSROOT:-${ADM_ROOTFS}}"

  # Prefixo padrão para o toolchain cross (se houver)
  # Ex.: /opt/cross/x86_64-linux-gnu/bin/x86_64-linux-gnu-gcc
  ADM_TOOLCHAIN_PREFIX="${ADM_TOOLCHAIN_PREFIX:-/opt/cross/${TARGET_TRIPLET}}"

  # Diretórios padrão de include e libs dentro do sysroot
  SYS_INC_DIR="${ADM_SYSROOT}/usr/include"
  SYS_LIB_DIR="${ADM_SYSROOT}/usr/lib"
  SYS_LIB64_DIR="${ADM_SYSROOT}/usr/lib64"

  # flags comuns a todos os perfis
  CFLAGS_COMMON="-pipe"
  CXXFLAGS_COMMON="-pipe"
  CPPFLAGS_COMMON="-I${SYS_INC_DIR}"
  LDFLAGS_COMMON="-L${SYS_LIB_DIR} -L${SYS_LIB64_DIR}"

  #############################################################################
  # Ajuste de flags por perfil
  #############################################################################
  case "${ADM_PROFILE}" in
    glibc)
      CFLAGS_OPT="-O2"
      CXXFLAGS_OPT="-O2"
      LDFLAGS_OPT="-Wl,-O1,-z,relro,-z,now -Wl,--as-needed"
      ;;

    musl)
      CFLAGS_OPT="-O2 -fstack-protector-strong"
      CXXFLAGS_OPT="-O2 -fstack-protector-strong"
      # opcionalmente, mais estático:
      # LDFLAGS_OPT="-static -Wl,-O1,-z,relro,-z,now -Wl,--as-needed"
      LDFLAGS_OPT="-Wl,-O1,-z,relro,-z,now -Wl,--as-needed"
      ;;

    aggressive)
      CFLAGS_OPT="-O3 -march=native -mtune=native -fomit-frame-pointer -flto=auto"
      CXXFLAGS_OPT="-O3 -march=native -mtune=native -fomit-frame-pointer -flto=auto"
      LDFLAGS_OPT="-flto=auto -Wl,-O2,-z,relro,-z,now -Wl,--as-needed"
      ;;
  esac

  #############################################################################
  # Composição final das flags
  #############################################################################
  export TARGET_TRIPLET

  export CFLAGS="${CFLAGS:-${CFLAGS_COMMON} ${CFLAGS_OPT}}"
  export CXXFLAGS="${CXXFLAGS:-${CXXFLAGS_COMMON} ${CXXFLAGS_OPT}}"
  export CPPFLAGS="${CPPFLAGS:-${CPPFLAGS_COMMON}}"
  export LDFLAGS="${LDFLAGS:-${LDFLAGS_COMMON} ${LDFLAGS_OPT}}"

  #############################################################################
  # Toolchain (cross ou native) – pode ser sobrescrito fora
  #############################################################################
  # Se ADM_USE_NATIVE=1, usa toolchain nativo ao invés do prefixado
  ADM_USE_NATIVE="${ADM_USE_NATIVE:-0}"

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

  #############################################################################
  # PKG-CONFIG
  #############################################################################
  # Para builds em sysroot, PKG_CONFIG_LIBDIR é mais seguro que PKG_CONFIG_PATH
  export PKG_CONFIG="${PKG_CONFIG:-${ADM_TOOLCHAIN_PREFIX}/bin/${TARGET_TRIPLET}-pkg-config}"
  if [[ ! -x "${PKG_CONFIG}" ]]; then
    # fallback para pkg-config nativo
    PKG_CONFIG="pkg-config"
  fi
  export PKG_CONFIG

  export PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR:-${SYS_LIB_DIR}/pkgconfig:${SYS_LIB64_DIR}/pkgconfig}"
  export PKG_CONFIG_SYSROOT_DIR="${PKG_CONFIG_SYSROOT_DIR:-${ADM_SYSROOT}}"

  #############################################################################
  # PATH – garante que o toolchain esteja à frente
  #############################################################################
  if [[ "${ADM_USE_NATIVE}" = "1" ]]; then
    :
  else
    case ":$PATH:" in
      *:"${ADM_TOOLCHAIN_PREFIX}/bin":*)
        ;;
      *)
        export PATH="${ADM_TOOLCHAIN_PREFIX}/bin:${PATH}"
        ;;
    esac
  fi

  #############################################################################
  # Variáveis convenientes para scripts de configure/make
  #############################################################################
  # BUILD/HOST/TARGET: por padrão usamos o mesmo triplet (cross simples)
  export BUILD_TRIPLET="${BUILD_TRIPLET:-${TARGET_TRIPLET}}"
  export HOST_TRIPLET="${HOST_TRIPLET:-${TARGET_TRIPLET}}"

  # Parâmetros comuns para ./configure
  export ADM_CONFIGURE_ARGS_COMMON="
    --host=${HOST_TRIPLET}
    --build=${BUILD_TRIPLET}
    --prefix=/usr
    --sysconfdir=/etc
    --localstatedir=/var
  "

  # Alguns projetos respeitam DESTDIR, outros usam SYSROOT; garantimos ambos
  export DESTDIR="${DESTDIR:-}"
  export SYSROOT="${ADM_SYSROOT}"

  # Variáveis auxiliares que o seu framework pode usar
  export ADM_PROFILE ADM_TARGET_ARCH ADM_TARGET_LIBC ADM_ROOT ADM_ROOTFS ADM_SYSROOT
}

is_git_url() {
  # Detecta heurísticamente se a URL é de repositório git (github/gitlab/etc)
  local url="$1"
  case "$url" in
    git://* | git+* | ssh://git@* | git@* )
      return 0 ;;
    https://*.git | http://*.git | *.git )
      return 0 ;;
    *)
      return 1 ;;
  esac
}

verify_checksum() {
  # Verifica SHA256 ou MD5 (prioriza SHA256 se ambos fornecidos)
  # Uso: verify_checksum <arquivo> <sha256> <md5>
  local file="$1"
  local sha256="${2:-}"
  local md5="${3:-}"

  if [[ ! -f "$file" ]]; then
    log_error "Arquivo para verificação de checksum não existe: $file"
    exit 1
  fi

  if [[ "${ADM_DRY_RUN}" = "1" ]]; then
    if [[ -n "$sha256" ]]; then
      log_warn "[DRY-RUN] Verificar SHA256 de $file"
    elif [[ -n "$md5" ]]; then
      log_warn "[DRY-RUN] Verificar MD5 de $file"
    else
      log_warn "Nenhum checksum fornecido para $file (sem verificação)."
    fi
    return 0
  fi

  if [[ -n "$sha256" ]]; then
    if ! echo "${sha256}  ${file}" | sha256sum -c -; then
      log_error "Falha na verificação SHA256 para $file"
      exit 1
    fi
    log_ok "SHA256 OK para $file"
  elif [[ -n "$md5" ]]; then
    if ! echo "${md5}  ${file}" | md5sum -c -; then
      log_error "Falha na verificação MD5 para $file"
      exit 1
    fi
    log_ok "MD5 OK para $file"
  else
    log_warn "Nenhum checksum fornecido para $file (sem verificação)."
  fi
}

download_one_source() {
  # Faz o download (se necessário) de uma única fonte.
  # Uso: download_one_source <full-pkg-name> <url> <index> <sha256> <md5>
  local full="$1"
  local url="$2"
  local idx="$3"
  local sha256="$4"
  local md5="$5"

  mkdir -p "${ADM_CACHE_DIR}"

  if is_git_url "$url"; then
    # Para fontes git, apenas registramos (o clone será feito em extract_source)
    log_info "Fonte git detectada (idx=${idx}) para ${full}: ${url}"
    return 0
  fi

  # Fonte "arquivo" (http/https/ftp)
  local tarball_basename
  tarball_basename="$(basename "${url}")"
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
      run_cmd "curl -fL '${url}' -o '${tarball_path}'"
    elif command -v wget >/dev/null 2>&1; then
      run_cmd "wget -c '${url}' -O '${tarball_path}'"
    else
      log_error "Nem curl nem wget encontrados para download."
      exit 1
    fi
  fi

  # Verificação inteligente de checksum (SHA256 ou MD5)
  if [[ -n "$sha256" || -n "$md5" ]]; then
    verify_checksum "${tarball_path}" "${sha256}" "${md5}"
  else
    log_warn "Nenhum checksum (SHA256/MD5) definido para ${tarball_basename}"
  fi
}

###############################################################################
# Utilitários
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
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -P|--profile)
        ADM_PROFILE="$2"; shift 2;;
      -n|--dry-run)
        ADM_DRY_RUN=1; shift;;
      -h|--help)
        usage; exit 0;;
      *)
        args+=("$1"); shift;;
    esac
  done
  set -- "${args[@]}"
  echo "$@"
}

# Normaliza "pkg" ou "cat/pkg"
normalize_pkg_name() {
  local input="$1"
  if [[ "$input" == */* ]]; then
    echo "$input"
  else
    # tentar descobrir categoria: busca em packages/*/input/input.sh
    local candidates
    candidates=$(find "${ADM_PACKAGES_DIR}" -mindepth 2 -maxdepth 2 -type d -name "$input" 2>/dev/null || true)
    local first
    first=$(echo "$candidates" | head -n1 || true)
    if [[ -z "$first" ]]; then
      log_error "Pacote $input não encontrado em ${ADM_PACKAGES_DIR}"
      exit 1
    fi
    local cat
    cat=$(basename "$(dirname "$first")")
    echo "${cat}/${input}"
  fi
}

pkg_dirs_for_name() {
  local full="$1"
  local cat="${full%%/*}"
  local name="${full##*/}"
  echo "${ADM_PACKAGES_DIR}/${cat}/${name}"
}

pkg_script_path() {
  local full="$1"
  local dir
  dir=$(pkg_dirs_for_name "$full")
  echo "${dir}/${full##*/}.sh"
}

pkg_hook_path() {
  local full="$1"
  local hook="$2" # pre_install, post_install, ...
  local dir
  dir=$(pkg_dirs_for_name "$full")
  echo "${dir}/${full##*/}.${hook}"
}

pkg_patch_path() {
  local full="$1"
  local dir
  dir=$(pkg_dirs_for_name "$full")
  echo "${dir}/${full##*/}.patch"
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
  local name="${full##*/}"
  echo "${ADM_BUILD_ROOT}/${name}"
}

pkg_destdir() {
  local full="$1"
  local name="${full##*/}"
  echo "${ADM_BUILD_ROOT}/dest/${name}"
}

pkg_tarball_path() {
  local full="$1"
  local cat="${full%%/*}"
  local name="${full##*/}"
  local version="$2"
  mkdir -p "${ADM_ROOT}/pkgs/${cat}"
  echo "${ADM_ROOT}/pkgs/${cat}/${name}-${version}-${ADM_PROFILE}.tar.zst"
}

###############################################################################
# Carrega metadados de pacote
###############################################################################

load_pkg_metadata() {
  local full="$1"
  local script
  script=$(pkg_script_path "$full")
  if [[ ! -f "$script" ]]; then
    log_error "Script de pacote não encontrado: $script"
    exit 1
  fi

  # Limpar variáveis PKG_ de execuções anteriores
  unset PKG_NAME PKG_VERSION PKG_CATEGORY PKG_URL PKG_SHA256 PKG_DEPENDS \
        PKG_TARGET_TRIPLET PKG_CFLAGS_EXTRA PKG_LDFLAGS_EXTRA

  # shellcheck source=/dev/null
  source "$script"

  if [[ -z "${PKG_NAME:-}" ]] || [[ -z "${PKG_VERSION:-}" ]] || [[ -z "${PKG_URL:-}" ]]; then
    log_error "PKG_NAME, PKG_VERSION ou PKG_URL não definidos em $script"
    exit 1
  fi

  if [[ -z "${PKG_CATEGORY:-}" ]]; then
    PKG_CATEGORY="${full%%/*}"
  fi

  PKG_DEPENDS=("${PKG_DEPENDS[@]:-}")
}

###############################################################################
# download + extração + patch
###############################################################################

fetch_source() {
  local full="$1"

  # Lista de URLs:
  # - se PKG_URLS (array) estiver definida, usa ela
  # - senão, usa PKG_URL (string única)
  local urls=()

  if declare -p PKG_URLS >/dev/null 2>&1; then
    # shellcheck disable=SC2154
    urls=("${PKG_URLS[@]}")
  elif [[ -n "${PKG_URL:-}" ]]; then
    urls=("${PKG_URL}")
  else
    log_error "Nenhuma PKG_URL ou PKG_URLS definida para ${full}"
    exit 1
  fi

  if [[ "${#urls[@]}" -eq 0 ]]; then
    log_error "Lista de URLs está vazia para ${full}"
    exit 1
  fi

  # Arrays de checksums opcionais
  local sha256s=()
  local md5s=()

  if declare -p PKG_SHA256S >/dev/null 2>&1; then
    # shellcheck disable=SC2154
    sha256s=("${PKG_SHA256S[@]}")
  fi
  if declare -p PKG_MD5S >/dev/null 2>&1; then
    # shellcheck disable=SC2154
    md5s=("${PKG_MD5S[@]}")
  fi

  for idx in "${!urls[@]}"; do
    local url="${urls[$idx]}"
    local sha256_for_this=""
    local md5_for_this=""

    # Se arrays de checksums existirem e tiverem tamanho compatível, usa por índice.
    if [[ "${#sha256s[@]}" -gt "$idx" ]]; then
      sha256_for_this="${sha256s[$idx]}"
    elif [[ -n "${PKG_SHA256:-}" && "$idx" -eq 0 ]]; then
      # Fallback: PKG_SHA256 simples para a primeira URL
      sha256_for_this="${PKG_SHA256}"
    fi

    if [[ "${#md5s[@]}" -gt "$idx" ]]; then
      md5_for_this="${md5s[$idx]}"
    elif [[ -n "${PKG_MD5:-}" && "$idx" -eq 0 ]]; then
      # Fallback: PKG_MD5 simples para a primeira URL
      md5_for_this="${PKG_MD5}"
    fi

    download_one_source "$full" "$url" "$idx" "$sha256_for_this" "$md5_for_this"
  done
}

extract_source() {
  local full="$1"

  local build_dir
  build_dir=$(pkg_build_dir "$full")

  # Determina URL principal (para extração)
  local main_url=""
  if [[ -n "${PKG_URL:-}" ]]; then
    main_url="${PKG_URL}"
  elif declare -p PKG_URLS >/dev/null 2>&1; then
    # shellcheck disable=SC2154
    if [[ "${#PKG_URLS[@]}" -gt 0 ]]; then
      main_url="${PKG_URLS[0]}"
    fi
  fi

  if [[ -z "$main_url" ]]; then
    log_error "Nenhuma URL principal (PKG_URL ou PKG_URLS[0]) definida para extração de ${full}"
    exit 1
  fi

  if [[ -d "$build_dir" ]]; then
    log_info "Diretório de build já existe: $build_dir (retomando)"
    return 0
  fi

  run_cmd "mkdir -p '${build_dir}'"

  if is_git_url "$main_url"; then
    # Clone direto para o diretório de build
    log_info "Clonando fonte git principal para diretório de build: ${main_url}"
    if [[ "${ADM_DRY_RUN}" = "1" ]]; then
      log_warn "[DRY-RUN] git clone '${main_url}' '${build_dir}'"
    else
      git clone "${main_url}" "${build_dir}"
      # Se o pacote definir PKG_GIT_REF, faz checkout específico (tag/commit/branch)
      if [[ -n "${PKG_GIT_REF:-}" ]]; then
        (
          cd "${build_dir}"
          git checkout "${PKG_GIT_REF}"
        )
      fi
    fi
  else
    # Fonte principal é tarball/arquivo
    local tarball_basename
    tarball_basename="$(basename "${main_url}")"
    local tarball_path="${ADM_CACHE_DIR}/${tarball_basename}"

    if [[ ! -f "$tarball_path" ]]; then
      log_error "Tarball principal não encontrado no cache: ${tarball_path}"
      log_error "Certifique-se de chamar fetch_source antes de extract_source."
      exit 1
    fi

    log_info "Extraindo ${tarball_path} para ${build_dir}"
    # Usamos --strip-components=1 para a fonte principal (layout clássico)
    run_cmd "tar -xf '${tarball_path}' -C '${build_dir}' --strip-components=1"
  fi

  # Aplicar patch opcional
  local patch_file
  patch_file=$(pkg_patch_path "$full")
  if [[ -f "$patch_file" ]]; then
    log_info "Aplicando patch: ${patch_file}"
    if [[ "${ADM_DRY_RUN}" = "1" ]]; then
      log_warn "[DRY-RUN] (cd '${build_dir}' && patch -p1 < '${patch_file}')"
    else
      (
        cd "$build_dir"
        patch -p1 < "$patch_file"
      )
    fi
  fi
}

###############################################################################
# Hooks
###############################################################################

run_hook() {
  local full="$1"
  local hook="$2"
  local hook_path
  hook_path=$(pkg_hook_path "$full" "$hook")
  if [[ -f "$hook_path" ]]; then
    log_info "Executando hook ${hook} -> ${hook_path}"
    if [[ "${ADM_DRY_RUN}" = "1" ]]; then
      log_warn "DRY-RUN: ${ADM_HOOK_SHELL} '${hook_path}'"
    else
      "${ADM_HOOK_SHELL}" "$hook_path"
    fi
  fi
}

###############################################################################
# Build + install + strip + pacote
###############################################################################

build_and_install_pkg() {
  local full="$1"
  load_pkg_metadata "$full"

  setup_profile

  # overrides por pacote
  if [[ -n "${PKG_TARGET_TRIPLET:-}" ]]; then
    TARGET_TRIPLET="${PKG_TARGET_TRIPLET}"
  fi
  if [[ -n "${PKG_CFLAGS_EXTRA:-}" ]]; then
    CFLAGS="${CFLAGS} ${PKG_CFLAGS_EXTRA}"
    CXXFLAGS="${CXXFLAGS} ${PKG_CFLAGS_EXTRA}"
  fi
  if [[ -n "${PKG_LDFLAGS_EXTRA:-}" ]]; then
    LDFLAGS="${LDFLAGS} ${PKG_LDFLAGS_EXTRA}"
  fi

  fetch_source "$full"
  extract_source "$full"

  local build_dir
  build_dir=$(pkg_build_dir "$full")
  local destdir
  destdir=$(pkg_destdir "$full")
  run_cmd "mkdir -p '${destdir}'"

  # Pre-install hook
  run_hook "$full" "pre_install"

  local state_dir
  state_dir=$(pkg_state_dir "$full")
  mkdir -p "$state_dir"

  if [[ ! -f "${state_dir}/built" ]]; then
    log_info "Configurando e compilando ${PKG_NAME}-${PKG_VERSION}..."

    if [[ "${ADM_DRY_RUN}" = "1" ]]; then
      # Mostrar comandos que seriam executados
      local cfg_preview=" ./configure"
      if [[ -n "${ADM_CONFIGURE_ARGS_COMMON:-}" ]]; then
        cfg_preview+=" ${ADM_CONFIGURE_ARGS_COMMON}"
      else
        cfg_preview+=" --host='${TARGET_TRIPLET}' --build='${TARGET_TRIPLET}' --prefix=/usr --sysconfdir=/etc --localstatedir=/var"
      fi
      if declare -p PKG_CONFIGURE_OPTS >/dev/null 2>&1; then
        cfg_preview+=" ${PKG_CONFIGURE_OPTS[*]}"
      fi
      log_warn "[DRY-RUN] (cd '${build_dir}' &&${cfg_preview})"

      local make_preview=" make -j'$(nproc)'"
      if declare -p PKG_MAKE_OPTS >/dev/null 2>&1; then
        make_preview+=" ${PKG_MAKE_OPTS[*]}"
      fi
      log_warn "[DRY-RUN] (cd '${build_dir}' &&${make_preview})"
    else
      (
        cd "$build_dir"

        # Monta ./configure com argumentos comuns + específicos
        local cfg_args=()
        if [[ -n "${ADM_CONFIGURE_ARGS_COMMON:-}" ]]; then
          # shellcheck disable=SC2206
          cfg_args=(${ADM_CONFIGURE_ARGS_COMMON})
        else
          cfg_args=(
            "--host=${TARGET_TRIPLET}"
            "--build=${TARGET_TRIPLET}"
            "--prefix=/usr"
            "--sysconfdir=/etc"
            "--localstatedir=/var"
          )
        fi

        if declare -p PKG_CONFIGURE_OPTS >/dev/null 2>&1; then
          # shellcheck disable=SC2154
          cfg_args+=("${PKG_CONFIGURE_OPTS[@]}")
        fi

        run_cmd ./configure "${cfg_args[@]}"

        # Monta make com -j + PKG_MAKE_OPTS
        local make_args=( "-j$(nproc)" )
        if declare -p PKG_MAKE_OPTS >/dev/null 2>&1; then
          # shellcheck disable=SC2154
          make_args+=("${PKG_MAKE_OPTS[@]}")
        fi

        run_cmd make "${make_args[@]}"
      )
      touch "${state_dir}/built"
    fi
  else
    log_info "Já marcado como built; pulando passo de compilação"
  fi

  log_info "Instalando em DESTDIR: ${destdir}"
  if [[ "${ADM_DRY_RUN}" = "1" ]]; then
    local make_install_preview=" make DESTDIR='${destdir}' install"
    if declare -p PKG_MAKE_INSTALL_OPTS >/dev/null 2>&1; then
      # shellcheck disable=SC2154
      make_install_preview=" make DESTDIR='${destdir}' ${PKG_MAKE_INSTALL_OPTS[*]} install"
    fi
    log_warn "[DRY-RUN] (cd '${build_dir}' &&${make_install_preview})"
  else
    (
      cd "$build_dir"
      local mi_args=( "DESTDIR=${destdir}" )
      if declare -p PKG_MAKE_INSTALL_OPTS >/dev/null 2>&1; then
        # shellcheck disable=SC2154
        mi_args+=("${PKG_MAKE_INSTALL_OPTS[@]}")
      fi
      run_cmd make "${mi_args[@]}" install
    )
  fi

  log_info "Executando strip em binários e libs..."
  if [[ "${ADM_DRY_RUN}" = "1" ]]; then
    log_warn "[DRY-RUN] strip em arquivos ELF sob ${destdir}"
  else
    find "${destdir}" -type f -print0 | while IFS= read -r -d '' f; do
      if file "$f" | grep -q "ELF"; then
        "${STRIP:-strip}" --strip-unneeded "$f" 2>/dev/null || true
      fi
    done
  fi

  # Empacotamento
  local tarball
  tarball=$(pkg_tarball_path "$full" "${PKG_VERSION}")
  log_info "Empacotando em ${tarball}"
  if [[ "${ADM_DRY_RUN}" = "1" ]]; then
    log_warn "[DRY-RUN] tar -I 'zstd -19' -cf '${tarball}' -C '${destdir}' ."
  else
    run_cmd tar -I 'zstd -19' -cf "${tarball}" -C "${destdir}" .
  fi

  # Cópia para rootfs
  log_info "Instalando em rootfs: ${ADM_ROOTFS}"
  if [[ "${ADM_DRY_RUN}" = "1" ]]; then
    log_warn "[DRY-RUN] rsync -a '${destdir}/' '${ADM_ROOTFS}/'"
  else
    run_cmd rsync -a "${destdir}/" "${ADM_ROOTFS}/"
  fi

  # Registro
  register_install "$full" "$destdir"

  # Execução de comandos pós-instalação (dentro do rootfs)
  if [[ -n "${PKG_POST_INSTALL_CMDS:-}" ]]; then
    log_info "Executando PKG_POST_INSTALL_CMDS dentro de ${ADM_ROOTFS}"
    if [[ "${ADM_DRY_RUN}" = "1" ]]; then
      log_warn "[DRY-RUN] (cd '${ADM_ROOTFS}' && /bin/sh -c '${PKG_POST_INSTALL_CMDS}')"
    else
      (
        cd "${ADM_ROOTFS}"
        /bin/sh -c "${PKG_POST_INSTALL_CMDS}"
      )
    fi
  fi

  # Post-install hook
  run_hook "$full" "post_install"

  log_ok "Pacote ${full} (${PKG_VERSION}) instalado com sucesso."
}

register_install() {
  local full="$1"
  local destdir="$2"
  local dbdir
  dbdir=$(pkg_db_dir "$full")
  mkdir -p "$dbdir"

  log_info "Registrando instalação em ${dbdir}"
  if [[ "${ADM_DRY_RUN}" = "1" ]]; then
    log_warn "DRY-RUN: registro de arquivos em db"
    return
  fi

  find "${destdir}" -mindepth 1 -printf "/%P\n" | sort > "${dbdir}/files.list"

  {
    echo "name=${PKG_NAME}"
    echo "version=${PKG_VERSION}"
    echo "category=${PKG_CATEGORY}"
    echo "profile=${ADM_PROFILE}"
    echo "url=${PKG_URL}"
    echo -n "depends="
    printf "%s " "${PKG_DEPENDS[@]}"
    echo
  } > "${dbdir}/meta"

  # Atualizar reverse deps (requires)
  for dep in "${PKG_DEPENDS[@]}"; do
    local dep_full
    dep_full=$(normalize_pkg_name "$dep")
    local dep_db
    dep_db=$(pkg_db_dir "$dep_full")
    mkdir -p "$dep_db"
    local req_file="${dep_db}/required_by"
    touch "$req_file"
    if ! grep -qx "${full}" "$req_file"; then
      echo "${full}" >> "$req_file"
    fi
  done
}

###############################################################################
# Dependências (topological sort via Kahn)
###############################################################################

collect_deps_recursive() {
  local full="$1"
  local -n out_set="$2"

  load_pkg_metadata "$full"
  out_set["$full"]=1
  for d in "${PKG_DEPENDS[@]}"; do
    local dep_full
    dep_full=$(normalize_pkg_name "$d")
    if [[ -z "${out_set[$dep_full]:-}" ]]; then
      collect_deps_recursive "$dep_full" out_set
    fi
  done
}

topo_sort_kahn() {
  # Entrada: lista de pacotes em stdin (um por linha)
  # Saída: ordem topológica em stdout
  local pkgs=()
  while read -r p; do
    [[ -z "$p" ]] && continue
    pkgs+=("$p")
  done

  declare -A indeg
  declare -A deps

  # inicializar
  for p in "${pkgs[@]}"; do
    indeg["$p"]=0
  done

  # calcular indegree
  for p in "${pkgs[@]}"; do
    load_pkg_metadata "$p"
    local d
    for d in "${PKG_DEPENDS[@]}"; do
      local dep_full
      dep_full=$(normalize_pkg_name "$d")
      # apenas conta se estiver no conjunto
      if [[ -n "${indeg[$dep_full]:-}" ]]; then
        deps["$p"]+="${dep_full} "
        indeg["$p"]=$(( indeg["$p"] + 1 ))
      fi
    done
  done

  local -a queue=()
  for p in "${pkgs[@]}"; do
    if [[ "${indeg[$p]}" -eq 0 ]]; then
      queue+=("$p")
    fi
  done

  local -a result=()
  while [[ ${#queue[@]} -gt 0 ]]; do
    local n="${queue[0]}"
    queue=("${queue[@]:1}")
    result+=("$n")
    for m in ${deps["$n"]:-}; do
      indeg["$m"]=$(( indeg["$m"] - 1 ))
      if [[ "${indeg[$m]}" -eq 0 ]]; then
        queue+=("$m")
      fi
    done
  done

  if [[ "${#result[@]}" -ne "${#pkgs[@]}" ]]; then
    log_error "Ciclo de dependências detectado! Conjunto: ${pkgs[*]}"
    exit 1
  fi

  printf "%s\n" "${result[@]}"
}

build_with_deps() {
  local full="$1"

  declare -A dep_set=()
  collect_deps_recursive "$full" dep_set

  log_info "Calculando ordem topológica de build..."
  local order
  order=$(printf "%s\n" "${!dep_set[@]}" | topo_sort_kahn)

  log_info "Ordem de build: $(echo "$order" | tr '\n' ' ')"
  while read -r p; do
    [[ -z "$p" ]] && continue
    log_info ">>> Construindo dependência: $p"
    build_and_install_pkg "$p"
  done <<< "$order"
}

###############################################################################
# Uninstall com resolução reversa de deps
###############################################################################

uninstall_pkg() {
  local full="$1"
  local dbdir
  dbdir=$(pkg_db_dir "$full")
  if [[ ! -d "$dbdir" ]]; then
    log_warn "Pacote $full não está registrado como instalado."
    return
  fi

  # Checar se é requerido por outros
  local req_file="${dbdir}/required_by"
  if [[ -f "$req_file" ]]; then
    local reqs
    reqs=$(grep -v -E '^\s*$' "$req_file" || true)
    if [[ -n "$reqs" ]]; then
      log_warn "Pacote $full é requerido por:"
      echo "$reqs" | sed 's/^/  - /'
      log_warn "Removendo mesmo assim (resolução reversa deve tratar ordem)."
    fi
  fi

  # Pre-uninstall hook
  run_hook "$full" "pre_uninstall"

  # Remove arquivos
  local files_list="${dbdir}/files.list"
  if [[ -f "$files_list" ]]; then
    log_info "Removendo arquivos de $full"
    if [[ "${ADM_DRY_RUN}" = "1" ]]; then
      log_warn "DRY-RUN: remoção dos arquivos listados em ${files_list}"
    else
      while read -r path; do
        [[ -z "$path" ]] && continue
        local f="${ADM_ROOTFS}${path}"
        if [[ -e "$f" || -L "$f" ]]; then
          rm -f "$f" || true
        fi
      done < "$files_list"
    fi
  else
    log_warn "files.list não encontrado em $dbdir"
  fi

  # Limpar reverse deps
  if [[ "${ADM_DRY_RUN}" != "1" ]]; then
    for d in "${ADM_DB_DIR}"/*/*; do
      [[ -d "$d" ]] || continue
      local rf="${d}/required_by"
      [[ -f "$rf" ]] || continue
      sed -i "\|^${full}$|d" "$rf" || true
    done
  fi

  # Post-uninstall hook
  run_hook "$full" "post_uninstall"

  if [[ "${ADM_DRY_RUN}" != "1" ]]; then
    rm -rf "$dbdir"
  fi
  log_ok "Pacote $full desinstalado."
}

# Remove um pacote com recursão reversa (desinstalar quem depende dele antes)
uninstall_with_reverse_deps() {
  local full="$1"

  # Construir grafo de reverse deps a partir de DB
  declare -A graph indeg allpkgs

  # Carregar todos pacotes instalados
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    local p
    p="${d#${ADM_DB_DIR}/}"
    allpkgs["$p"]=1
    indeg["$p"]=0
  done < <(find "${ADM_DB_DIR}" -mindepth 2 -maxdepth 2 -type d)

  # Construir grafo: arestas A->B se B depende de A
  for p in "${!allpkgs[@]}"; do
    local meta="${ADM_DB_DIR}/${p}/meta"
    [[ -f "$meta" ]] || continue
    local deps
    deps=$(grep '^depends=' "$meta" | cut -d= -f2- || true)
    for d in $deps; do
      local dep_full
      dep_full=$(normalize_pkg_name "$d" || true)
      [[ -n "$dep_full" ]] || continue
      if [[ -n "${allpkgs[$dep_full]:-}" ]]; then
        graph["$dep_full"]+="${p} "
        indeg["$p"]=$(( indeg["$p"] + 1 ))
      fi
    done
  done

  # Coletar subgrafo contendo "full" e todos que dependem dele (transitivamente)
  declare -A sub
  local queue=("$full")
  while [[ ${#queue[@]} -gt 0 ]]; do
    local n="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n "${sub[$n]:-}" ]] && continue
    sub["$n"]=1
    for m in ${graph["$n"]:-}; do
      queue+=("$m")
    done
  done

  # Ordenar topologicamente subgrafo (reverse deps) e desinstalar na ordem reversa
  # Para reverse deps, queremos que dependentes sejam removidos antes.
  # Aqui basta usar Kahn no subgrafo e depois inverter a ordem final.
  declare -A indeg_sub
  for p in "${!sub[@]}"; do
    indeg_sub["$p"]=0
  done
  for p in "${!sub[@]}"; do
    for m in ${graph["$p"]:-}; do
      if [[ -n "${sub[$m]:-}" ]]; then
        indeg_sub["$m"]=$(( indeg_sub["$m"] + 1 ))
      fi
    done
  done

  local -a q2=()
  for p in "${!sub[@]}"; do
    if [[ "${indeg_sub[$p]}" -eq 0 ]]; then
      q2+=("$p")
    fi
  done

  local -a result=()
  while [[ ${#q2[@]} -gt 0 ]]; do
    local n="${q2[0]}"
    q2=("${q2[@]:1}")
    result+=("$n")
    for m in ${graph["$n"]:-}; do
      if [[ -n "${sub[$m]:-}" ]]; then
        indeg_sub["$m"]=$(( indeg_sub["$m"] - 1 ))
        if [[ "${indeg_sub[$m]}" -eq 0 ]]; then
          q2+=("$m")
        fi
      fi
    done
  done

  # Se tiver ciclo no subgrafo, aborta
  if [[ "${#result[@]}" -ne "${#sub[@]}" ]]; then
    log_error "Ciclo em reverse deps na árvore de $full"
    exit 1
  fi

  # Desinstalar em ordem reversa
  log_info "Ordem de desinstalação (dependentes primeiro):"
  printf '  %s\n' "${result[@]}"

  for ((i=${#result[@]}-1; i>=0; i--)); do
    uninstall_pkg "${result[i]}"
  done
}

###############################################################################
# Rebuild
###############################################################################

rebuild_world() {
  log_info "Rebuild do mundo: todos pacotes instalados"
  local pkgs=()
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    pkgs+=("${d#${ADM_DB_DIR}/}")
  done < <(find "${ADM_DB_DIR}" -mindepth 2 -maxdepth 2 -type d)

  # top-sort com base nas deps atuais
  local order
  order=$(printf "%s\n" "${pkgs[@]}" | topo_sort_kahn)
  log_info "Ordem de rebuild: $(echo "$order" | tr '\n' ' ')"

  while read -r p; do
    [[ -z "$p" ]] && continue
    log_info ">>> Rebuild: $p"
    build_and_install_pkg "$p"
  done <<< "$order"
}

rebuild_pkg() {
  local full="$1"
  log_info "Rebuild de $full e deps"
  build_with_deps "$full"
}

###############################################################################
# Info, search, list
###############################################################################

cmd_info() {
  local full="$1"
  local script
  script=$(pkg_script_path "$full")
  if [[ ! -f "$script" ]]; then
    log_error "Script não encontrado: $script"
    exit 1
  fi

  load_pkg_metadata "$full"
  local dbdir
  dbdir=$(pkg_db_dir "$full")

  echo "Pacote:    $full"
  echo "Nome:      ${PKG_NAME}"
  echo "Versão:    ${PKG_VERSION}"
  echo "Categoria: ${PKG_CATEGORY}"
  echo "URL:       ${PKG_URL}"
  echo "Perfil:    ${ADM_PROFILE}"
  echo "Depende:   ${PKG_DEPENDS[*]:-(nenhuma)}"
  if [[ -d "$dbdir" ]]; then
    echo "Status:    instalado"
    if [[ -f "${dbdir}/files.list" ]]; then
      echo "Arquivos instalados: $(wc -l < "${dbdir}/files.list")"
    fi
  else
    echo "Status:    não instalado"
  fi
}

cmd_search() {
  local pattern="$1"
  log_info "Procurando por pacotes que casam com '${pattern}'..."
  find "${ADM_PACKAGES_DIR}" -mindepth 2 -maxdepth 2 -type d -print \
    | sed "s|^${ADM_PACKAGES_DIR}/||" \
    | grep -i --color=never "${pattern}" || true
}

cmd_list_installed() {
  log_info "Pacotes instalados:"
  find "${ADM_DB_DIR}" -mindepth 2 -maxdepth 2 -type d -print \
    | sed "s|^${ADM_DB_DIR}/||" \
    | sort
}

cmd_graph_deps() {
  local full="$1"
  declare -A dep_set=()
  collect_deps_recursive "$full" dep_set
  topo_sort_kahn <<< "$(printf "%s\n" "${!dep_set[@]}")"
}

###############################################################################
# Update (git)
###############################################################################

cmd_update() {
  if [[ -d "${ADM_PACKAGES_DIR}/.git" ]]; then
    log_info "Atualizando receitas em ${ADM_PACKAGES_DIR} (git pull)..."
    if [[ "${ADM_DRY_RUN}" = "1" ]]; then
      log_warn "DRY-RUN: git -C '${ADM_PACKAGES_DIR}' pull"
    else
      git -C "${ADM_PACKAGES_DIR}" pull --ff-only
    fi
  else
    log_info "Clonando receitas em ${ADM_PACKAGES_DIR} a partir de ${ADM_GIT_REPO}"
    if [[ "${ADM_DRY_RUN}" = "1" ]]; then
      log_warn "DRY-RUN: git clone '${ADM_GIT_REPO}' '${ADM_PACKAGES_DIR}'"
    else
      git clone "${ADM_GIT_REPO}" "${ADM_PACKAGES_DIR}"
    fi
  fi
}

###############################################################################
# Dispatch
###############################################################################

main() {
  local rest
  rest=$(parse_global_args "$@")
  # shellcheck disable=SC2086
  set -- $rest

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    update)
      cmd_update
      ;;
    build|install)
      if [[ $# -lt 1 ]]; then
        usage; exit 1
      fi
      local full
      full=$(normalize_pkg_name "$1")
      build_with_deps "$full"
      ;;
    uninstall)
      if [[ $# -lt 1 ]]; then
        usage; exit 1
      fi
      local full
      full=$(normalize_pkg_name "$1")
      uninstall_with_reverse_deps "$full"
      ;;
    rebuild)
      if [[ $# -eq 0 || "$1" = "world" ]]; then
        rebuild_world
      else
        local full
        full=$(normalize_pkg_name "$1")
        rebuild_pkg "$full"
      fi
      ;;
    info)
      if [[ $# -lt 1 ]]; then
        usage; exit 1
      fi
      cmd_info "$(normalize_pkg_name "$1")"
      ;;
    search)
      if [[ $# -lt 1 ]]; then
        usage; exit 1
      fi
      cmd_search "$1"
      ;;
    list-installed)
      cmd_list_installed
      ;;
    graph-deps)
      if [[ $# -lt 1 ]]; then
        usage; exit 1
      fi
      cmd_graph_deps "$(normalize_pkg_name "$1")"
      ;;
    dry-run)
      ADM_DRY_RUN=1
      # Executa um comando ADM em modo seco
      main "$@"
      ;;
    ""|help|-h|--help)
      usage
      ;;
    *)
      log_error "Comando desconhecido: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
