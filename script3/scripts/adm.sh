#!/usr/bin/env bash
# Gerenciador de build para rootfs Linux From Scratch independente (glibc/musl)

set -euo pipefail

##############################################################################
# Configuração global
##############################################################################

ADM_ROOT="/opt/adm"
ADM_BIN="${ADM_ROOT}/bin"
ADM_PACKAGES_DIR="${ADM_ROOT}/packages"
ADM_CACHE_SRC="${ADM_ROOT}/cache/src"
ADM_CACHE_PKG="${ADM_ROOT}/cache/pkg"
ADM_LOG_DIR="${ADM_ROOT}/logs"
ADM_HOOKS_DIR="${ADM_ROOT}/hooks"
ADM_STATE_DIR="${ADM_ROOT}/state"
ADM_BUILD_DIR="${ADM_ROOT}/build"

ADM_DEFAULT_PROFILE="glibc"
ADM_JOBS="${ADM_JOBS:-$(nproc)}"     # paralelismo
ADM_RESUME="${ADM_RESUME:-1}"       # retomada de construção (1=on, 0=off)

# Ajuste para o seu repositório de pacotes
ADM_REMOTE_PACKAGES_URL="${ADM_REMOTE_PACKAGES_URL:-git@github.com:usuario/seu-repo-pacotes.git}"

# Variáveis que serão setadas conforme o perfil
ADM_PROFILE=""
ADM_ROOTFS=""
ADM_TOOLS_DIR=""

##############################################################################
# Cores e logging
##############################################################################

CLR_RESET="\033[0m"
CLR_INFO="\033[1;34m"
CLR_WARN="\033[1;33m"
CLR_ERR="\033[1;31m"
CLR_OK="\033[1;32m"

log_info()  { echo -e "${CLR_INFO}[INFO]${CLR_RESET} $*"; }
log_warn()  { echo -e "${CLR_WARN}[WARN]${CLR_RESET} $*"; }
log_err()   { echo -e "${CLR_ERR}[ERROR]${CLR_RESET} $*"; }
log_ok()    { echo -e "${CLR_OK}[OK]${CLR_RESET} $*"; }

# Tratamento de erros não capturados (evita erros silenciosos)
trap 'log_err "Falha na linha ${LINENO}, comando: ${BASH_COMMAND}"' ERR

##############################################################################
# Diretórios padrão
##############################################################################

ensure_dirs() {
    mkdir -p \
        "${ADM_BIN}" \
        "${ADM_PACKAGES_DIR}" \
        "${ADM_CACHE_SRC}" \
        "${ADM_CACHE_PKG}" \
        "${ADM_LOG_DIR}" \
        "${ADM_HOOKS_DIR}"/{pre-fetch.d,post-fetch.d,pre-build.d,post-build.d,pre-install.d,post-install.d} \
        "${ADM_ROOT}/rootfs-glibc/tools" \
        "${ADM_ROOT}/rootfs-musl/tools" \
        "${ADM_STATE_DIR}" \
        "${ADM_BUILD_DIR}"
}

##############################################################################
# Logging para arquivo
##############################################################################

ADM_RUN_ID=""
ADM_RUN_LOG=""

setup_logging() {
    mkdir -p "${ADM_LOG_DIR}"
    ADM_RUN_ID="$(date +%Y%m%d-%H%M%S)"
    ADM_RUN_LOG="${ADM_LOG_DIR}/${ADM_RUN_ID}.log"
    export ADM_RUN_ID ADM_RUN_LOG

    # Redireciona stdout/stderr para tee (terminal + arquivo)
    exec > >(tee -a "${ADM_RUN_LOG}") 2>&1

    log_info "Log desta execução: ${ADM_RUN_LOG}"
}

##############################################################################
# Verificação de ferramentas necessárias
##############################################################################

check_cmd() {
    local c="$1"
    command -v "$c" >/dev/null 2>&1 || {
        log_err "Ferramenta obrigatória não encontrada: ${c}"
        exit 1
    }
}

check_required_tools() {
    check_cmd bash
    check_cmd curl
    check_cmd git
    check_cmd tar
    check_cmd patch
    check_cmd sha256sum
    check_cmd md5sum
    check_cmd tee
    # zstd e xz são opcionais, mas avisamos se não existirem
    if ! command -v zstd >/dev/null 2>&1; then
        log_warn "zstd não encontrado (tar.zst indisponível, será usado fallback tar.xz se xz estiver presente)."
    fi
    if ! command -v xz >/dev/null 2>&1; then
        log_warn "xz não encontrado (fallback tar.xz indisponível, apenas tar sem compressão será usado)."
    fi
}

##############################################################################
# Perfis: glibc / musl
##############################################################################

set_profile() {
    local profile="${1:-$ADM_DEFAULT_PROFILE}"

    case "$profile" in
        glibc)
            ADM_PROFILE="glibc"
            ADM_ROOTFS="${ADM_ROOT}/rootfs-glibc"
            ADM_TOOLS_DIR="${ADM_ROOTFS}/tools"
            ;;
        musl)
            ADM_PROFILE="musl"
            ADM_ROOTFS="${ADM_ROOT}/rootfs-musl"
            ADM_TOOLS_DIR="${ADM_ROOTFS}/tools"
            ;;
        *)
            log_err "Perfil inválido: $profile (use glibc ou musl)"
            exit 1
            ;;
    esac

    export ADM_PROFILE ADM_ROOTFS ADM_TOOLS_DIR
    mkdir -p "${ADM_ROOTFS}" "${ADM_TOOLS_DIR}"
    log_info "Perfil ativo: ${ADM_PROFILE} (ROOTFS=${ADM_ROOTFS}, TOOLS=${ADM_TOOLS_DIR})"
}

##############################################################################
# Hooks
##############################################################################

run_hooks() {
    local stage="$1"   # pre-fetch, post-fetch, pre-build, post-build, pre-install, post-install
    local pkg="$2"

    local dir="${ADM_HOOKS_DIR}/${stage}.d"
    [[ -d "$dir" ]] || return 0

    for hook in "$dir"/*; do
        [[ -x "$hook" ]] || continue
        log_info "Executando hook ${stage}: $(basename "$hook") (pkg=${pkg})"
        ADM_HOOK_STAGE="$stage" ADM_HOOK_PKG="$pkg" "$hook"
    done
}

##############################################################################
# Funções auxiliares de pacote
##############################################################################

pkg_find_script() {
    local pkg="$1"   # formato categoria/pacote
    local path="${ADM_PACKAGES_DIR}/${pkg}/build.sh"
    if [[ ! -f "$path" ]]; then
        log_err "Script de build não encontrado para pacote '${pkg}': ${path}"
        exit 1
    fi
    echo "$path"
}

pkg_load_metadata() {
    local pkg="$1"
    local script
    script="$(pkg_find_script "$pkg")"

    # Limpa variáveis relacionadas a pacote anterior
    unset PKG_NAME PKG_VERSION PKG_RELEASE PKG_CATEGORY
    unset PKG_SOURCES PKG_SHA256 PKG_MD5 PKG_DEPENDS PKG_PROFILE_SUPPORT

    # shellcheck source=/dev/null
    . "$script" metadata

    # Valida definição mínima
    : "${PKG_NAME:?PKG_NAME não definido em ${script}}"
    : "${PKG_VERSION:?PKG_VERSION não definido em ${script}}"
    : "${PKG_RELEASE:?PKG_RELEASE não definido em ${script}}"

    # Garante que arrays existem (mesmo vazias)
    : "${PKG_SOURCES:=()}"
    : "${PKG_SHA256:=()}"
    : "${PKG_MD5:=()}"
    : "${PKG_DEPENDS:=()}"
    : "${PKG_PROFILE_SUPPORT:=()}"
}

##############################################################################
# Download, cache e verificação de checksums
# - Suporta:
#   * https/http (arquivos)
#   * git (git://, git+https://, https://...git, github, gitlab)
##############################################################################

# Baixa (ou atualiza) repositório git em cache e cria working tree
fetch_git_repo() {
    local url="$1"
    local pkg="$2"

    local repo_url="$url"
    # remove prefixo git+
    repo_url="${repo_url#git+}"

    local fragment=""
    if [[ "$repo_url" == *"#"* ]]; then
        fragment="${repo_url#*#}"
        repo_url="${repo_url%%#*}"
    fi

    local name
    name="$(basename "${repo_url}" .git)"
    local mirror="${ADM_CACHE_SRC}/${pkg}/${name}.git"
    local work="${ADM_CACHE_SRC}/${pkg}/${name}-work"

    mkdir -p "${ADM_CACHE_SRC}/${pkg}"

    if [[ -d "$mirror" ]]; then
        log_info "Atualizando mirror git: ${repo_url}"
        (cd "$mirror" && git fetch --all --tags --prune)
    else
        log_info "Clonando mirror git: ${repo_url} -> ${mirror}"
        git clone --mirror "$repo_url" "$mirror"
    fi

    # recria working tree sempre que chamado (garante estado limpo)
    rm -rf "$work"
    log_info "Criando working tree git: ${work}"
    git clone "$mirror" "$work"

    if [[ -n "$fragment" ]]; then
        # fragmento pode ser: commit=<hash>, tag=<tag>, branch=<nome>, ou ref direto
        local ref_type ref_value
        if [[ "$fragment" == *=* ]]; then
            ref_type="${fragment%%=*}"
            ref_value="${fragment#*=}"
        else
            ref_type="ref"
            ref_value="$fragment"
        fi
        (
            cd "$work"
            case "$ref_type" in
                commit)
                    log_info "Checkout por commit: ${ref_value}"
                    git checkout "$ref_value"
                    ;;
                tag)
                    log_info "Checkout por tag: ${ref_value}"
                    git checkout "tags/${ref_value}"
                    ;;
                branch)
                    log_info "Checkout por branch: ${ref_value}"
                    git checkout "$ref_value"
                    ;;
                ref|*)
                    log_info "Checkout por ref: ${ref_value}"
                    git checkout "$ref_value"
                    ;;
            esac
        )
    fi
}

is_git_source() {
    local url="$1"
    if [[ "$url" =~ ^git:// ]] || [[ "$url" =~ ^git\+https:// ]] || [[ "$url" =~ \.git($|#) ]]; then
        return 0
    fi
    return 1
}

download_with_check_file() {
    local url="$1"
    local dest="$2"
    local sha="$3"
    local md5="$4"

    local max_retry=3
    local attempt=1

    while (( attempt <= max_retry )); do
        if [[ -f "$dest" ]]; then
            log_info "Usando cache de source: $dest"
        else
            log_info "Baixando: $url -> $dest (tentativa ${attempt}/${max_retry})"
            curl -L --fail -o "$dest" "$url" || {
                log_warn "Falha no download de $url"
                rm -f "$dest"
                ((attempt++))
                continue
            }
        fi

        # Verificar checksums se fornecidos
        if [[ -n "$sha" ]]; then
            if echo "${sha}  ${dest}" | sha256sum -c -; then
                log_ok "sha256sum OK para $(basename "$dest")"
                return 0
            else
                log_warn "sha256sum incorreto para $(basename "$dest"), removendo e tentando novamente"
                rm -f "$dest"
            fi
        elif [[ -n "$md5" ]]; then
            if echo "${md5}  ${dest}" | md5sum -c -; then
                log_ok "md5sum OK para $(basename "$dest")"
                return 0
            else
                log_warn "md5sum incorreto para $(basename "$dest"), removendo e tentando novamente"
                rm -f "$dest"
            fi
        else
            log_warn "Nenhum checksum fornecido para $(basename "$dest"); aceitando como está"
            return 0
        fi

        ((attempt++))
    done

    log_err "Não foi possível obter um arquivo válido de ${url}"
    exit 1
}

pkg_fetch_sources() {
    local pkg="$1"

    run_hooks "pre-fetch" "$pkg"

    local -n _SRC=PKG_SOURCES
    local -n _SHA=PKG_SHA256
    local -n _MD5=PKG_MD5

    if [[ "${#_SRC[@]}" -eq 0 ]]; then
        log_warn "Pacote '${pkg}' não possui fontes definidas (PKG_SOURCES vazio)"
        run_hooks "post-fetch" "$pkg"
        return 0
    fi

    mkdir -p "${ADM_CACHE_SRC}/${pkg}"

    local i=0
    for url in "${_SRC[@]}"; do
        if is_git_source "$url"; then
            log_info "Fonte git detectada: ${url}"
            fetch_git_repo "$url" "$pkg"
        else
            local filename
            filename="$(basename "${url%%\?*}")"
            local dest="${ADM_CACHE_SRC}/${pkg}/${filename}"

            local sha="${_SHA[$i]:-}"
            local md5="${_MD5[$i]:-}"

            download_with_check_file "$url" "$dest" "$sha" "$md5"
        fi
        ((i++))
    done

    run_hooks "post-fetch" "$pkg"
}

##############################################################################
# Empacotamento binário (.tar.zst com fallback para .tar.xz ou tar puro)
##############################################################################

pkg_make_binary_tarball() {
    local pkg="$1"
    local version="$2"
    local release="$3"
    local destdir="$4"  # ROOTFS do perfil

    mkdir -p "${ADM_CACHE_PKG}"

    local base="${pkg}-${version}-${release}-${ADM_PROFILE}"
    local zst="${ADM_CACHE_PKG}/${base}.tar.zst"
    local xz="${ADM_CACHE_PKG}/${base}.tar.xz"
    local tar_plain="${ADM_CACHE_PKG}/${base}.tar"

    log_info "Empacotando binário: ${base}"

    if command -v zstd >/dev/null 2>&1; then
        tar -C "$destdir" -I 'zstd -19 -T0' -cpf "$zst" . \
            && log_ok "Criado pacote binário: $zst" \
            || { log_err "Falha ao criar pacote .tar.zst"; exit 1; }
    elif command -v xz >/dev/null 2>&1; then
        tar -C "$destdir" -I 'xz -T0 -9e' -cpf "$xz" . \
            && log_ok "Criado pacote binário: $xz" \
            || { log_err "Falha ao criar pacote .tar.xz"; exit 1; }
    else
        log_warn "Nenhum compressor zstd/xz disponível, criando tar sem compressão."
        tar -C "$destdir" -cpf "$tar_plain" . \
            && log_ok "Criado pacote binário: $tar_plain" \
            || { log_err "Falha ao criar pacote .tar"; exit 1; }
    fi
}

pkg_extract_binary_tarball_if_exists() {
    local pkg="$1"
    local version="$2"
    local release="$3"
    local destdir="$4"

    local base="${pkg}-${version}-${release}-${ADM_PROFILE}"
    local zst="${ADM_CACHE_PKG}/${base}.tar.zst"
    local xz="${ADM_CACHE_PKG}/${base}.tar.xz"
    local tar_plain="${ADM_CACHE_PKG}/${base}.tar"

    if [[ -f "$zst" ]]; then
        log_info "Encontrado cache binário: $zst (extraindo)"
        mkdir -p "$destdir"
        tar -C "$destdir" -I zstd -xpf "$zst"
        return 0
    elif [[ -f "$xz" ]]; then
        log_info "Encontrado cache binário: $xz (extraindo)"
        mkdir -p "$destdir"
        tar -C "$destdir" -I xz -xpf "$xz"
        return 0
    elif [[ -f "$tar_plain" ]]; then
        log_info "Encontrado cache binário: $tar_plain (extraindo)"
        mkdir -p "$destdir"
        tar -C "$destdir" -xpf "$tar_plain"
        return 0
    fi

    return 1
}

##############################################################################
# Aplicação automática de patches
##############################################################################

pkg_apply_patches() {
    local pkg="$1"
    local builddir="$2"

    local patch_dir="${ADM_PACKAGES_DIR}/${pkg}"
    shopt -s nullglob
    local patches=("${patch_dir}"/*.patch)
    if (( ${#patches[@]} == 0 )); then
        return 0
    fi
    log_info "Aplicando patches para '${pkg}'"
    (
        cd "$builddir"
        for p in "${patches[@]}"; do
            log_info "Aplicando patch: $(basename "$p")"
            patch -p1 < "$p"
        done
    )
}

##############################################################################
# Estado para retomada de construção
##############################################################################

pkg_state_file() {
    local pkg="$1"
    local dir="${ADM_STATE_DIR}/${ADM_PROFILE}"
    mkdir -p "$dir"
    echo "${dir}/${pkg}.state"
}

pkg_mark_state() {
    local pkg="$1"
    local state="$2"  # building | done
    local file
    file="$(pkg_state_file "$pkg")"
    echo "$state" > "$file"
}

pkg_get_state() {
    local pkg="$1"
    local file
    file="$(pkg_state_file "$pkg")"
    if [[ -f "$file" ]]; then
        cat "$file"
    else
        echo ""
    fi
}

##############################################################################
# Construção de pacote individual
##############################################################################

pkg_build_one() {
    local pkg="$1"
    local script
    script="$(pkg_find_script "$pkg")"

    # Carrega metadata
    pkg_load_metadata "$pkg"

    # Verifica se o perfil atual é suportado
    local -n _PROFILES=PKG_PROFILE_SUPPORT
    if [[ "${#_PROFILES[@]}" -gt 0 ]]; then
        local supported=false
        for p in "${_PROFILES[@]}"; do
            if [[ "$p" == "$ADM_PROFILE" ]]; then
                supported=true
                break
            fi
        done
        if [[ "$supported" != true ]]; then
            log_warn "Pacote '${pkg}' não suporta perfil ${ADM_PROFILE}, ignorando"
            return 0
        fi
    fi

    # Retomada: se já está "done" e ADM_RESUME=1, pula
    if [[ "${ADM_RESUME}" -eq 1 ]]; then
        local st
        st="$(pkg_get_state "$pkg")"
        if [[ "$st" == "done" ]]; then
            log_info "Pulando '${pkg}' (já concluído para perfil ${ADM_PROFILE})"
            return 0
        fi
    fi

    # Tenta usar cache binário
    if pkg_extract_binary_tarball_if_exists "$PKG_NAME" "$PKG_VERSION" "$PKG_RELEASE" "$ADM_ROOTFS"; then
        log_ok "Pacote '${pkg}' instalado a partir de cache binário"
        pkg_mark_state "$pkg" "done"
        return 0
    fi

    # Marca como "building"
    pkg_mark_state "$pkg" "building"

    # Baixa fontes
    pkg_fetch_sources "$pkg"

    # Diretório de build limpo por pacote/perfil
    local builddir="${ADM_BUILD_DIR}/${ADM_PROFILE}/${pkg}"
    rm -rf "$builddir"
    mkdir -p "$builddir"

    # Prepara fontes no builddir
    local -n _SRC=PKG_SOURCES
    for url in "${_SRC[@]:-}"; do
        if is_git_source "$url"; then
            local repo_url="${url#git+}"
            repo_url="${repo_url%%#*}"
            local name
            name="$(basename "${repo_url}" .git)"
            local work="${ADM_CACHE_SRC}/${pkg}/${name}-work"
            if [[ -d "$work" ]]; then
                log_info "Copiando fonte git '${name}-work' para ${builddir}"
                cp -a "$work" "${builddir}/"
            else
                log_warn "Working tree git não encontrado para ${url}, certifique-se de que fetch_git_repo foi executado."
            fi
        else
            local filename
            filename="$(basename "${url%%\?*}")"
            local srcpath="${ADM_CACHE_SRC}/${pkg}/${filename}"

            if [[ "$srcpath" =~ \.(tar\.gz|tgz|tar\.bz2|tar\.xz|tar\.zst|tar)$ ]]; then
                log_info "Extraindo ${srcpath} em ${builddir}"
                case "$srcpath" in
                    *.tar.zst)
                        tar -C "$builddir" -I zstd -xf "$srcpath"
                        ;;
                    *.tar.xz)
                        tar -C "$builddir" -I xz -xf "$srcpath"
                        ;;
                    *)
                        tar -C "$builddir" -xf "$srcpath"
                        ;;
                esac
            else
                # Arquivo simples (não tar) – apenas copia
                cp -a "$srcpath" "$builddir/"
            fi
        fi
    done

    # Aplica patches
    pkg_apply_patches "$pkg" "$builddir"

    run_hooks "pre-build" "$pkg"

    # Chama script de build
    log_info "Construindo pacote '${pkg}' (perfil=${ADM_PROFILE})"
    PKG_BUILD_DIR="$builddir" PKG_ROOTFS="$ADM_ROOTFS" \
        ADM_PROFILE="$ADM_PROFILE" ADM_ROOTFS="$ADM_ROOTFS" \
        ADM_TOOLS_DIR="$ADM_TOOLS_DIR" \
        "$script" build

    run_hooks "post-build" "$pkg"

    run_hooks "pre-install" "$pkg"
    # Instalação deve ser feita pelo próprio build.sh usando DESTDIR=$PKG_ROOTFS
    run_hooks "post-install" "$pkg"

    # Cria pacote binário
    pkg_make_binary_tarball "$PKG_NAME" "$PKG_VERSION" "$PKG_RELEASE" "$ADM_ROOTFS"

    pkg_mark_state "$pkg" "done"
    log_ok "Pacote '${pkg}' construído e instalado para perfil ${ADM_PROFILE}"
}

##############################################################################
# Grafo de dependências (Kahn) + detecção de ciclos
##############################################################################

declare -A GRAPH_DEPS     # pkg -> "dep1 dep2 ..."
declare -A GRAPH_REVERSE  # dep -> "pkg1 pkg2 ..."
declare -A GRAPH_NODES    # pkg -> 1

graph_reset() {
    GRAPH_DEPS=()
    GRAPH_REVERSE=()
    GRAPH_NODES=()
}

graph_add_node() {
    local n="$1"
    GRAPH_NODES["$n"]=1
}

graph_add_edge() {
    local dep="$1"
    local pkg="$2"
    graph_add_node "$dep"
    graph_add_node "$pkg"
    GRAPH_DEPS["$pkg"]="${GRAPH_DEPS["$pkg"]} $dep"
    GRAPH_REVERSE["$dep"]="${GRAPH_REVERSE["$dep"]} $pkg"
}

graph_collect_from_targets() {
    local -a queue=("$@")
    local -A visited=()

    while ((${#queue[@]})); do
        local pkg="${queue[0]}"
        queue=("${queue[@]:1}")

        if [[ -n "${visited["$pkg"]:-}" ]]; then
            continue
        fi
        visited["$pkg"]=1
        graph_add_node "$pkg"

        pkg_load_metadata "$pkg"
        local -n _DEPS=PKG_DEPENDS

        for d in "${_DEPS[@]:-}"; do
            graph_add_edge "$d" "$pkg"
            queue+=("$d")
        done
    done
}

BUILD_ORDER=()

graph_topological_sort_kahn() {
    local -A indegree=()
    local node dep

    for node in "${!GRAPH_NODES[@]}"; do
        indegree["$node"]=0
    done

    for node in "${!GRAPH_DEPS[@]}"; do
        for dep in ${GRAPH_DEPS["$node"]}; do
            (( indegree["$node"]++ ))
        done
    done

    local -a queue=()
    for node in "${!GRAPH_NODES[@]}"; do
        if (( indegree["$node"] == 0 )); then
            queue+=("$node")
        fi
    done

    local -a result=()
    local processed=0

    while ((${#queue[@]})); do
        local n="${queue[0]}"
        queue=("${queue[@]:1}")

        result+=("$n")
        ((processed++))

        for succ in ${GRAPH_REVERSE["$n"]:-}; do
            (( indegree["$succ"]-- ))
            if (( indegree["$succ"] == 0 )); then
                queue+=("$succ")
            fi
        done
    done

    local total_nodes="${#GRAPH_NODES[@]}"
    if (( processed < total_nodes )); then
        log_err "Detecção de ciclo de dependências! Nós no grafo: ${total_nodes}, processados: ${processed}"
        exit 1
    fi

    BUILD_ORDER=("${result[@]}")
}

##############################################################################
# Construção com paralelismo, respeitando dependências
##############################################################################

build_graph_parallel() {
    local total_nodes="${#GRAPH_NODES[@]}"
    if (( total_nodes == 0 )); then
        log_warn "Nenhum nó no grafo de dependências."
        return 0
    fi

    # Recalcula indegree (para não depender do BUILD_ORDER)
    local -A indegree=()
    local node dep

    for node in "${!GRAPH_NODES[@]}"; do
        indegree["$node"]=0
    done

    for node in "${!GRAPH_DEPS[@]}"; do
        for dep in ${GRAPH_DEPS["$node"]}; do
            (( indegree["$node"]++ ))
        done
    done

    local -a ready=()
    for node in "${!GRAPH_NODES[@]}"; do
        if (( indegree["$node"] == 0 )); then
            ready+=("$node")
        fi
    done

    local built_count=0
    local -A pid_to_pkg=()

    while (( built_count < total_nodes )); do
        if ((${#ready[@]} == 0)); then
            log_err "Sem nós prontos para build mas ainda há nós não construídos (possível ciclo ou erro)."
            exit 1
        fi

        # Monta batch limitado por ADM_JOBS
        local -a batch=()
        while ((${#ready[@]} && ${#batch[@]} < ADM_JOBS)); do
            batch+=("${ready[0]}")
            ready=("${ready[@]:1}")
        done

        log_info "Iniciando batch de build (até ${ADM_JOBS} jobs): ${batch[*]}"

        pid_to_pkg=()
        local pkg
        for pkg in "${batch[@]}"; do
            (
                pkg_build_one "$pkg"
            ) &
            pid_to_pkg[$!]="$pkg"
        done

        local fail=0
        local pid
        for pid in "${!pid_to_pkg[@]}"; do
            if ! wait "$pid"; then
                log_err "Falha ao construir pacote: ${pid_to_pkg[$pid]}"
                fail=1
            else
                local okpkg="${pid_to_pkg[$pid]}"
                ((built_count++))
                # Atualiza indegree dos sucessores
                local succ
                for succ in ${GRAPH_REVERSE["$okpkg"]:-}; do
                    (( indegree["$succ"]-- ))
                    if (( indegree["$succ"] == 0 )); then
                        ready+=("$succ")
                    fi
                done
            fi
        done

        if (( fail )); then
            log_err "Erro em pelo menos um pacote do batch; abortando construção."
            exit 1
        fi
    done
}

build_with_deps() {
    local targets=("$@")

    graph_reset
    graph_collect_from_targets "${targets[@]}"
    graph_topological_sort_kahn

    log_info "Ordem topológica (build):"
    printf '  %s\n' "${BUILD_ORDER[@]}"

    log_info "Ordem reversa (remoção):"
    for ((i=${#BUILD_ORDER[@]}-1; i>=0; i--)); do
        printf '  %s\n' "${BUILD_ORDER[i]}"
    done

    build_graph_parallel
}

##############################################################################
# Sync com repositório git de scripts
##############################################################################

cmd_sync() {
    ensure_dirs
    if [[ -d "${ADM_PACKAGES_DIR}/.git" ]]; then
        log_info "Atualizando repositório de pacotes em ${ADM_PACKAGES_DIR}"
        (cd "${ADM_PACKAGES_DIR}" && git pull --ff-only)
    else
        log_info "Clonando repositório de pacotes em ${ADM_PACKAGES_DIR}"
        git clone "${ADM_REMOTE_PACKAGES_URL}" "${ADM_PACKAGES_DIR}"
    fi
}

##############################################################################
# Limpeza inteligente
##############################################################################

usage_clean() {
    cat <<EOF
Uso: adm clean <modo>

Modos:
  build              Remove diretórios de build    (${ADM_BUILD_DIR})
  sources            Remove cache de fontes       (${ADM_CACHE_SRC})
  pkgs               Remove cache de binários     (${ADM_CACHE_PKG})
  logs               Remove logs                  (${ADM_LOG_DIR})
  state              Remove estados de build      (${ADM_STATE_DIR})
  rootfs             Remove rootfs glibc/musl     (${ADM_ROOT}/rootfs-glibc, ${ADM_ROOT}/rootfs-musl)
  soft               Limpa build + state          (mantém caches e rootfs)
  full --force       Limpa TUDO do ADM (rootfs, caches, build, logs, state)

Exemplos:
  adm clean soft
  adm clean full --force
EOF
}

cmd_clean() {
    local mode="${1:-}"
    shift || true

    case "$mode" in
        build)
            log_warn "Limpando diretórios de build: ${ADM_BUILD_DIR}"
            rm -rf "${ADM_BUILD_DIR}"
            mkdir -p "${ADM_BUILD_DIR}"
            ;;
        sources)
            log_warn "Limpando cache de fontes: ${ADM_CACHE_SRC}"
            rm -rf "${ADM_CACHE_SRC}"
            mkdir -p "${ADM_CACHE_SRC}"
            ;;
        pkgs)
            log_warn "Limpando cache de binários: ${ADM_CACHE_PKG}"
            rm -rf "${ADM_CACHE_PKG}"
            mkdir -p "${ADM_CACHE_PKG}"
            ;;
        logs)
            log_warn "Limpando logs: ${ADM_LOG_DIR}"
            rm -rf "${ADM_LOG_DIR}"
            mkdir -p "${ADM_LOG_DIR}"
            ;;
        state)
            log_warn "Limpando estados de build: ${ADM_STATE_DIR}"
            rm -rf "${ADM_STATE_DIR}"
            mkdir -p "${ADM_STATE_DIR}"
            ;;
        rootfs)
            log_warn "Limpando rootfs glibc/musl: ${ADM_ROOT}/rootfs-{glibc,musl}"
            rm -rf "${ADM_ROOT}/rootfs-glibc" "${ADM_ROOT}/rootfs-musl"
            mkdir -p "${ADM_ROOT}/rootfs-glibc/tools" "${ADM_ROOT}/rootfs-musl/tools"
            ;;
        soft)
            log_warn "Limpeza soft: build + state"
            rm -rf "${ADM_BUILD_DIR}" "${ADM_STATE_DIR}"
            mkdir -p "${ADM_BUILD_DIR}" "${ADM_STATE_DIR}"
            ;;
        full)
            local force=0
            if [[ "${1:-}" == "--force" ]]; then
                force=1
            fi
            if (( force != 1 )); then
                log_err "Modo 'full' remove TUDO em ${ADM_ROOT}. Use: adm clean full --force"
                exit 1
            fi
            log_warn "LIMPANDO COMPLETAMENTE ${ADM_ROOT} (exceto este script se estiver fora de ${ADM_ROOT})"
            rm -rf \
                "${ADM_BUILD_DIR}" \
                "${ADM_CACHE_SRC}" \
                "${ADM_CACHE_PKG}" \
                "${ADM_LOG_DIR}" \
                "${ADM_STATE_DIR}" \
                "${ADM_ROOT}/rootfs-glibc" \
                "${ADM_ROOT}/rootfs-musl"
            ensure_dirs
            ;;
        *)
            usage_clean
            exit 1
            ;;
    esac

    log_ok "Limpeza '${mode}' concluída."
}

##############################################################################
# CLI
##############################################################################

usage() {
    cat <<EOF
Uso: adm <comando> [opções]

Comandos:
  sync                     Sincroniza scripts de construção via git
  build [opções] <pkgs>    Constrói pacotes com dependências
  clean <modo>             Limpeza inteligente (build, caches, rootfs, full)

Opções para 'build':
  -P, --profile <p>        Perfil: glibc (padrão) ou musl
  -j, --jobs <n>           Número máximo de jobs paralelos (padrão: ${ADM_JOBS})
      --resume             Habilita retomada de construção (padrão)
      --no-resume          Desabilita retomada (reconstrói tudo do comando)

Exemplos:
  adm sync
  adm build core/binutils core/gcc
  adm build -P musl -j 4 core/binutils core/gcc
  adm clean soft
  adm clean full --force
EOF
}

cmd_build() {
    local profile="$ADM_DEFAULT_PROFILE"
    local -a pkgs=()

    while (($#)); do
        case "$1" in
            -P|--profile)
                profile="$2"
                shift 2
                ;;
            -j|--jobs)
                ADM_JOBS="$2"
                shift 2
                ;;
            --resume)
                ADM_RESUME=1
                shift
                ;;
            --no-resume)
                ADM_RESUME=0
                shift
                ;;
            --)
                shift
                break
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                log_err "Opção desconhecida para 'build': $1"
                exit 1
                ;;
            *)
                pkgs+=("$1")
                shift
                ;;
        esac
    done

    if ((${#pkgs[@]} == 0)); then
        log_err "Nenhum pacote informado para 'build'"
        usage
        exit 1
    fi

    ensure_dirs
    set_profile "$profile"
    build_with_deps "${pkgs[@]}"
}

main() {
    ensure_dirs
    setup_logging
    check_required_tools

    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        sync)
            cmd_sync "$@"
            ;;
        build)
            cmd_build "$@"
            ;;
        clean)
            cmd_clean "$@"
            ;;
        ""|-h|--help|help)
            usage
            ;;
        *)
            log_err "Comando desconhecido: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
