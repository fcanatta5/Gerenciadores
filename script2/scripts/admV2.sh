#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Caminhos básicos
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Logging / cores
# ---------------------------------------------------------------------------

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

log_info()  { _log INFO  "$COLOR_INFO"  "$*"; }
log_warn()  { _log WARN  "$COLOR_WARN"  "$*"; }
log_error() { _log ERROR "$COLOR_ERROR" "$*"; }
log_ok()    { _log OK    "$COLOR_OK"    "$*"; }

on_error() {
    local line="$1"
    log_error "Falha na linha $line (veja o log completo em ${LOG_FILE:-<stdout>})."
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Locks (flock)
# ---------------------------------------------------------------------------

acquire_lock() {
    local lock_name="$1"
    local lock_file="${LOCK_DIR}/${lock_name}.lock"
    exec 200>"$lock_file"
    if ! flock -n 200; then
        log_error "Outro processo do adm está em execução (lock: $lock_file)."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Funções utilitárias
# ---------------------------------------------------------------------------

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
    require_cmd tar
    require_cmd patch
    require_cmd rsync
    require_cmd sha256sum
    require_cmd md5sum
    require_cmd awk
    require_cmd find
    require_cmd sort
    require_cmd diff
    require_cmd xargs
    require_cmd grep
    require_cmd nproc
    require_cmd flock
    # Precisamos de pelo menos um downloader: curl ou wget
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        log_error "É necessário ter 'curl' ou 'wget' disponível para downloads."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Perfis (glibc / musl / otimizações)
# ---------------------------------------------------------------------------

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
            if [ "${ADM_IN_CHROOT:-0}" = "1" ]; then
                ADM_SYSROOT="/"
            else
                ADM_SYSROOT="$ROOTFS_GLIBC"
            fi
            ADM_TARGET="${arch}-pc-linux-gnu"
            ADM_CFLAGS="-O2 -pipe -fstack-protector-strong -D_FORTIFY_SOURCE=2"
            ADM_CXXFLAGS="$ADM_CFLAGS"
            ADM_LDFLAGS="-Wl,-O1,-z,relro,-z,now"
            ;;
        musl)
            ADM_PROFILE="musl"
            if [ "${ADM_IN_CHROOT:-0}" = "1" ]; then
                ADM_SYSROOT="/"
            else
                ADM_SYSROOT="$ROOTFS_MUSL"
            fi
            ADM_TARGET="${arch}-pc-linux-musl"
            ADM_CFLAGS="-O2 -pipe -fstack-protector-strong"
            ADM_CXXFLAGS="$ADM_CFLAGS"
            ADM_LDFLAGS="-Wl,-O1"
            ;;
        glibc-opt)
            ADM_PROFILE="glibc-opt"
            if [ "${ADM_IN_CHROOT:-0}" = "1" ]; then
                ADM_SYSROOT="/"
            else
                ADM_SYSROOT="$ROOTFS_GLIBC"
            fi
            ADM_TARGET="${arch}-pc-linux-gnu"
            ADM_CFLAGS="-O3 -pipe -march=native -fstack-protector-strong -D_FORTIFY_SOURCE=2"
            ADM_CXXFLAGS="$ADM_CFLAGS"
            ADM_LDFLAGS="-Wl,-O2,-z,relro,-z,now"
            ;;
        musl-opt)
            ADM_PROFILE="musl-opt"
            if [ "${ADM_IN_CHROOT:-0}" = "1" ]; then
                ADM_SYSROOT="/"
            else
                ADM_SYSROOT="$ROOTFS_MUSL"
            fi
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

profile_state_dir() {
    local dir="${STATE_DIR}/${ADM_PROFILE}"
    mkdir -p "$dir"
    printf "%s" "$dir"
}

profile_db_dir() {
    local dir="${DB_ROOT}/${ADM_PROFILE}"
    mkdir -p "$dir"
    printf "%s" "$dir"
}

# ---------------------------------------------------------------------------
# Carregamento de scripts de pacote
# ---------------------------------------------------------------------------

PKG_NAME=""
PKG_VERSION=""
PKG_CATEGORY=""
PKG_SOURCE_URLS=()
PKG_TARBALL=""
PKG_SHA256=""
PKG_MD5=""
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()
PKG_PATCHES=()
PKG_DEPENDS=()

reset_pkg_vars() {
    PKG_NAME=""
    PKG_VERSION=""
    PKG_CATEGORY=""
    PKG_SOURCE_URLS=()
    PKG_TARBALL=""
    PKG_SHA256=""
    PKG_MD5=""
    PKG_PATCH_URLS=()
    PKG_PATCH_SHA256=()
    PKG_PATCH_MD5=()
    PKG_PATCHES=()
    PKG_DEPENDS=()
}

pkg_script_path() {
    local pkg="$1"
    if [ -f "$pkg" ]; then
        printf "%s" "$pkg"
        return 0
    fi
    local category name
    category="${pkg%%/*}"
    name="${pkg##*/}"
    if [ "$category" = "$name" ]; then
        if [ -f "${PKG_ROOT}/${pkg}.sh" ]; then
            printf "%s/%s.sh" "$PKG_ROOT" "$pkg"
            return 0
        fi
        if [ -f "${PKG_ROOT}/base/${pkg}.sh" ]; then
            printf "%s/base/%s.sh" "$PKG_ROOT" "$pkg"
            return 0
        fi
    fi
    if [ -f "${PKG_ROOT}/${category}/${name}.sh" ]; then
        printf "%s/%s/%s.sh" "$PKG_ROOT" "$category" "$name"
        return 0
    fi
    return 1
}

load_package_def() {
    local pkg="$1"
    reset_pkg_vars

    local script
    if ! script="$(pkg_script_path "$pkg")"; then
        log_error "Script de pacote não encontrado para '$pkg'"
        exit 1
    fi

    # shellcheck disable=SC1090
    . "$script"

    if [ -z "$PKG_NAME" ] || [ -z "$PKG_VERSION" ]; then
        log_error "Script $script não definiu PKG_NAME/PKG_VERSION corretamente."
        exit 1
    fi
    if [ -z "$PKG_CATEGORY" ]; then
        PKG_CATEGORY="base"
    fi
}

pkg_id() {
    printf "%s-%s" "$PKG_NAME" "$PKG_VERSION"
}

# ---------------------------------------------------------------------------
# Download / cache (genérico)
# ---------------------------------------------------------------------------

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
        else
            if wget -O "$tmp" "$url"; then
                mv "$tmp" "$dest"
                return 0
            fi
        fi
        log_warn "Falha ao baixar de $url, tentando próximo espelho..."
    done
    return 1
}

adm_fetch_file() {
    local tarball="$1"
    local urls_str="$2"
    local sha256="$3"
    local md5="$4"

    mkdir -p "$SOURCE_CACHE"

    local dest="${SOURCE_CACHE}/${tarball}"

    local urls=()
    # shellcheck disable=SC2206
    urls=($urls_str)

    while :; do
        if [ ! -f "$dest" ]; then
            if [ "${#urls[@]}" -eq 0 ]; then
                log_error "Sem URLs para baixar $tarball"
                return 1
            fi
            log_info "Baixando $tarball..."
            if ! download_with_cache "$dest" "${urls[@]}"; then
                log_error "Falha ao baixar $tarball de todas as URLs."
                return 1
            fi
        fi

        local ok=1
        if [ -n "$sha256" ]; then
            local got
            got="$(sha256sum_file "$dest")"
            if [ "$got" != "$sha256" ]; then
                log_warn "SHA256 incorreto para $tarball (esperado $sha256, obtido $got). Removendo e tentando novamente."
                rm -f "$dest"
                ok=0
            fi
        elif [ -n "$md5" ]; then
            local got
            got="$(md5sum_file "$dest")"
            if [ "$got" != "$md5" ]; then
                log_warn "MD5 incorreto para $tarball (esperado $md5, obtido $got). Removendo e tentando novamente."
                rm -f "$dest"
                ok=0
            fi
        else
            log_warn "Nenhum checksum definido para $tarball; não será verificado."
        fi

        if [ "$ok" -eq 1 ]; then
            break
        fi
    done

    printf "%s" "$dest"
}

# ---------------------------------------------------------------------------
# Download principal (source)
# ---------------------------------------------------------------------------

ensure_source_downloaded() {
    local tarball_name="${PKG_NAME}-${PKG_VERSION}.tar"
    if [ -n "${PKG_TARBALL:-}" ]; then
        tarball_name="$PKG_TARBALL"
    fi

    local cache_file="${SOURCE_CACHE}/${tarball_name}"
    local urls_str="${PKG_SOURCE_URLS[*]:-}"

    local sha256="${PKG_SHA256:-}"
    local md5="${PKG_MD5:-}"

    if [ -f "$cache_file" ]; then
        log_info "Source já em cache: $cache_file"
        if [ -n "$sha256" ]; then
            local got
            got="$(sha256sum_file "$cache_file")"
            if [ "$got" != "$sha256" ]; then
                log_warn "SHA256 incorreto para $tarball_name em cache; removendo e baixando novamente."
                rm -f "$cache_file"
            fi
        elif [ -n "$md5" ]; then
            local got
            got="$(md5sum_file "$cache_file")"
            if [ "$got" != "$md5" ]; then
                log_warn "MD5 incorreto para $tarball_name em cache; removendo e baixando novamente."
                rm -f "$cache_file"
            fi
        fi
    fi

    if [ ! -f "$cache_file" ]; then
        cache_file="$(adm_fetch_file "$tarball_name" "$urls_str" "$sha256" "$md5")"
    fi

    printf "%s" "$cache_file"
}

# ---------------------------------------------------------------------------
# Patches
# ---------------------------------------------------------------------------

ensure_patches_downloaded() {
    local i
    PKG_PATCHES=("${PKG_PATCHES[@]:-}")
    local n_urls=${#PKG_PATCH_URLS[@]:-}
    if [ "$n_urls" -eq 0 ]; then
        return 0
    fi
    for ((i=0; i<n_urls; i++)); do
        local url="${PKG_PATCH_URLS[$i]}"
        local sha="${PKG_PATCH_SHA256[$i]:-}"
        local md="${PKG_PATCH_MD5[$i]:-}"
        local base
        base="$(basename "$url")"
        local dest="${SOURCE_CACHE}/${base}"
        local urls_str="$url"
        if [ ! -f "$dest" ]; then
            log_info "Baixando patch $base"
            adm_fetch_file "$base" "$urls_str" "$sha" "$md" >/dev/null
        fi
        PKG_PATCHES+=("$dest")
    done
}

apply_patches() {
    local srcdir="$1"
    if [ "${#PKG_PATCHES[@]:-}" -eq 0 ]; then
        return 0
    fi
    pushd "$srcdir" >/dev/null
    local p
    for p in "${PKG_PATCHES[@]}"; do
        log_info "Aplicando patch: $p"
        patch -Np1 -i "$p"
    done
    popd >/dev/null
}

# ---------------------------------------------------------------------------
# Binários em cache
# ---------------------------------------------------------------------------

binpkg_path() {
    local id
    id="$(pkg_id)"
    printf "%s/%s-%s.tar.xz" "$BIN_CACHE" "$id" "$ADM_PROFILE"
}

install_from_binpkg_if_available() {
    local binpkg
    binpkg="$(binpkg_path)"
    if [ ! -f "$binpkg" ]; then
        return 1
    fi

    log_info "Encontrado binário em cache: $binpkg"

    # Se já está instalado segundo o DB, não fazemos nada.
    if is_installed; then
        log_ok "$(pkg_id) já registrado como instalado; pulando extração do binário."
        return 0
    fi

    local before after
    before="$(mktemp)"
    after="$(mktemp)"

    snapshot_files "$ADM_SYSROOT" "$before"

    # Extrai o binário diretamente no SYSROOT do profile
    tar -xJf "$binpkg" -C "$ADM_SYSROOT"

    snapshot_files "$ADM_SYSROOT" "$after"

    # Gera manifesto com base na diferença antes/depois
    local manifest_file
    manifest_file="$(pkg_manifest_file)"
    generate_manifest "$before" "$after" > "$manifest_file"
    rm -f "$before" "$after"

    # Registra metadados básicos
    local meta
    meta="$(pkg_meta_file)"
    {
        echo "name=$PKG_NAME"
        echo "version=$PKG_VERSION"
        echo "profile=$ADM_PROFILE"
        echo "category=$PKG_CATEGORY"
        echo "depends=${PKG_DEPENDS[*]-}"
    } > "$meta"

    # Marca estado como instalado
    set_pkg_state "installed"

    log_ok "$(pkg_id) instalado a partir do cache de binários em $ADM_SYSROOT"
    return 0
}

store_binpkg() {
    local destdir="$1"
    if [ ! -d "$destdir" ] || ! find "$destdir" -mindepth 1 -type f -o -type l | head -n1 >/dev/null 2>&1; then
        log_warn "DESTDIR vazio para $(pkg_id); não será gerado binário em cache."
        return 0
    fi

    local binpkg
    binpkg="$(binpkg_path)"
    log_info "Gerando binário em cache: $binpkg"
    ( cd "$destdir" && tar -cJf "$binpkg" . )
}

# ---------------------------------------------------------------------------
# Estado de build
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Manifesto
# ---------------------------------------------------------------------------

snapshot_files() {
    local sysroot="$1"
    local out="$2"
    ( cd "$sysroot" && find . -type f -o -type l | sort ) > "$out"
}

generate_manifest() {
    local before_file="$1"
    local after_file="$2"
    diff -u "$before_file" "$after_file" | awk '
        /^\+\.\// {
            gsub(/^\+/, "", $1);
            print $1
        }
    '
}

# ---------------------------------------------------------------------------
# Dependências (Kahn, com grafo transitivo)
# ---------------------------------------------------------------------------

load_depends_for_pkg() {
    local pkg="$1"
    load_package_def "$pkg"
    local d
    for d in "${PKG_DEPENDS[@]:-}"; do
        echo "$pkg $d"
    done
}

build_dep_graph() {
    # Constrói o grafo de dependências de forma transitiva:
    # parte da lista de pacotes solicitados, segue PKG_DEPENDS
    # recursivamente até esgotar o grafo, evitando ciclos via
    # conjunto de "visitados".
    local pkgs=("$@")
    local edges_file
    edges_file=$(mktemp)

    local visited_file
    visited_file=$(mktemp)
    : > "$visited_file"

    # fila de processamento (BFS simples)
    local queue=("${pkgs[@]}")

    while [ "${#queue[@]}" -gt 0 ]; do
        local next_queue=()
        local p
        for p in "${queue[@]}"; do
            # já processado?
            if grep -qx "$p" "$visited_file" 2>/dev/null; then
                continue
            fi
            echo "$p" >> "$visited_file"

            # carrega deps do pacote atual
            load_package_def "$p"
            local d
            for d in "${PKG_DEPENDS[@]:-}"; do
                echo "$p $d" >> "$edges_file"
                # agenda dependência para exploração
                if ! grep -qx "$d" "$visited_file" 2>/dev/null; then
                    next_queue+=("$d")
                fi
            done
        done
        queue=("${next_queue[@]}")
    done

    rm -f "$visited_file"
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
        log_error "Ciclo detectado em dependências."
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

# ---------------------------------------------------------------------------
# Build de um pacote
# ---------------------------------------------------------------------------

run_hook_if_exists() {
    local hook="$1"
    if declare -f "$hook" >/dev/null 2>&1; then
        log_info "Executando hook $hook() para $(pkg_id)"
        "$hook"
    fi
}

build_one_pkg() {
    local pkg="$1"
    load_package_def "$pkg"

    if is_installed; then
        log_ok "$(pkg_id) já instalado, pulando (sem rebuild desnecessário)."
        return 0
    fi

    if install_from_binpkg_if_available; then
        # install_from_binpkg_if_available já cuidou de manifest/meta/state
        return 0
    fi

    local state
    state="$(get_pkg_state)"

    local build_dir="${ADM_ROOT}/build/${ADM_PROFILE}/$(pkg_id)"
    local destdir="${ADM_ROOT}/destdir/${ADM_PROFILE}/$(pkg_id)"

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
    srcdir="$(find "$build_dir" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
    if [ -z "$srcdir" ]; then
        log_error "Não foi possível localizar diretório de source em $build_dir"
        exit 1
    fi

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
            log_info "Instalando via rsync de $DESTDIR para $ADM_SYSROOT"
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
    if [ "${#pkgs[@]}" -eq 0 ]; then
        log_error "Nenhum pacote especificado."
        exit 1
    fi

    local order
    order=$(resolve_dependencies "${pkgs[@]}")
    log_info "Ordem de build: $order"
    local p
    for p in $order; do
        build_one_pkg "$p"
    done
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

reverse_dependency_map() {
    local profile_dir
    profile_dir="$(profile_db_dir)"
    if [ ! -d "$profile_dir" ]; then
        return 0
    fi
    local meta
    for meta in "$profile_dir"/*/meta; do
        [ -f "$meta" ] || continue
        # shellcheck disable=SC1090
        . "$meta"
        local pkg="${name}-${version}"
        local dep
        for dep in ${depends:-}; do
            echo "$pkg $dep"
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
    while [ "$changed" -eq 1 ]; do
        changed=0
        local p dep
        while read -r p dep; do
            if printf '%s\n' "$(cut -d- -f1 <<< "$p")" >/dev/null 2>&1; then :; fi
            if printf '%s\n' "$(cut -d- -f1 <<< "$dep")" >/dev/null 2>&1; then :; fi
        done < /dev/null

        local pk d
        while read -r pk d; do
            if printf '%s\n' "${initial[@]}" | grep -qx "$pk"; then
                if ! grep -qx "$d" "$tmp_set"; then
                    echo "$d" >> "$tmp_set"
                    changed=1
                fi
            fi
        done < "$tmp_edges"
    done

    sort -u "$tmp_set"
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
        log_info "Removendo arquivos listados em $manifest"
        pushd "$ADM_SYSROOT" >/dev/null
        tac "$manifest" | while IFS= read -r f; do
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

# ---------------------------------------------------------------------------
# Limpeza de workdirs / estados
# ---------------------------------------------------------------------------

clean_pkg_workdir() {
    local pkg="$1"

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

clean_all_workdirs_for_profile() {
    local build_root="${ADM_ROOT}/build/${ADM_PROFILE}"
    if [ -d "$build_root" ]; then
        log_info "Limpando todos os workdirs em $build_root"
        rm -rf --one-file-system "$build_root"
    fi

    local state_dir
    state_dir="$(profile_state_dir)"
    if [ -d "$state_dir" ]; then
        log_info "Limpando estados de build em $state_dir"
        rm -rf --one-file-system "$state_dir"
    fi
}

adm_clean() {
    local pkgs=()

    while [ $# -gt 0 ]; do
        case "$1" in
            -P|--profile)
                shift 2 ;; # tratado em cmd_clean
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

# ---------------------------------------------------------------------------
# Sync (git)
# ---------------------------------------------------------------------------

sync_packages() {
    local repo="${ADM_REPO_URL:-}"
    require_cmd git
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

cmd_sync() {
    check_environment
    local logf="${LOG_ROOT}/sync-$(date +%Y%m%d-%H%M%S).log"
    log_set_file "$logf"
    log_info "Log em $logf"

    acquire_lock "sync"
    sync_packages
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
adm - sistema de build source-based para LFS / Linux From Scratch

Uso geral:
  adm build     [-P profile] pacote1 [pacote2 ...]
  adm uninstall [-P profile] pacote1 [pacote2 ...]
  adm list      [-P profile]
  adm info      pacote
  adm sync
  adm chroot    [-P profile] [opções_chroot...] [--] comando_adm [args...]

Comandos:

  build
    Constrói um ou mais pacotes a partir dos scripts de construção.
    - Resolve dependências em ordem topológica.
    - Usa cache de sources e de binários quando disponível.
    - Instala no rootfs do profile selecionado.

    Exemplo:
      adm build -P glibc coreutils-9.9 bash-5.3

  uninstall
    Remove um ou mais pacotes do rootfs do profile.
    - Remove na ordem reversa de dependências.
    - Executa hooks de pre/post-uninstall quando definidos.

    Exemplo:
      adm uninstall -P musl coreutils-9.9

  list
    Lista os pacotes instalados no profile (e suas versões).

    Exemplo:
      adm list -P glibc

  info
    Mostra informações sobre um pacote (metadados, dependências, etc).

    Exemplo:
      adm info coreutils-9.9

  sync
    Sincroniza / atualiza os scripts de construção a partir do repositório git
    configurado em ADM_REPO_URL (por exemplo, atualiza /opt/adm/packages).

    Exemplo:
      adm sync

  chroot
    Gerencia e entra em um chroot seguro baseado no rootfs do profile e
    executa o próprio adm lá dentro (via /opt/adm/adm-chroot.sh).

    Modos principais:
      1) Shell interativo dentro do chroot:
           adm chroot -P glibc --shell

      2) Executar um comando do adm dentro do chroot:
           adm chroot -P glibc -- build coreutils-9.9
           adm chroot -P musl  -- build bash-5.3

    Opções passadas para o wrapper (adm-chroot.sh):
      -P, --profile   glibc | musl | glibc-opt | musl-opt
      --shell         Abre um shell de root dentro do chroot do profile
      --bind-ro DIR   Faz bind read-only de DIR do host dentro do chroot (pode repetir)
      --bind-rw DIR   Faz bind read-write de DIR do host dentro do chroot (pode repetir)
      --debug         Ativa logs detalhados do wrapper

Profiles disponíveis:
  glibc      - rootfs com glibc padrão
  musl       - rootfs com musl padrão
  glibc-opt  - rootfs glibc com flags otimizadas (ex.: -O3 -march=native)
  musl-opt   - rootfs musl com flags otimizadas

Variáveis de ambiente importantes:
  ADM_ROOT     - Diretório raiz do adm (padrão: /opt/adm)
  ADM_ARCH     - Arquitetura alvo (ex.: x86_64)
  ADM_REPO_URL - URL do repositório git com scripts de pacotes

Diretórios padrão:
  Scripts de pacotes:   \$PKG_ROOT/<categoria>/<pacote>.sh
  Rootfs glibc:         \$ROOTFS_GLIBC
  Rootfs musl:          \$ROOTFS_MUSL
  Cache de sources:     \$SOURCE_CACHE
  Cache de binários:    \$BIN_CACHE

Exemplos rápidos:
  # Construir coreutils e bash para glibc (fora do chroot)
  adm build -P glibc coreutils-9.9 bash-5.3

  # Construir coreutils dentro do chroot glibc-rootfs
  adm chroot -P glibc -- build coreutils-9.9

  # Entrar em shell dentro do chroot musl-rootfs
  adm chroot -P musl --shell

EOF
}

# ---------------------------------------------------------------------------
# Subcomandos
# ---------------------------------------------------------------------------

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

    acquire_lock "build-${profile}"
    build_with_deps "${pkgs[@]}"
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
    local pkg_arg=()

    while [ $# -gt 0 ]; do
        case "$1" in
            -P|--profile)
                profile="$2"; shift 2 ;;
            *)
                pkg_arg+=("$1"); shift ;;
        esac
    done

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
    local profile="glibc"
    local pkg=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -P|--profile)
                profile="$2"; shift 2 ;;
            -*)
                log_error "Opção desconhecida: $1"
                exit 1 ;;
            *)
                pkg="$1"; shift ;;
        esac
    done

    if [ -z "$pkg" ]; then
        log_error "Uso: adm info [-P profile] pacote"
        exit 1
    fi

    load_profile "$profile"
    load_package_def "$pkg"

    echo "Pacote:   $PKG_NAME"
    echo "Versão:   $PKG_VERSION"
    echo "Categoria:$PKG_CATEGORY"
    echo "Profile:  $ADM_PROFILE"
    echo "Target:   $ADM_TARGET"
    echo "SYSROOT:  $ADM_SYSROOT"
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

# ----------------------------------------------------------------------
# Subcomando: chroot
# Wrapper para /opt/adm/adm-chroot.sh
# Uso:
#   adm chroot -P glibc -- build coreutils-9.9
#   adm chroot -P musl  -- shell
# ----------------------------------------------------------------------
cmd_chroot() {
    # Todos os argumentos depois de "chroot" vêm aqui intactos
    # Exemplo:
    #   adm chroot -P glibc -- build coreutils-9.9
    # vira:
    #   cmd_chroot -P glibc -- build coreutils-9.9

    local wrapper

    # Local padrão do wrapper
    wrapper="${ADM_ROOT:-/opt/adm}/adm-chroot.sh"

    if [ ! -x "${wrapper}" ]; then
        log_error "Wrapper de chroot não encontrado ou não executável: ${wrapper}"
        log_error "Verifique se você instalou /opt/adm/adm-chroot.sh e deu chmod +x."
        exit 1
    fi

    exec "${wrapper}" "$@"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
    if [ $# -lt 1 ]; then
        usage
        exit 1
    fi

    local cmd="$1"; shift || true

    case "$cmd" in
        build)
            cmd_build "$@"
            ;;
        uninstall)
            cmd_uninstall "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        info)
            cmd_info "$@"
            ;;
        clean)
            cmd_clean "$@"
            ;;
        sync)
            cmd_sync "$@"
            ;;
        chroot)
            cmd_chroot "$@"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
