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
ADM_STATE_DIR="${ADM_ROOT}/state"
ADM_BUILD_DIR="${ADM_ROOT}/build"
ADM_DB_DIR="${ADM_ROOT}/db"

ADM_DEFAULT_PROFILE="glibc"

# Definir ADM_JOBS com fallback se nproc não existir
if command -v nproc >/dev/null 2>&1; then
    _adm_default_jobs="$(nproc)"
else
    _adm_default_jobs=1
fi
ADM_JOBS="${ADM_JOBS:-${_adm_default_jobs}}"

ADM_RESUME="${ADM_RESUME:-1}"        # retomada de construção (1=on, 0=off)
ADM_DRY_RUN=0                        # definido em main() por --dry-run

# Repositório de scripts de pacotes
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

# Tratamento de erros não capturados (evita erro silencioso)
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
        "${ADM_ROOT}/rootfs-glibc/tools" \
        "${ADM_ROOT}/rootfs-musl/tools" \
        "${ADM_STATE_DIR}" \
        "${ADM_BUILD_DIR}" \
        "${ADM_DB_DIR}"
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
# Hooks por pacote (simples)
# Estrutura esperada por pacote:
#   /opt/adm/packages/<categoria>/<pacote>/hooks/pre_build.sh
#   /opt/adm/packages/<categoria>/<pacote>/hooks/post_build.sh
#   /opt/adm/packages/<categoria>/<pacote>/hooks/pre_install.sh
#   /opt/adm/packages/<categoria>/<pacote>/hooks/post_install.sh
#   /opt/adm/packages/<categoria>/<pacote>/hooks/pre_uninstall.sh
#   /opt/adm/packages/<categoria>/<pacote>/hooks/post_uninstall.sh
##############################################################################

run_hook() {
    local stage="$1"   # pre_build, post_build, pre_install, post_install, pre_uninstall, post_uninstall
    local pkg="$2"     # categoria/pacote

    local hook="${ADM_PACKAGES_DIR}/${pkg}/hooks/${stage}.sh"

    if [[ ! -f "$hook" ]]; then
        return 0
    fi

    if [[ ! -x "$hook" ]]; then
        log_warn "Hook encontrado mas não executável: ${hook} (pkg=${pkg}, stage=${stage})"
        return 0
    fi

    log_info "Executando hook ${stage} para '${pkg}': ${hook}"

    if [[ "${ADM_DRY_RUN:-0}" -eq 1 ]]; then
        log_info "[DRY-RUN] ${hook}"
        return 0
    fi

    ADM_HOOK_STAGE="$stage" \
    ADM_HOOK_PKG="$pkg" \
    ADM_PROFILE="$ADM_PROFILE" \
    ADM_ROOTFS="$ADM_ROOTFS" \
        "$hook"
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

    PKG_SOURCES=()
    PKG_SHA256=()
    PKG_MD5=()
    PKG_DEPENDS=()
    PKG_PROFILE_SUPPORT=()

    # shellcheck source=/dev/null
    . "$script" metadata

    : "${PKG_NAME:?PKG_NAME não definido em ${script}}"
    : "${PKG_VERSION:?PKG_VERSION não definido em ${script}}"
    : "${PKG_RELEASE:?PKG_RELEASE não definido em ${script}}"
}

##############################################################################
# Download, cache e verificação de checksums
##############################################################################

is_git_source() {
    local url="$1"
    if [[ "$url" =~ ^git:// ]] || [[ "$url" =~ ^git\+https:// ]] || [[ "$url" =~ \.git($|#) ]]; then
        return 0
    fi
    return 1
}

fetch_git_repo() {
    local url="$1"
    local pkg="$2"

    local repo_url="$url"
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

    if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] iria sincronizar repositório git: ${repo_url} em ${mirror}"
        return 0
    fi

    if [[ -d "$mirror" ]]; then
        log_info "Atualizando mirror git: ${repo_url}"
        (cd "$mirror" && git fetch --all --tags --prune)
    else
        log_info "Clonando mirror git: ${repo_url} -> ${mirror}"
        git clone --mirror "$repo_url" "$mirror"
    fi

    rm -rf "$work"
    log_info "Criando working tree git: ${work}"
    git clone "$mirror" "$work"

    if [[ -n "$fragment" ]]; then
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

download_with_check_file() {
    local url="$1"
    local dest="$2"
    local sha="$3"
    local md5="$4"

    if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] iria baixar: ${url} -> ${dest}"
        return 0
    fi

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

    local -n _SRC=PKG_SOURCES
    local -n _SHA=PKG_SHA256
    local -n _MD5=PKG_MD5

    if [[ "${#_SRC[@]}" -eq 0 ]]; then
        log_warn "Pacote '${pkg}' não possui fontes definidas (PKG_SOURCES vazio)"
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

            if [[ -z "$sha" && -z "$md5" ]]; then
                log_warn "Nenhum checksum configurado para fonte ${url} (índice ${i})"
            fi

            download_with_check_file "$url" "$dest" "$sha" "$md5"
        fi
        ((i++))
    done
}

##############################################################################
# Estado de build (retomada)
##############################################################################

pkg_state_file() {
    local pkg="$1"
    local base_dir="${ADM_STATE_DIR}/${ADM_PROFILE}"
    local pkg_dir="${base_dir}/$(dirname "$pkg")"
    mkdir -p "$pkg_dir"
    echo "${base_dir}/${pkg}.state"
}

pkg_mark_state() {
    local pkg="$1"
    local state="$2"
    local file
    file="$(pkg_state_file "$pkg")"
    if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] iria marcar estado de ${pkg} como '${state}' em ${file}"
        return 0
    fi
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
# DB de instalação (manifesto, meta)
##############################################################################

pkg_db_dir() {
    local pkg="$1"
    local base="${ADM_DB_DIR}/${ADM_PROFILE}"
    local dir="${base}/${pkg}"
    echo "$dir"
}

pkg_manifest_file() {
    local pkg="$1"
    echo "$(pkg_db_dir "$pkg")/manifest"
}

pkg_meta_file() {
    local pkg="$1"
    echo "$(pkg_db_dir "$pkg")/meta"
}

pkg_is_installed() {
    local pkg="$1"
    local manifest
    manifest="$(pkg_manifest_file "$pkg")"
    [[ -f "$manifest" ]]
}

pkg_register_installation() {
    local pkg="$1"
    local version="$2"
    local release="$3"
    shift 3
    local -a deps=("$@")

    local dbd
    dbd="$(pkg_db_dir "$pkg")"
    local manifest
    manifest="$(pkg_manifest_file "$pkg")"
    local meta
    meta="$(pkg_meta_file "$pkg")"

    if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] iria registrar instalação de ${pkg} em ${dbd}"
        return 0
    fi

    mkdir -p "$dbd"

    local manual=0
    if [[ " ${ADM_TARGETS[*]:-} " == *" ${pkg} "* ]]; then
        manual=1
    fi
    if [[ -f "$meta" ]]; then
        # shellcheck disable=SC1090
        . "$meta"
        if [[ "${MANUAL:-0}" -eq 1 ]]; then
            manual=1
        fi
    fi

    {
        echo "NAME=${pkg}"
        echo "VERSION=${version}"
        echo "RELEASE=${release}"
        echo -n "DEPS="
        printf "%s " "${deps[@]:-}"
        echo
        echo "MANUAL=${manual}"
    } > "$meta"

    log_ok "Registro de instalação criado para ${pkg} (perfil=${ADM_PROFILE})"
}

pkg_read_meta_field() {
    local pkg="$1"
    local field="$2"
    local meta
    meta="$(pkg_meta_file "$pkg")"
    [[ -f "$meta" ]] || return 1
    # shellcheck disable=SC1090
    . "$meta"
    case "$field" in
        NAME)    echo "${NAME:-}" ;;
        VERSION) echo "${VERSION:-}" ;;
        RELEASE) echo "${RELEASE:-}" ;;
        DEPS)    echo "${DEPS:-}" ;;
        MANUAL)  echo "${MANUAL:-0}" ;;
    esac
}

##############################################################################
# Empacotamento binário por pacote
##############################################################################

pkg_tar_base_name() {
    local pkg="$1"
    local version="$2"
    local release="$3"
    echo "${pkg//\//_}-${version}-${release}-${ADM_PROFILE}"
}

pkg_make_binary_tarball_relative() {
    local pkg="$1"
    local version="$2"
    local release="$3"
    local destdir="$4"

    mkdir -p "${ADM_CACHE_PKG}"

    local base
    base="$(pkg_tar_base_name "$pkg" "$version" "$release")"
    local zst="${ADM_CACHE_PKG}/${base}.tar.zst"
    local xz="${ADM_CACHE_PKG}/${base}.tar.xz"
    local tar_plain="${ADM_CACHE_PKG}/${base}.tar"
    local tar_tmp="${ADM_CACHE_PKG}/${base}.tar.tmp"

    if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] iria empacotar ${pkg} (DESTDIR=${destdir}) em ${ADM_CACHE_PKG}/${base}.tar.*"
        return 0
    fi

    log_info "Criando tar temporário de ${pkg} a partir de ${destdir}"
    rm -f "$tar_tmp"
    tar -C "$destdir" -cpf "$tar_tmp" .

    local manifest_rel
    manifest_rel="$(pkg_manifest_file "$pkg").rel"
    mkdir -p "$(dirname "$manifest_rel")"
    tar -tf "$tar_tmp" | sed 's|^\./||' > "$manifest_rel"

    if command -v zstd >/dev/null 2>&1; then
        log_info "Comprimindo tar para ${zst}"
        rm -f "$zst"
        zstd -19 -T0 -q "$tar_tmp" -o "$zst"
        rm -f "$tar_tmp" "$xz" "$tar_plain"
    elif command -v xz >/dev/null 2>&1; then
        log_info "Comprimindo tar para ${xz}"
        rm -f "$xz"
        xz -T0 -9e -c "$tar_tmp" > "$xz"
        rm -f "$tar_tmp" "$zst" "$tar_plain"
    else
        log_warn "Nenhum compressor zstd/xz disponível, mantendo tar sem compressão em ${tar_plain}"
        mv "$tar_tmp" "$tar_plain"
        rm -f "$zst" "$xz"
    fi

    log_ok "Pacote binário gerado para ${pkg}"
}

pkg_find_binary_tarball() {
    local pkg="$1"
    local version="$2"
    local release="$3"

    local base
    base="$(pkg_tar_base_name "$pkg" "$version" "$release")"

    local zst="${ADM_CACHE_PKG}/${base}.tar.zst"
    local xz="${ADM_CACHE_PKG}/${base}.tar.xz"
    local tar_plain="${ADM_CACHE_PKG}/${base}.tar"

    if [[ -f "$zst" ]]; then
        echo "$zst"
        return 0
    elif [[ -f "$xz" ]]; then
        echo "$xz"
        return 0
    elif [[ -f "$tar_plain" ]]; then
        echo "$tar_plain"
        return 0
    fi

    return 1
}

pkg_install_from_tarball() {
    local pkg="$1"
    local version="$2"
    local release="$3"

    local tarball
    if ! tarball="$(pkg_find_binary_tarball "$pkg" "$version" "$release")"; then
        return 1
    fi

    log_info "Instalando ${pkg} a partir de cache binário: ${tarball}"

    if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] iria extrair ${tarball} em ${ADM_ROOTFS}"
        return 0
    fi

    mkdir -p "$ADM_ROOTFS"

    case "$tarball" in
        *.tar.zst)
            zstd -d -q "$tarball" -c | tar -C "$ADM_ROOTFS" -xpf -
            ;;
        *.tar.xz)
            xz -d -c "$tarball" | tar -C "$ADM_ROOTFS" -xpf -
            ;;
        *.tar)
            tar -C "$ADM_ROOTFS" -xpf "$tarball"
            ;;
        *)
            log_err "Formato de tarball desconhecido: ${tarball}"
            return 1
            ;;
    esac

    local manifest_rel
    manifest_rel="$(pkg_manifest_file "$pkg").rel"
    if [[ ! -f "$manifest_rel" ]]; then
        case "$tarball" in
            *.tar.zst)
                zstd -d -q "$tarball" -c | tar -tf - | sed 's|^\./||' > "$manifest_rel"
                ;;
            *.tar.xz)
                xz -d -c "$tarball" | tar -tf - | sed 's|^\./||' > "$manifest_rel"
                ;;
            *.tar)
                tar -tf "$tarball" | sed 's|^\./||' > "$manifest_rel"
                ;;
        esac
    fi

    local manifest_abs
    manifest_abs="$(pkg_manifest_file "$pkg")"
    mkdir -p "$(dirname "$manifest_abs")"
    : > "$manifest_abs"
    if [[ -f "$manifest_rel" ]]; then
        while IFS= read -r rel; do
            [[ -z "$rel" ]] && continue
            echo "${ADM_ROOTFS}/${rel}" >> "$manifest_abs"
        done < "$manifest_rel"
    fi

    log_ok "Pacote '${pkg}' instalado a partir de cache binário"
    return 0
}

##############################################################################
# Aplicação automática de patches
##############################################################################

pkg_apply_patches() {
    local pkg="$1"
    local builddir="$2"

    local patch_dir="${ADM_PACKAGES_DIR}/${pkg}"
    local old_nullglob
    old_nullglob="$(shopt -p nullglob || true)"
    shopt -s nullglob

    local patches=("${patch_dir}"/*.patch)

    if ((${#patches[@]} == 0)); then
        eval "$old_nullglob"
        return 0
    fi

    log_info "Aplicando patches para '${pkg}'"
    (
        cd "$builddir"
        for p in "${patches[@]}"; do
            log_info "Aplicando patch: $(basename "$p")"
            if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
                log_info "[DRY-RUN] patch -p1 < ${p}"
            else
                patch -p1 < "$p"
            fi
        done
    )

    eval "$old_nullglob"
}

##############################################################################
# Construção de pacote individual
##############################################################################

ADM_TARGETS=()

pkg_build_one() {
    local pkg="$1"
    local script
    script="$(pkg_find_script "$pkg")"

    pkg_load_metadata "$pkg"

    local -n _PROFILES=PKG_PROFILE_SUPPORT
    if [[ "${#_PROFILES[@]}" -gt 0 ]]; then
        local supported=false
        for p in "${_PROFILES[@]}"; do
            if [[ "$p" == "$ADM_PROFILE" ]]; then
                supported=true; break
            fi
        done
        if [[ "$supported" != true ]]; then
            log_warn "Pacote '${pkg}' não suporta perfil ${ADM_PROFILE}, ignorando"
            return 0
        fi
    fi

    if [[ "$ADM_RESUME" -eq 1 && "$ADM_DRY_RUN" -eq 0 ]]; then
        local st
        st="$(pkg_get_state "$pkg")"
        if [[ "$st" == "done" ]]; then
            log_info "Pulando '${pkg}' (já concluído para perfil ${ADM_PROFILE})"
            return 0
        fi
    fi

    if pkg_is_installed "$pkg"; then
        log_info "Pacote '${pkg}' já está instalado para perfil ${ADM_PROFILE}; nada a fazer."
        return 0
    fi

    if pkg_install_from_tarball "$pkg" "$PKG_VERSION" "$PKG_RELEASE"; then
        pkg_mark_state "$pkg" "done"
        return 0
    fi

    pkg_mark_state "$pkg" "building"

    pkg_fetch_sources "$pkg"

    local builddir="${ADM_BUILD_DIR}/${ADM_PROFILE}/${pkg}"
    local destdir="${ADM_ROOT}/dest/${ADM_PROFILE}/${pkg}"
    log_info "Preparando builddir=${builddir} destdir=${destdir}"

    if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] iria limpar e criar builddir/destdir para ${pkg}"
    else
        rm -rf "$builddir" "$destdir"
        mkdir -p "$builddir" "$destdir"
    fi

    local -n _SRC=PKG_SOURCES
    for url in "${_SRC[@]:-}"; do
        if is_git_source "$url"; then
            local repo_url="${url#git+}"
            repo_url="${repo_url%%#*}"
            local name
            name="$(basename "${repo_url}" .git)"
            local work="${ADM_CACHE_SRC}/${pkg}/${name}-work"

            if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
                log_info "[DRY-RUN] iria copiar working tree git ${work} para ${builddir}"
            else
                if [[ -d "$work" ]]; then
                    log_info "Copiando fonte git '${name}-work' para ${builddir}"
                    cp -a "$work" "${builddir}/"
                else
                    log_warn "Working tree git não encontrado para ${url}, verifique o fetch_git_repo."
                fi
            fi
        else
            local filename
            filename="$(basename "${url%%\?*}")"
            local srcpath="${ADM_CACHE_SRC}/${pkg}/${filename}"

            if [[ "$srcpath" =~ \.(tar\.gz|tgz|tar\.bz2|tar\.xz|tar\.zst|tar)$ ]]; then
                log_info "Extraindo ${srcpath} em ${builddir}"
                if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
                    log_info "[DRY-RUN] tar -C ${builddir} -xf ${srcpath}"
                else
                    case "$srcpath" in
                        *.tar.zst) zstd -d -q "$srcpath" -c | tar -C "$builddir" -xpf - ;;
                        *.tar.xz)  xz -d -c "$srcpath" | tar -C "$builddir" -xpf - ;;
                        *)         tar -C "$builddir" -xpf "$srcpath" ;;
                    esac
                fi
            else
                if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
                    log_info "[DRY-RUN] cp -a ${srcpath} ${builddir}/"
                else
                    cp -a "$srcpath" "$builddir/"
                fi
            fi
        fi
    done

    pkg_apply_patches "$pkg" "$builddir"

    run_hook pre_build "$pkg"

    log_info "Construindo pacote '${pkg}' (perfil=${ADM_PROFILE})"

    if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] iria executar script de build: ${script} build (PKG_BUILD_DIR=${builddir}, PKG_DESTDIR=${destdir})"
    else
        PKG_BUILD_DIR="$builddir" PKG_ROOTFS="$ADM_ROOTFS" \
            PKG_DESTDIR="$destdir" \
            ADM_PROFILE="$ADM_PROFILE" ADM_ROOTFS="$ADM_ROOTFS" \
            ADM_TOOLS_DIR="$ADM_TOOLS_DIR" \
            "$script" build
    fi

    run_hook post_build "$pkg"

    run_hook pre_install "$pkg"

    if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] iria instalar ${pkg} copiando ${destdir} para ${ADM_ROOTFS}"
    else
        mkdir -p "$ADM_ROOTFS"
        (cd "$destdir" && tar -cpf - .) | (cd "$ADM_ROOTFS" && tar -xpf -)
    fi

    run_hook post_install "$pkg"

    pkg_make_binary_tarball_relative "$pkg" "$PKG_VERSION" "$PKG_RELEASE" "$destdir"

    local manifest_rel
    manifest_rel="$(pkg_manifest_file "$pkg").rel"
    local manifest_abs
    manifest_abs="$(pkg_manifest_file "$pkg")"
    if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] iria gerar manifesto absoluto para ${pkg} em ${manifest_abs}"
    else
        mkdir -p "$(dirname "$manifest_abs")"
        : > "$manifest_abs"
        if [[ -f "$manifest_rel" ]]; then
            while IFS= read -r rel; do
                [[ -z "$rel" ]] && continue
                echo "${ADM_ROOTFS}/${rel}" >> "$manifest_abs"
            done < "$manifest_rel"
        fi
    fi

    local -n _DEPS=PKG_DEPENDS
    pkg_register_installation "$pkg" "$PKG_VERSION" "$PKG_RELEASE" "${_DEPS[@]:-}"

    pkg_mark_state "$pkg" "done"
    log_ok "Pacote '${pkg}' construído e instalado para perfil ${ADM_PROFILE}"
}

##############################################################################
# Grafo de dependências (Kahn) + build paralelo
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

build_graph_parallel() {
    local total_nodes="${#GRAPH_NODES[@]}"
    if (( total_nodes == 0 )); then
        log_warn "Nenhum nó no grafo de dependências."
        return 0
    fi

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
    declare -A pid_to_pkg

    while (( built_count < total_nodes )); do
        if ((${#ready[@]} == 0)); then
            log_err "Sem nós prontos para build mas ainda há nós não construídos."
            exit 1
        fi

        local -a batch=()
        while ((${#ready[@]} && ${#batch[@]} < ADM_JOBS)); do
            batch+=("${ready[0]}")
            ready=("${ready[@]:1}")
        done

        log_info "Iniciando batch (até ${ADM_JOBS} jobs): ${batch[*]}"

        pid_to_pkg=()
        local pkg
        for pkg in "${batch[@]}"; do
            if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
                log_info "[DRY-RUN] iria construir pacote ${pkg}"
                ((built_count++))
                local succ
                for succ in ${GRAPH_REVERSE["$pkg"]:-}; do
                    (( indegree["$succ"]-- ))
                    if (( indegree["$succ"] == 0 )); then
                        ready+=("$succ")
                    fi
                done
            else
                (
                    pkg_build_one "$pkg"
                ) &
                pid_to_pkg[$!]="$pkg"
            fi
        done

        if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
            continue
        fi

        local fail=0 pid
        for pid in "${!pid_to_pkg[@]}"; do
            if ! wait "$pid"; then
                log_err "Falha ao construir pacote: ${pid_to_pkg[$pid]}"
                fail=1
            else
                local okpkg="${pid_to_pkg[$pid]}"
                ((built_count++))
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

    ADM_TARGETS=("${targets[@]}")

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
    if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        if [[ -d "${ADM_PACKAGES_DIR}/.git" ]]; then
            log_info "[DRY-RUN] iria executar 'git pull --ff-only' em ${ADM_PACKAGES_DIR}"
        else
            log_info "[DRY-RUN] iria clonar ${ADM_REMOTE_PACKAGES_URL} em ${ADM_PACKAGES_DIR}"
        fi
        return 0
    fi

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
  full --force       Limpa TUDO do ADM (rootfs, caches, build, logs, state, db)

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
            if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
                log_info "[DRY-RUN] rm -rf ${ADM_BUILD_DIR}"
            else
                rm -rf "${ADM_BUILD_DIR}"
                mkdir -p "${ADM_BUILD_DIR}"
            fi
            ;;
        sources)
            log_warn "Limpando cache de fontes: ${ADM_CACHE_SRC}"
            if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
                log_info "[DRY-RUN] rm -rf ${ADM_CACHE_SRC}"
            else
                rm -rf "${ADM_CACHE_SRC}"
                mkdir -p "${ADM_CACHE_SRC}"
            fi
            ;;
        pkgs)
            log_warn "Limpando cache de binários: ${ADM_CACHE_PKG}"
            if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
                log_info "[DRY-RUN] rm -rf ${ADM_CACHE_PKG}"
            else
                rm -rf "${ADM_CACHE_PKG}"
                mkdir -p "${ADM_CACHE_PKG}"
            fi
            ;;
        logs)
            log_warn "Limpando logs: ${ADM_LOG_DIR}"
            if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
                log_info "[DRY-RUN] rm -rf ${ADM_LOG_DIR}"
            else
                rm -rf "${ADM_LOG_DIR}"
                mkdir -p "${ADM_LOG_DIR}"
            fi
            ;;
        state)
            log_warn "Limpando estados de build: ${ADM_STATE_DIR}"
            if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
                log_info "[DRY-RUN] rm -rf ${ADM_STATE_DIR}"
            else
                rm -rf "${ADM_STATE_DIR}"
                mkdir -p "${ADM_STATE_DIR}"
            fi
            ;;
        rootfs)
            log_warn "Limpando rootfs glibc/musl"
            if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
                log_info "[DRY-RUN] rm -rf ${ADM_ROOT}/rootfs-glibc ${ADM_ROOT}/rootfs-musl"
            else
                rm -rf "${ADM_ROOT}/rootfs-glibc" "${ADM_ROOT}/rootfs-musl"
                mkdir -p "${ADM_ROOT}/rootfs-glibc/tools" "${ADM_ROOT}/rootfs-musl/tools"
            fi
            ;;
        soft)
            log_warn "Limpeza soft: build + state"
            if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
                log_info "[DRY-RUN] rm -rf ${ADM_BUILD_DIR} ${ADM_STATE_DIR}"
            else
                rm -rf "${ADM_BUILD_DIR}" "${ADM_STATE_DIR}"
                mkdir -p "${ADM_BUILD_DIR}" "${ADM_STATE_DIR}"
            fi
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
            log_warn "LIMPANDO COMPLETAMENTE ${ADM_ROOT} (exceto ${ADM_BIN})"
            if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
                log_info "[DRY-RUN] rm -rf build cache src pkg logs state db rootfs-*"
            else
                rm -rf \
                    "${ADM_BUILD_DIR}" \
                    "${ADM_CACHE_SRC}" \
                    "${ADM_CACHE_PKG}" \
                    "${ADM_LOG_DIR}" \
                    "${ADM_STATE_DIR}" \
                    "${ADM_DB_DIR}" \
                    "${ADM_ROOT}/rootfs-glibc" \
                    "${ADM_ROOT}/rootfs-musl"
                ensure_dirs
            fi
            ;;
        *)
            usage_clean
            exit 1
            ;;
    esac

    log_ok "Limpeza '${mode}' concluída."
}

##############################################################################
# Uninstall + órfãos
##############################################################################

pkg_uninstall_one() {
    local pkg="$1"

    if ! pkg_is_installed "$pkg"; then
        log_warn "Pacote '${pkg}' não está instalado para perfil ${ADM_PROFILE}"
        return 0
    fi

    run_hook pre_uninstall "$pkg"

    local manifest
    manifest="$(pkg_manifest_file "$pkg")"

    if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] iria desinstalar ${pkg} removendo arquivos listados em ${manifest}"
    else
        log_info "Desinstalando pacote '${pkg}'"
        if [[ -f "$manifest" ]]; then
            mapfile -t _paths < "$manifest"
            local idx path
            for ((idx=${#_paths[@]}-1; idx>=0; idx--)); do
                path="${_paths[idx]}"
                [[ -z "$path" ]] && continue
                if [[ -d "$path" ]]; then
                    rmdir "$path" 2>/dev/null || true
                else
                    rm -f "$path" 2>/dev/null || true
                fi
            done
        fi
        rm -rf "$(pkg_db_dir "$pkg")"
    fi

    run_hook post_uninstall "$pkg"

    log_ok "Pacote '${pkg}' desinstalado (perfil=${ADM_PROFILE})"
}

list_installed_pkgs_for_profile() {
    local base="${ADM_DB_DIR}/${ADM_PROFILE}"
    [[ -d "$base" ]] || return 0
    find "$base" -mindepth 2 -type f -name meta | while read -r mf; do
        local rel
        rel="${mf#$base/}"
        rel="${rel%/meta}"
        echo "$rel"
    done
}

cmd_autoremove_orphans() {
    log_info "Procurando pacotes órfãos para perfil ${ADM_PROFILE}"

    local base="${ADM_DB_DIR}/${ADM_PROFILE}"
    [[ -d "$base" ]] || { log_info "Nenhum pacote instalado."; return 0; }

    declare -A installed
    declare -A deps_map
    declare -A manual_map

    while IFS= read -r pkg; do
        installed["$pkg"]=1
        local meta
        meta="$(pkg_meta_file "$pkg")"
        # shellcheck disable=SC1090
        . "$meta"
        manual_map["$pkg"]="${MANUAL:-0}"
        deps_map["$pkg"]="${DEPS:-}"
    done < <(list_installed_pkgs_for_profile)

    declare -A reachable
    local -a queue=()

    local p
    for p in "${!installed[@]}"; do
        if [[ "${manual_map[$p]:-0}" -eq 1 ]]; then
            reachable["$p"]=1
            queue+=("$p")
        fi
    done

    while ((${#queue[@]})); do
        local cur="${queue[0]}"
        queue=("${queue[@]:1}")

        for d in ${deps_map["$cur"]:-}; do
            if [[ -n "${installed["$d"]:-}" && -z "${reachable["$d"]:-}" ]]; then
                reachable["$d"]=1
                queue+=("$d")
            fi
        done
    done

    local -a orphans=()
    for p in "${!installed[@]}"; do
        if [[ -z "${reachable["$p"]:-}" ]]; then
            orphans+=("$p")
        fi
    done

    if ((${#orphans[@]} == 0)); then
        log_info "Nenhum órfão encontrado."
        return 0
    fi

    log_warn "Pacotes órfãos detectados: ${orphans[*]}"

    local op="REMOVENDO"
    if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        op="(DRY-RUN) Removeria"
    fi
    log_warn "${op} órfãos: ${orphans[*]}"

    local o
    for o in "${orphans[@]}"; do
        pkg_uninstall_one "$o"
    done
}

cmd_uninstall() {
    local profile="$ADM_DEFAULT_PROFILE"
    local with_orphans=0
    local -a pkgs=()

    while (($#)); do
        case "$1" in
            -P|--profile)
                profile="$2"; shift 2 ;;
            --with-orphans)
                with_orphans=1; shift ;;
            -h|--help)
                cat <<EOF
Uso: adm uninstall [opções] <pkgs>

Opções:
  -P, --profile <p>    Perfil: glibc ou musl
      --with-orphans   Após desinstalar, remove pacotes órfãos

Exemplos:
  adm uninstall core/hello
  adm uninstall -P musl --with-orphans core/hello
EOF
                return 0
                ;;
            -*)
                log_err "Opção desconhecida para 'uninstall': $1"
                exit 1
                ;;
            *)
                pkgs+=("$1"); shift ;;
        esac
    done

    if ((${#pkgs[@]} == 0)); then
        log_err "Nenhum pacote informado para 'uninstall'"
        exit 1
    fi

    set_profile "$profile"

    local pkg
    for pkg in "${pkgs[@]}"; do
        pkg_uninstall_one "$pkg"
    done

    if (( with_orphans )); then
        cmd_autoremove_orphans
    fi
}

##############################################################################
# Search / Info
##############################################################################

cmd_search() {
    local pattern="${1:-}"
    if [[ -z "$pattern" ]]; then
        log_err "Uso: adm search <padrão>"
        exit 1
    fi

    [[ -d "$ADM_PACKAGES_DIR" ]] || { log_warn "Diretório de pacotes vazio."; return 0; }

    log_info "Procurando pacotes que combinem com '${pattern}'"

    local found=0
    while IFS= read -r dir; do
        local rel
        rel="${dir#$ADM_PACKAGES_DIR/}"
        local script="${dir}/build.sh"
        local pkg_name=""
        local pkg_version=""

        if [[ -f "$script" ]]; then
            unset PKG_NAME PKG_VERSION
            PKG_SOURCES=() PKG_SHA256=() PKG_MD5=() PKG_DEPENDS=() PKG_PROFILE_SUPPORT=()
            # shellcheck source=/dev/null
            . "$script" metadata
            pkg_name="${PKG_NAME:-}"
            pkg_version="${PKG_VERSION:-}"
        fi

        if [[ "$rel" == *"$pattern"* ]] || [[ "$pkg_name" == *"$pattern"* ]]; then
            echo "  ${rel}  ->  ${pkg_name:-?} ${pkg_version:-}"
            found=1
        fi
    done < <(find "$ADM_PACKAGES_DIR" -mindepth 2 -maxdepth 2 -type d | sort)

    if (( ! found )); then
        log_info "Nenhum pacote encontrado com padrão '${pattern}'."
    fi
}

cmd_info() {
    local pkg="${1:-}"
    if [[ -z "$pkg" ]]; then
        log_err "Uso: adm info <categoria/pacote>"
        exit 1
    fi

    pkg_load_metadata "$pkg"

    echo "Pacote:       ${pkg}"
    echo "Nome lógico:  ${PKG_NAME}"
    echo "Versão:       ${PKG_VERSION}"
    echo "Release:      ${PKG_RELEASE}"
    echo "Categoria:    ${PKG_CATEGORY:-}"
    echo "Perfis:       ${PKG_PROFILE_SUPPORT[*]:-(todos)}"
    echo "Deps:         ${PKG_DEPENDS[*]:-(nenhuma)}"
    echo "Sources:"
    local s
    for s in "${PKG_SOURCES[@]:-}"; do
        echo "  - ${s}"
    done

    local profile
    for profile in glibc musl; do
        ADM_PROFILE="$profile"
        ADM_ROOTFS="${ADM_ROOT}/rootfs-${ADM_PROFILE}"
        if pkg_is_installed "$pkg"; then
            local version release
            version="$(pkg_read_meta_field "$pkg" VERSION 2>/dev/null || echo '?')"
            release="$(pkg_read_meta_field "$pkg" RELEASE 2>/dev/null || echo '?')"
            echo "Instalado em ${profile}: SIM (versão=${version}, release=${release})"
        else
            echo "Instalado em ${profile}: NÃO"
        fi
    done
}

##############################################################################
# CLI
##############################################################################

usage() {
    cat <<EOF
Uso: adm [opções globais] <comando> [opções]

Opções globais:
  --dry-run               Não aplica mudanças, apenas mostra o que faria

Comandos:
  sync                    Sincroniza scripts de construção via git
  build [opções] <pkgs>   Constrói pacotes com dependências
  clean <modo>            Limpeza inteligente (build, caches, rootfs, full)
  uninstall [opts] <pkgs> Desinstala pacotes, com opção de remover órfãos
  search <padrão>         Procura pacotes pelo nome/diretório
  info <pkg>              Mostra informações de um pacote

Opções para 'build':
  -P, --profile <p>       Perfil: glibc (padrão) ou musl
  -j, --jobs <n>          Número máximo de jobs paralelos (padrão: ${ADM_JOBS})
      --resume            Habilita retomada de construção (padrão)
      --no-resume         Desabilita retomada (reconstrói tudo do comando)

Exemplos:
  adm sync
  adm build core/binutils core/gcc
  adm build -P musl -j 4 core/binutils core/gcc
  adm uninstall core/hello --with-orphans
  adm search hello
  adm info core/hello
  adm clean soft
EOF
}

cmd_build() {
    local profile="$ADM_DEFAULT_PROFILE"
    local -a pkgs=()

    while (($#)); do
        case "$1" in
            -P|--profile)
                profile="$2"; shift 2 ;;
            -j|--jobs)
                ADM_JOBS="$2"; shift 2 ;;
            --resume)
                ADM_RESUME=1; shift ;;
            --no-resume)
                ADM_RESUME=0; shift ;;
            --)
                shift; break ;;
            -h|--help)
                usage; exit 0 ;;
            -*)
                log_err "Opção desconhecida para 'build': $1"
                exit 1 ;;
            *)
                pkgs+=("$1"); shift ;;
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

    while (($#)); do
        case "$1" in
            --dry-run)
                ADM_DRY_RUN=1; shift ;;
            --)
                shift; break ;;
            *)
                break ;;
        esac
    done

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
        uninstall)
            cmd_uninstall "$@"
            ;;
        search)
            cmd_search "$@"
            ;;
        info)
            cmd_info "$@"
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
