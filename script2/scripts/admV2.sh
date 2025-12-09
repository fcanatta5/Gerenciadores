#!/usr/bin/env bash
set -euo pipefail

ADM_ROOT=${ADM_ROOT:-/opt/adm}
PKG_ROOT="${ADM_ROOT}/packages"
CACHE_ROOT="${ADM_ROOT}/cache"
SOURCE_CACHE="${CACHE_ROOT}/sources"
BIN_CACHE="${CACHE_ROOT}/binpkgs"
ROOTFS_GLIBC="${ADM_ROOT}/glibc-rootfs"
ROOTFS_MUSL="${ADM_ROOT}/musl-rootfs"
DB_ROOT="${ADM_ROOT}/db"
LOG_ROOT="${ADM_ROOT}/logs"
LOCK_DIR="${ADM_ROOT}/lock"
STATE_DIR="${DB_ROOT}/build-state"

mkdir -p "$PKG_ROOT" "$SOURCE_CACHE" "$BIN_CACHE" \
         "$ROOTFS_GLIBC" "$ROOTFS_MUSL" \
         "$DB_ROOT" "$LOG_ROOT" "$LOCK_DIR" "$STATE_DIR"

# ------------- Colors / logging -------------

if [ -t 1 ]; then
    COLOR_RESET='\033[0m'
    COLOR_INFO='\033[1;34m'
    COLOR_WARN='\033[1;33m'
    COLOR_ERROR='\033[1;31m'
    COLOR_OK='\033[1;32m'
else
    COLOR_RESET=''
    COLOR_INFO=''
    COLOR_WARN=''
    COLOR_ERROR=''
    COLOR_OK=''
fi

LOG_FILE=""

timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

log_set_file() {
    LOG_FILE="$1"
}

_log() {
    local level="$1"; shift
    local color="$1"; shift
    local msg="$*"
    local ts
    ts="$(timestamp)"
    printf "%b[%s] %-5s%b %s\n" "$color" "$ts" "$level" "$COLOR_RESET" "$msg"
    if [ -n "${LOG_FILE:-}" ]; then
        printf "[%s] %-5s %s\n" "$ts" "$level" "$msg" >> "$LOG_FILE"
    fi
}

log_info()  { _log INFO "$COLOR_INFO"  "$*"; }
log_warn()  { _log WARN "$COLOR_WARN"  "$*"; }
log_error() { _log ERROR "$COLOR_ERROR" "$*"; }
log_ok()    { _log OK "$COLOR_OK" "$*"; }

on_error() {
    local line="$1"
    log_error "Falha na linha $line. Abortando."
}
trap 'on_error $LINENO' ERR

# ------------- Lock global -------------

acquire_lock() {
    local name="${1:-global}"
    local lockfile="${LOCK_DIR}/${name}.lock"
    exec 9>"$lockfile"
    if ! flock -n 9; then
        log_error "Outro processo adm está em execução (lock: $lockfile)."
        exit 1
    fi
}

# ------------- Utilitários -------------

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Comando obrigatório não encontrado: $cmd"
        exit 1
    fi
}

sha256sum_file() {
    sha256sum "$1" | awk '{print $1}'
}

md5sum_file() {
    md5sum "$1" | awk '{print $1}'
}

check_environment() {
    # Ferramentas básicas exigidas para build de pacotes
    require_cmd tar
    require_cmd patch
    require_cmd rsync
    # git só é necessário para 'adm sync'
    # curl ou wget: pelo menos um precisa existir
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        log_error "É necessário ter 'curl' ou 'wget' disponível para downloads."
        exit 1
    fi
}

# ------------- Limpeza de diretórios de trabalho / estado -------------

# Limpa diretório de build e estado de um pacote específico
clean_pkg_workdir() {
    local pkg="$1"

    # Precisamos do PKG_NAME/PKG_VERSION para calcular pkg_id / state_file
    load_package_def "$pkg"

    local build_dir="${ADM_ROOT}/build/${ADM_PROFILE}/$(pkg_id)"
    local state_file
    state_file="$(pkg_state_file)"

    log_info "Limpando workdir de $(pkg_id) para profile ${ADM_PROFILE}: ${build_dir}"
    rm -rf --one-file-system "$build_dir"

    if [ -f "$state_file" ]; then
        log_info "Removendo arquivo de estado: ${state_file}"
        rm -f "$state_file"
    fi
}

# Limpa todos os diretórios de build e estados do profile atual
clean_all_workdirs_for_profile() {
    local profile_build_dir="${ADM_ROOT}/build/${ADM_PROFILE}"
    local state_dir
    state_dir="$(profile_state_dir)"

    log_info "Limpando TODOS os workdirs do profile ${ADM_PROFILE}: ${profile_build_dir}"
    rm -rf --one-file-system "$profile_build_dir"
    mkdir -p "$profile_build_dir"

    log_info "Limpando estados de build do profile ${ADM_PROFILE}: ${state_dir}"
    rm -rf --one-file-system "$state_dir"
    mkdir -p "$state_dir"
}

# Limpeza "inteligente" de nível mais alto:
# - se receber pacotes: limpa só esses workdirs
# - se não receber nada: limpa todos os workdirs do profile atual
adm_clean() {
    local pkgs=()

    while [ $# -gt 0 ]; do
        case "$1" in
            -P|--profile)
                # perfil é tratado fora, em cmd_clean; ignorar aqui
                shift 2 ;;
            -*)
                log_error "Opção desconhecida para clean: $1"
                exit 1 ;;
            *)
                pkgs+=("$1"); shift ;;
        esac
    done

    if [ "${#pkgs[@]}" -eq 0 ]; then
        clean_all_workdirs_for_profile
    else
        local p
        for p in "${pkgs[@]}"; do
            clean_pkg_workdir "$p"
        done
    fi
}

# ------------- Perfis (glibc / musl) -------------

ADM_PROFILE=""
ADM_SYSROOT=""
ADM_TARGET=""
ADM_CFLAGS=""
ADM_CXXFLAGS=""
ADM_LDFLAGS=""

load_profile() {
    local profile="$1"
    local arch="${ADM_ARCH:-x86_64}"

    case "$profile" in
        glibc)
            ADM_PROFILE="glibc"
            ADM_SYSROOT="$ROOTFS_GLIBC"
            ADM_TARGET="${arch}-pc-linux-gnu"
            ADM_CFLAGS="-O2 -pipe -fstack-protector-strong -D_FORTIFY_SOURCE=2"
            ADM_CXXFLAGS="$ADM_CFLAGS"
            ADM_LDFLAGS="-Wl,-O1,-z,relro,-z,now"
            ;;
        musl)
            ADM_PROFILE="musl"
            ADM_SYSROOT="$ROOTFS_MUSL"
            ADM_TARGET="${arch}-pc-linux-musl"
            ADM_CFLAGS="-O2 -pipe -fstack-protector-strong"
            ADM_CXXFLAGS="$ADM_CFLAGS"
            ADM_LDFLAGS="-Wl,-O1"
            ;;
        glibc-opt)
            ADM_PROFILE="glibc-opt"
            ADM_SYSROOT="$ROOTFS_GLIBC"
            ADM_TARGET="${arch}-pc-linux-gnu"
            ADM_CFLAGS="-O3 -pipe -march=native -fstack-protector-strong -D_FORTIFY_SOURCE=2"
            ADM_CXXFLAGS="$ADM_CFLAGS"
            ADM_LDFLAGS="-Wl,-O2,-z,relro,-z,now"
            ;;
        musl-opt)
            ADM_PROFILE="musl-opt"
            ADM_SYSROOT="$ROOTFS_MUSL"
            ADM_TARGET="${arch}-pc-linux-musl"
            ADM_CFLAGS="-O3 -pipe -march=native -fstack-protector-strong"
            ADM_CXXFLAGS="$ADM_CFLAGS"
            ADM_LDFLAGS="-Wl,-O2"
            ;;
        *)
            log_error "Profile desconhecido: $profile (use glibc, musl, glibc-opt, musl-opt)"
            exit 1
            ;;
    esac

    export ADM_PROFILE ADM_SYSROOT ADM_TARGET
    export CC="${CC:-gcc}"
    export CXX="${CXX:-g++}"
    export AR="${AR:-ar}"
    export RANLIB="${RANLIB:-ranlib}"
    export CFLAGS="${CFLAGS:-$ADM_CFLAGS}"
    export CXXFLAGS="${CXXFLAGS:-$ADM_CXXFLAGS}"
    export LDFLAGS="${LDFLAGS:-$ADM_LDFLAGS}"
    export PKG_CONFIG_PATH="${ADM_SYSROOT}/usr/lib/pkgconfig:${ADM_SYSROOT}/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="${ADM_SYSROOT}"
    export MAKEFLAGS="${MAKEFLAGS:--j$(nproc)}"

    log_info "Profile carregado: $ADM_PROFILE (TARGET=$ADM_TARGET, SYSROOT=$ADM_SYSROOT)"
}

# ------------- Carregar definição de pacote -------------

PKG_NAME=""
PKG_VERSION=""
PKG_CATEGORY=""
PKG_SOURCE_URLS=()
PKG_SHA256=""
PKG_MD5=""
PKG_DEPENDS=()
PKG_PATCHES=()

# suporte a patches remotos
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

PKG_FILE=""

find_package_file() {
    local name="$1"
    local file
    file=$(find "$PKG_ROOT" -maxdepth 3 -type f -name "${name}.sh" 2>/dev/null | head -n1 || true)
    if [ -z "$file" ]; then
        log_error "Script de pacote não encontrado para '${name}' em ${PKG_ROOT}"
        exit 1
    fi
    PKG_FILE="$file"
}

load_package_def() {
    local name="$1"
    find_package_file "$name"

    # limpar variáveis de pacote
    PKG_NAME=""
    PKG_VERSION=""
    PKG_CATEGORY=""
    PKG_SOURCE_URLS=()
    PKG_SHA256=""
    PKG_MD5=""
    PKG_DEPENDS=()
    PKG_PATCHES=()

    PKG_PATCH_URLS=()
    PKG_PATCH_SHA256=()
    PKG_PATCH_MD5=()

    # shellcheck disable=SC1090
    source "$PKG_FILE"

    if [ -z "${PKG_NAME:-}" ] || [ -z "${PKG_VERSION:-}" ]; then
        log_error "PKG_NAME ou PKG_VERSION não definidos em $PKG_FILE"
        exit 1
    fi

    if [ "${#PKG_SOURCE_URLS[@]}" -eq 0 ]; then
        log_error "PKG_SOURCE_URLS vazio em $PKG_FILE"
        exit 1
    fi
}

pkg_id() {
    printf "%s-%s" "$PKG_NAME" "$PKG_VERSION"
}

profile_db_dir() {
    printf "%s/%s" "$DB_ROOT" "$ADM_PROFILE"
}

profile_state_dir() {
    printf "%s/%s" "$STATE_DIR" "$ADM_PROFILE"
}

pkg_state_file() {
    local state_dir
    state_dir="$(profile_state_dir)"
    mkdir -p "$state_dir"
    printf "%s/%s.state" "$state_dir" "$(pkg_id)"
}

pkg_db_dir() {
    local dir
    dir="$(profile_db_dir)/${PKG_NAME}"
    mkdir -p "$dir"
    printf "%s" "$dir"
}

pkg_manifest_file() {
    printf "%s/manifest" "$(pkg_db_dir)"
}

pkg_meta_file() {
    printf "%s/meta" "$(pkg_db_dir)"
}

is_installed() {
    [ -f "$(pkg_manifest_file)" ]
}

# ------------- Download e cache (source principal) -------------

download_with_cache() {
    local dest="$1"; shift
    local urls=("$@")
    local tmp="${dest}.part"
    local url
    for url in "${urls[@]}"; do
        log_info "Baixando de $url"
        if command -v curl >/dev/null 2>&1; then
            if curl -fL "$url" -o "$tmp"; then
                mv "$tmp" "$dest"
                return 0
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget -O "$tmp" "$url"; then
                mv "$tmp" "$dest"
                return 0
            fi
        else
            log_error "Nem curl nem wget disponíveis para download."
            exit 1
        fi
        log_warn "Falha ao baixar de $url, tentando próximo link..."
    done
    return 1
}

verify_source_checksum() {
    local file="$1"
    if [ -n "${PKG_SHA256:-}" ]; then
        local sum
        sum="$(sha256sum_file "$file")"
        if [ "$sum" != "$PKG_SHA256" ]; then
            log_warn "SHA256 esperado: $PKG_SHA256, obtido: $sum"
            return 1
        fi
    elif [ -n "${PKG_MD5:-}" ]; then
        local sum
        sum="$(md5sum_file "$file")"
        if [ "$sum" != "$PKG_MD5" ]; then
            log_warn "MD5 esperado: $PKG_MD5, obtido: $sum"
            return 1
        fi
    else
        log_warn "Nenhum checksum definido para $(pkg_id); pulando verificação."
    fi
    return 0
}

# ------------- Download unificado de TODOS os sources do pacote -------------

ensure_sources_downloaded() {
    if [ "${#PKG_SOURCES[@]:-0}" -eq 0 ]; then
        log_error "PKG_SOURCES está vazio em $(pkg_id)"
        exit 1
    fi

    mkdir -p "$SOURCE_CACHE"

    local entry name urls sha_list dest tries have u
    for entry in "${PKG_SOURCES[@]}"; do
        IFS='|' read -r name urls sha_list <<< "$entry"
        dest="${SOURCE_CACHE}/${name}"

        if [ -z "$name" ] || [ -z "$urls" ]; then
            log_error "Entrada inválida em PKG_SOURCES: '$entry'"
            exit 1
        fi

        tries=0
        while :; do
            if [ -f "$dest" ]; then
                if [ -n "${sha_list:-}" ]; then
                    have="$(sha256sum_file "$dest")"
                    for u in $sha_list; do
                        if [ "$have" = "$u" ]; then
                            log_ok "Source verificado no cache: $name"
                            break 2
                        fi
                    done
                    log_warn "Checksum inválido para $name, removendo"
                    rm -f "$dest"
                else
                    log_ok "Source sem checksum no cache: $name"
                    break
                fi
            fi

            tries=$((tries+1))
            [ "$tries" -gt 5 ] && {
                log_error "Falha ao baixar $name após $tries tentativas"
                exit 1
            }

            for u in $urls; do
                log_info "Baixando $name de $u"
                if download_with_cache "$dest" "$u"; then
                    break
                fi
            done
        done
    done
}

# ------------- Download de patches (PKG_PATCH_URLS) -------------

ensure_patches_downloaded() {
    # Se o pacote não declarou patches remotos, nada a fazer.
    if [ "${#PKG_PATCH_URLS[@]:-0}" -eq 0 ]; then
        return 0
    fi

    PKG_PATCHES=("${PKG_PATCHES[@]:-}")

    local i url dest sum_sha sum_md5 sum_have

    for i in "${!PKG_PATCH_URLS[@]}"; do
        url="${PKG_PATCH_URLS[$i]}"
        dest="${SOURCE_CACHE}/$(basename "$url")"

        sum_sha="${PKG_PATCH_SHA256[$i]:-}"
        sum_md5="${PKG_PATCH_MD5[$i]:-}"

        if [ -f "$dest" ]; then
            if [ -n "$sum_sha" ]; then
                sum_have="$(sha256sum_file "$dest")"
                if [ "$sum_have" != "$sum_sha" ]; then
                    log_warn "SHA256 do patch $dest não confere, removendo para re-download."
                    rm -f "$dest"
                fi
            elif [ -n "$sum_md5" ]; then
                sum_have="$(md5sum_file "$dest")"
                if [ "$sum_have" != "$sum_md5" ]; then
                    log_warn "MD5 do patch $dest não confere, removendo para re-download."
                    rm -f "$dest"
                fi
            fi
        fi

        if [ ! -f "$dest" ]; then
            log_info "Baixando patch: $url"
            download_with_cache "$dest" "$url"

            if [ -n "$sum_sha" ]; then
                sum_have="$(sha256sum_file "$dest")"
                if [ "$sum_have" != "$sum_sha" ]; then
                    log_error "SHA256 inválido para patch ${dest}: esperado=${sum_sha}, obtido=${sum_have}"
                    exit 1
                fi
            elif [ -n "$sum_md5" ]; then
                sum_have="$(md5sum_file "$dest")"
                if [ "$sum_have" != "$sum_md5" ]; then
                    log_error "MD5 inválido para patch ${dest}: esperado=${sum_md5}, obtido=${sum_have}"
                    exit 1
                fi
            else
                log_warn "Nenhum checksum definido para patch ${dest}; download sem verificação."
            fi
        else
            log_info "Patch em cache: $dest"
        fi

        PKG_PATCHES+=("$dest")
    done
}

# ------------- Extração, patches, hooks -------------

apply_patches() {
    local srcdir="$1"
    if [ "${#PKG_PATCHES[@]}" -eq 0 ]; then
        return 0
    fi
    pushd "$srcdir" >/dev/null
    local p
    for p in "${PKG_PATCHES[@]}"; do
        log_info "Aplicando patch: $p"
        patch -p1 < "$p"
    done
    popd >/dev/null
}

run_hook_if_exists() {
    local hook="$1"
    if declare -f "$hook" >/dev/null 2>&1; then
        log_info "Executando hook: $hook"
        "$hook"
    fi
}

# ------------- Binário em cache -------------

binpkg_path() {
    printf "%s/%s-%s-%s.tar.xz" "$BIN_CACHE" "$ADM_PROFILE" "$PKG_NAME" "$PKG_VERSION"
}

install_from_binpkg_if_available() {
    local binpkg
    binpkg="$(binpkg_path)"
    if [ -f "$binpkg" ]; then
        log_info "Encontrado binário em cache: $binpkg"
        tar -xJf "$binpkg" -C "$ADM_SYSROOT"
        return 0
    fi
    return 1
}

store_binpkg() {
    local destdir="$1"
    # Se DESTDIR está vazio, provavelmente o pacote instalou direto em outro lugar (ex: tools/).
    # Evitamos gerar binário vazio ou inconsistente.
    if [ ! -d "$destdir" ] || ! find "$destdir" -mindepth 1 -type f -o -type l | head -n1 >/dev/null 2>&1; then
        log_warn "DESTDIR vazio para $(pkg_id); não será gerado binário em cache."
        return 0
    fi

    local binpkg
    binpkg="$(binpkg_path)"
    log_info "Gerando binário em cache: $binpkg"
    ( cd "$destdir" && tar -cJf "$binpkg" . )
}

# ------------- Estado de build -------------

set_pkg_state() {
    local state_file
    state_file="$(pkg_state_file)"
    echo "$1" > "$state_file"
}

get_pkg_state() {
    local state_file
    state_file="$(pkg_state_file)"
    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        echo "none"
    fi
}

# ------------- Manifesto -------------

generate_manifest() {
    local before_file="$1"
    local after_file="$2"
    diff -u "$before_file" "$after_file" | awk '
        /^+\// { sub(/^\+/, "", $1); print $1 }
    '
}

snapshot_files() {
    local sysroot="$1"
    local out="$2"
    ( cd "$sysroot" && find . -type f -o -type l ) | sort > "$out"
}

# ------------- Dependências (Kahn) -------------

load_depends_for_pkg() {
    local pkg="$1"
    load_package_def "$pkg"
    local d
    for d in "${PKG_DEPENDS[@]:-}"; do
        echo "$pkg $d"
    done
}

build_dep_graph() {
    local pkgs=("$@")
    local edges_file
    edges_file=$(mktemp)
    local p
    for p in "${pkgs[@]}"; do
        load_depends_for_pkg "$p" >> "$edges_file"
    done
    echo "$edges_file"
}

kahn_toposort() {
    awk '
    {
        if ($1 != "") {
            if (!seen[$1]) { pkg[$1]=1; seen[$1]=1; n_pkg++ }
        }
        if ($2 != "") {
            if (!seen[$2]) { pkg[$2]=1; seen[$2]=1; n_pkg++ }
        }
        if ($1 != "" && $2 != "") {
            edge[$1 SUBSEP $2]=1
            indeg[$1] += 0
            indeg[$2]++
        }
    }
    END {
        for (p in pkg) {
            if (indeg[p] == 0) {
                queue[qtail++] = p
            }
        }
        while (qhead < qtail) {
            u = queue[qhead++]
            order[no++] = u
            for (v in pkg) {
                key = u SUBSEP v
                if (edge[key]) {
                    indeg[v]--
                    edge[key]=0
                    if (indeg[v] == 0) {
                        queue[qtail++] = v
                    }
                }
            }
        }
        if (no != n_pkg) {
            print "CYCLE" > "/dev/stderr"
            exit 1
        }
        for (i = 0; i < no; i++) {
            print order[i]
        }
    }'
}

resolve_dependencies() {
    local pkgs=("$@")
    local edges_file
    edges_file="$(build_dep_graph "${pkgs[@]}")"
    local all_pkgs=()
    all_pkgs=($(awk '{print $1; print $2}' "$edges_file" | awk 'NF>0' | sort -u))

    local p
    for p in "${pkgs[@]}"; do
        if ! printf '%s\n' "${all_pkgs[@]}" | grep -qx "$p"; then
            all_pkgs+=("$p")
        fi
    done

    local sorted
    if ! sorted=$(cat "$edges_file" | kahn_toposort); then
        log_error "Detectado ciclo de dependências."
        rm -f "$edges_file"
        exit 1
    fi
    rm -f "$edges_file"

    local needed=()
    for p in $sorted; do
        if printf '%s\n' "${all_pkgs[@]}" | grep -qx "$p"; then
            needed+=("$p")
        fi
    done
    echo "${needed[@]}"
}

# ------------- Build de pacote -------------

build_one_pkg() {
    local pkg="$1"
    load_package_def "$pkg"

    if is_installed; then
        log_ok "$(pkg_id) já instalado, pulando (sem rebuild desnecessário)."
        return 0
    fi

    if install_from_binpkg_if_available; then
        log_ok "$(pkg_id) instalado a partir do cache de binários."
        return 0
    fi

    local state
    state="$(get_pkg_state)"
    log_info "Estado atual de $(pkg_id): $state"

    local build_dir="${ADM_ROOT}/build/${ADM_PROFILE}/$(pkg_id)"
    local destdir="${build_dir}/destdir"
    mkdir -p "$build_dir" "$destdir"

    export DESTDIR="$destdir"
    export SYSROOT="$ADM_SYSROOT"

    local src_tar=""
    if [ "$state" = "none" ]; then
        src_tar="$(ensure_source_downloaded)"
        log_info "Extraindo source $src_tar em $build_dir"
        tar -xf "$src_tar" -C "$build_dir"
        set_pkg_state "extracted"
        state="extracted"
    fi

    local srcdir
    srcdir="$(find "$build_dir" -maxdepth 1 -mindepth 1 -type d | head -n1)"
    if [ -z "$srcdir" ]; then
        log_error "Não foi possível localizar diretório de source em $build_dir"
        exit 1
    fi

    # Apenas na primeira extração aplicamos patches
    if [ "$state" = "extracted" ]; then
        ensure_patches_downloaded
        apply_patches "$srcdir"
    fi

    pushd "$srcdir" >/dev/null
    run_hook_if_exists "pre_build"

    if [ "$state" = "extracted" ]; then
        if declare -f "build" >/dev/null 2>&1; then
            log_info "Executando função build() de $(pkg_id)"
            build
        elif [ -x "./configure" ]; then
            log_info "Usando padrão ./configure && make && make install (DESTDIR) para $(pkg_id)"
            ./configure \
                --host="$ADM_TARGET" \
                --prefix=/usr \
                --sysconfdir=/etc \
                --disable-static \
                --enable-shared
            make
            make DESTDIR="$DESTDIR" install
        else
            log_error "Nenhuma função build() definida e ./configure não encontrado para $(pkg_id)."
            exit 1
        fi
        set_pkg_state "built"
        state="built"
    fi

    run_hook_if_exists "post_build"

    if [ "$state" != "installed" ]; then
        run_hook_if_exists "pre_install"

        local before after
        before="$(mktemp)"
        after="$(mktemp)"
        snapshot_files "$ADM_SYSROOT" "$before"

        if declare -f "install_pkg" >/dev/null 2>&1; then
            log_info "Executando função install_pkg() de $(pkg_id)"
            install_pkg
        else
            log_info "Instalando DESTDIR em SYSROOT com rsync para $(pkg_id)"
            rsync -a "$DESTDIR"/ "$ADM_SYSROOT"/
        fi

        snapshot_files "$ADM_SYSROOT" "$after"
        local manifest_file
        manifest_file="$(pkg_manifest_file)"
        generate_manifest "$before" "$after" > "$manifest_file"
        rm -f "$before" "$after"

        local meta
        meta="$(pkg_meta_file)"
        {
            echo "name=$PKG_NAME"
            echo "version=$PKG_VERSION"
            echo "profile=$ADM_PROFILE"
            echo "category=$PKG_CATEGORY"
            echo "depends=${PKG_DEPENDS[*]-}"
        } > "$meta"

        run_hook_if_exists "post_install"

        set_pkg_state "installed"

        store_binpkg "$DESTDIR"

        log_ok "$(pkg_id) instalado com sucesso em $ADM_SYSROOT"
    fi

    popd >/dev/null
}

build_with_deps() {
    local pkgs=("$@")
    local order
    order=$(resolve_dependencies "${pkgs[@]}")
    log_info "Ordem de build: $order"
    local p
    for p in $order; do
        build_one_pkg "$p"
    done
}

# ------------- Uninstall -------------

reverse_dependency_map() {
    local profile_dir
    profile_dir="$(profile_db_dir)"
    local meta
    for meta in "$profile_dir"/*/meta; do
        [ -f "$meta" ] || continue
        # shellcheck disable=SC1090
        . "$meta"
        local d
        for d in ${depends:-}; do
            [ -n "$d" ] && echo "$d $name"
        done
    done
}

collect_uninstall_closure() {
    local initial=("$@")
    local tmp_edges tmp_set
    tmp_edges=$(mktemp)
    reverse_dependency_map > "$tmp_edges"

    tmp_set=$(mktemp)
    printf "%s\n" "${initial[@]}" | sort -u > "$tmp_set"

    local changed=1
    while [ "$changed" -eq 1 ]; then
        changed=0
        local pkg
        for pkg in $(awk '{print $1 "\n" $2}' "$tmp_edges" | awk 'NF>0' | sort -u); do
            if grep -qx "$pkg" "$tmp_set"; then
                continue
            fi
            local users
            users=$(awk -v p="$pkg" '$1 == p {print $2}' "$tmp_edges" | sort -u)
            local u
            local needed=0
            for u in $users; do
                if ! grep -qx "$u" "$tmp_set"; then
                    needed=1
                    break
                fi
            done
            if [ "$needed" -eq 0 ] && [ -n "$users" ]; then
                echo "$pkg" >> "$tmp_set"
                changed=1
            fi
        done
    done

    cat "$tmp_set" | sort -u
    rm -f "$tmp_edges" "$tmp_set"
}

uninstall_pkg() {
    local pkg="$1"
    load_package_def "$pkg"

    if ! is_installed; then
        log_warn "$(pkg_id) não está instalado para profile $ADM_PROFILE."
        return 0
    fi

    run_hook_if_exists "pre_uninstall"

    local manifest
    manifest="$(pkg_manifest_file)"
    if [ ! -f "$manifest" ]; then
        log_warn "Manifesto ausente para $(pkg_id); não é possível remoção segura de arquivos."
    else
        pushd "$ADM_SYSROOT" >/dev/null
        tac "$manifest" | while read -r f; do
            if [ -e "$f" ] || [ -L "$f" ]; then
                rm -f "$f"
            fi
        done
        popd >/dev/null
        rm -f "$manifest"
    fi

    rm -rf "$(pkg_db_dir)"

    run_hook_if_exists "post_uninstall"

    log_ok "$(pkg_id) removido de $ADM_SYSROOT"
}

uninstall_with_deps() {
    local pkgs=("$@")
    local closure
    closure=($(collect_uninstall_closure "${pkgs[@]}"))
    if [ "${#closure[@]}" -eq 0 ]; then
        log_warn "Nenhum pacote para remover."
        return 0
    fi
    log_info "Pacotes a remover (incluindo dependentes órfãos): ${closure[*]}"

    local edges_file
    edges_file=$(mktemp)
    reverse_dependency_map > "$edges_file"
    local sorted
    if ! sorted=$(cat "$edges_file" | kahn_toposort); then
        log_warn "Ciclo em deps durante uninstall, removendo na ordem fornecida."
        sorted="${closure[*]}"
    fi
    rm -f "$edges_file"

    local ordered=()
    local p
    for p in $sorted; do
        if printf '%s\n' "${closure[@]}" | grep -qx "$p"; then
            ordered+=("$p")
        fi
    done

    local i
    for (( i=${#ordered[@]}-1; i>=0; i-- )); do
        uninstall_pkg "${ordered[i]}"
    done
}

# ------------- Sync (git) -------------

sync_packages() {
    local repo="${ADM_REPO_URL:-}"
    if [ -d "$PKG_ROOT/.git" ]; then
        log_info "Atualizando repositório de scripts em $PKG_ROOT"
        git -C "$PKG_ROOT" pull --ff-only
    elif [ -n "$repo" ]; then
        log_info "Clonando repositório de scripts de $repo para $PKG_ROOT"
        git clone "$repo" "$PKG_ROOT"
    else
        log_error "PKG_ROOT não é um repositório git e ADM_REPO_URL não foi definido."
        exit 1
    fi
}

# ------------- CLI -------------

usage() {
    cat <<EOF
adm - sistema de build source-based para LFS/DIY

Uso:
  adm build     [-P profile] pacote1 [pacote2 ...]
  adm uninstall [-P profile] pacote1 [pacote2 ...]
  adm sync
  adm list      [-P profile]
  adm clean     [-P profile] [pacote1 ...]
  adm info      pacote
  adm help

Profiles:
  glibc, musl, glibc-opt, musl-opt

Variáveis de ambiente importantes:
  ADM_ROOT, ADM_ARCH, ADM_REPO_URL

Diretórios padrão:
  Scripts de pacotes:   $PKG_ROOT/<categoria>/<pacote>.sh
  Rootfs glibc:         $ROOTFS_GLIBC
  Rootfs musl:          $ROOTFS_MUSL
  Cache de sources:     $SOURCE_CACHE
  Cache de binários:    $BIN_CACHE

EOF
}

cmd_build() {
    check_environment

    local profile="glibc"
    local pkgs=()

    while [ $# -gt 0 ]; do
        case "$1" in
            -P|--profile)
                profile="$2"; shift 2 ;;
            -*)
                log_error "Opção desconhecida: $1"
                exit 1 ;;
            *)
                pkgs+=("$1"); shift ;;
        esac
    done

    if [ "${#pkgs[@]}" -eq 0 ]; then
        log_error "Nenhum pacote especificado para build."
        exit 1
    fi

    load_profile "$profile"
    local logf="${LOG_ROOT}/build-${profile}-$(date +%Y%m%d-%H%M%S).log"
    log_set_file "$logf"
    log_info "Log em $logf"

    acquire_lock "build"
    build_with_deps "${pkgs[@]}"
}

cmd_uninstall() {
    check_environment

    local profile="glibc"
    local pkgs=()

    while [ $# -gt 0 ]; do
        case "$1" in
            -P|--profile)
                profile="$2"; shift 2 ;;
            -*)
                log_error "Opção desconhecida: $1"
                exit 1 ;;
            *)
                pkgs+=("$1"); shift ;;
        esac
    done

    if [ "${#pkgs[@]}" -eq 0 ]; then
        log_error "Nenhum pacote especificado para uninstall."
        exit 1
    fi

    load_profile "$profile"
    local logf="${LOG_ROOT}/uninstall-${profile}-$(date +%Y%m%d-%H%M%S).log"
    log_set_file "$logf"
    log_info "Log em $logf"

    acquire_lock "uninstall"
    uninstall_with_deps "${pkgs[@]}"
}

cmd_clean() {
    check_environment

    local profile="glibc"
    local args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            -P|--profile)
                profile="$2"; shift 2 ;;
            -*)
                log_error "Opção desconhecida: $1"
                exit 1 ;;
            *)
                args+=("$1"); shift ;;
        esac
    done

    load_profile "$profile"
    local logf="${LOG_ROOT}/clean-${profile}-$(date +%Y%m%d-%H%M%S).log"
    log_set_file "$logf"
    log_info "Log em $logf"

    acquire_lock "clean"
    adm_clean "${args[@]}"
}

cmd_list() {
    local profile="glibc"
    if [ "${1:-}" = "-P" ] || [ "${1:-}" = "--profile" ]; then
        profile="$2"
    fi
    load_profile "$profile"
    local dir
    dir="$(profile_db_dir)"
    if [ ! -d "$dir" ]; then
        echo "Nenhum pacote instalado para profile $profile"
        return 0
    fi
    echo "Pacotes instalados para profile $profile:"
    local meta
    for meta in "$dir"/*/meta; do
        [ -f "$meta" ] || continue
        # shellcheck disable=SC1090
        . "$meta"
        printf "  %s-%s (%s)\n" "$name" "$version" "${category:-unknown}"
    done
}

cmd_info() {
    local pkg="${1:-}"
    if [ -z "$pkg" ]; then
        log_error "Uso: adm info pacote"
        exit 1
    fi
    load_package_def "$pkg"
    echo "Pacote:   $PKG_NAME"
    echo "Versão:   $PKG_VERSION"
    echo "Categoria:${PKG_CATEGORY:-}"
    echo "URLs:"
    local u
    for u in "${PKG_SOURCE_URLS[@]}"; do
        echo "  $u"
    done
    echo "Depends:  ${PKG_DEPENDS[*]-}"

    if is_installed; then
        echo "Instalado: sim (profile ${ADM_PROFILE})"
    else
        echo "Instalado: não (profile ${ADM_PROFILE})"
    fi
}

main() {
    if [ $# -eq 0 ]; then
        usage
        exit 0
    fi

    local cmd="$1"; shift || true
    case "$cmd" in
        build)     cmd_build "$@" ;;
        uninstall) cmd_uninstall "$@" ;;
        sync)      sync_packages ;;
        list)      cmd_list "$@" ;;
        info)      cmd_info "$@" ;;
        clean)     cmd_clean "$@" ;;   
        -h|--help|help) usage ;;
        *)
            log_error "Comando desconhecido: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
