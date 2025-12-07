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

setup_profile() {
  case "${ADM_PROFILE}" in
    glibc)
      TARGET_TRIPLET="${TARGET_TRIPLET:-x86_64-linux-gnu}"
      CFLAGS_COMMON="-O2 -pipe"
      ;;
    musl)
      TARGET_TRIPLET="${TARGET_TRIPLET:-x86_64-linux-musl}"
      CFLAGS_COMMON="-O2 -pipe"
      ;;
    aggressive)
      TARGET_TRIPLET="${TARGET_TRIPLET:-x86_64-linux-gnu}"
      CFLAGS_COMMON="-O3 -march=native -mtune=native -pipe -fomit-frame-pointer -flto"
      ;;
    *)
      log_error "Perfil desconhecido: ${ADM_PROFILE}"
      exit 1
      ;;
  esac

  export TARGET_TRIPLET
  export CC="${CC:-${TARGET_TRIPLET}-gcc}"
  export CXX="${CXX:-${TARGET_TRIPLET}-g++}"
  export AR="${AR:-${TARGET_TRIPLET}-ar}"
  export RANLIB="${RANLIB:-${TARGET_TRIPLET}-ranlib}"

  export CFLAGS="${CFLAGS:-${CFLAGS_COMMON}}"
  export CXXFLAGS="${CXXFLAGS:-${CFLAGS_COMMON}}"
  export LDFLAGS="${LDFLAGS:-}"
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
  local tarball_basename
  tarball_basename="$(basename "${PKG_URL}")"
  local tarball_path="${ADM_CACHE_DIR}/${tarball_basename}"

  if [[ -f "$tarball_path" ]]; then
    log_info "Tarball já em cache: $tarball_path"
  else
    log_info "Baixando ${PKG_URL} -> ${tarball_path}"
    if command -v curl >/dev/null 2>&1; then
      run_cmd "curl -L '${PKG_URL}' -o '${tarball_path}'"
    elif command -v wget >/dev/null 2>&1; then
      run_cmd "wget '${PKG_URL}' -O '${tarball_path}'"
    else
      log_error "Nem curl nem wget encontrados"
      exit 1
    fi
  fi

  if [[ -n "${PKG_SHA256:-}" ]]; then
    log_info "Verificando SHA256..."
    if [[ "${ADM_DRY_RUN}" = "1" ]]; then
      log_warn "DRY-RUN: pular verificação de checksum"
    else
      echo "${PKG_SHA256}  ${tarball_path}" | sha256sum -c -
    fi
  fi
}

extract_source() {
  local full="$1"
  local build_dir
  build_dir=$(pkg_build_dir "$full")
  local tarball_basename
  tarball_basename="$(basename "${PKG_URL}")"
  local tarball_path="${ADM_CACHE_DIR}/${tarball_basename}"

  if [[ -d "$build_dir" ]]; then
    log_info "Diretório de build já existe: $build_dir (retomando)"
  else
    run_cmd "mkdir -p '${build_dir}'"
    log_info "Extraindo ${tarball_path} para ${build_dir}"
    run_cmd "tar -xf '${tarball_path}' -C '${build_dir}' --strip-components=1"
  fi

  local patch_file
  patch_file=$(pkg_patch_path "$full")
  if [[ -f "$patch_file" ]]; then
    log_info "Aplicando patch: ${patch_file}"
    if [[ "${ADM_DRY_RUN}" = "1" ]]; then
      log_warn "DRY-RUN: patch -p1 < '${patch_file}'"
    else
      (cd "$build_dir" && patch -p1 < "$patch_file")
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
      log_warn "DRY-RUN: ./configure && make"
    else
      (
        cd "$build_dir"
        ./configure \
          --host="${TARGET_TRIPLET}" \
          --build="${TARGET_TRIPLET}" \
          --prefix=/usr \
          --sysconfdir=/etc \
          --localstatedir=/var
        make -j"$(nproc)"
      )
    fi
    [[ "${ADM_DRY_RUN}" = "1" ]] || touch "${state_dir}/built"
  else
    log_info "Já marcado como built; pulando passo de compilação"
  fi

  log_info "Instalando em DESTDIR: ${destdir}"
  if [[ "${ADM_DRY_RUN}" = "1" ]]; then
    log_warn "DRY-RUN: make DESTDIR='${destdir}' install"
  else
    (
      cd "$build_dir"
      make DESTDIR="${destdir}" install
    )
  fi

  log_info "Executando strip em binários e libs..."
  if [[ "${ADM_DRY_RUN}" = "1" ]]; then
    log_warn "DRY-RUN: strip em arquivos ELF"
  else
    find "${destdir}" -type f -print0 | while IFS= read -r -d '' f; do
      if file "$f" | grep -q "ELF"; then
        strip --strip-unneeded "$f" || true
      fi
    done
  fi

  # Empacotamento
  local tarball
  tarball=$(pkg_tarball_path "$full" "${PKG_VERSION}")
  log_info "Empacotando em ${tarball}"
  if [[ "${ADM_DRY_RUN}" = "1" ]]; then
    log_warn "DRY-RUN: tar -I 'zstd -19' -cf '${tarball}' -C '${destdir}' ."
  else
    tar -I 'zstd -19' -cf "${tarball}" -C "${destdir}" .
  fi

  # Cópia para rootfs
  log_info "Instalando em rootfs: ${ADM_ROOTFS}"
  if [[ "${ADM_DRY_RUN}" = "1" ]]; then
    log_warn "DRY-RUN: rsync -a '${destdir}/' '${ADM_ROOTFS}/'"
  else
    rsync -a "${destdir}/" "${ADM_ROOTFS}/"
  fi

  # Registro
  register_install "$full" "$destdir"

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
