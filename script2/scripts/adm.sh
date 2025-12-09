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
    esac`

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

# NOVO: suporte a patches remotos
PKG_PATCH_URLS=()        # URLs dos patches
PKG_PATCH_SHA256=()      # checksums SHA256 por índice (opcional)
PKG_PATCH_MD5=()         # checksums MD5 por índice (opcional)

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

    # NOVO: suporte a patches remotos
    PKG_PATCH_URLS=()        # URLs dos patches
    PKG_PATCH_SHA256=()      # checksums SHA256 por índice (opcional)
    PKG_PATCH_MD5=()         # checksums MD5 por índice (opcional)

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

# ------------- Download e cache -------------

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

ensure_source_downloaded() {
    local tarball_name="${PKG_NAME}-${PKG_VERSION}.tar"
    local cache_file
    cache_file="${SOURCE_CACHE}/${tarball_name}"

    # O script de pacote pode definir PKG_TARBALL explicitamente (incluindo extensão)
    if [ -n "${PKG_TARBALL:-}" ]; then
        cache_file="${SOURCE_CACHE}/${PKG_TARBALL}"
    fi

    local tries=0
    while :; do
        if [ -f "$cache_file" ]; then
            log_info "Source em cache: $cache_file"
            if verify_source_checksum "$cache_file"; then
                echo "$cache_file"
                return 0
            else
                log_warn "Checksum não confere para $cache_file, removendo e baixando novamente."
                rm -f "$cache_file"
            fi
        fi

        tries=$((tries + 1))
        if [ "$tries" -gt 5 ]; then
            log_error "Falha ao baixar source após $tries tentativas."
            exit 1
        fi

        log_info "Baixando source para $(pkg_id) (tentativa $tries)..."
        if ! download_with_cache "$cache_file" "${PKG_SOURCE_URLS[@]}"; then
            log_warn "Download falhou, nova tentativa..."
            continue
        fi

        if verify_source_checksum "$cache_file"; then
            echo "$cache_file"
            return 0
        else
            log_warn "Checksum não confere após download, repetindo..."
            rm -f "$cache_file"
        fi
    done
}

# ------------- Download de patches (PKG_PATCH_URLS) -------------

ensure_patches_downloaded() {
    # Se o pacote não declarou PKG_PATCH_URLS, não há nada a fazer.
    if [ "${#PKG_PATCH_URLS[@]:-0}" -eq 0 ]; then
        return 0
    fi

    # Garante que PKG_PATCHES exista (mesmo se o pacote já tiver preenchido algo manualmente)
    PKG_PATCHES=("${PKG_PATCHES[@]:-}")

    local i url dest sum_sha sum_md5 sum_have

    for i in "${!PKG_PATCH_URLS[@]}"; do
        url="${PKG_PATCH_URLS[$i]}"
        # Usamos o mesmo cache de sources do adm
        dest="${SOURCE_CACHE}/$(basename "$url")"

        # Checksums esperados (podem estar vazios)
        sum_sha="${PKG_PATCH_SHA256[$i]:-}"
        sum_md5="${PKG_PATCH_MD5[$i]:-}"

        # Se o arquivo já existir, conferir checksum (se definido)
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

        # Se não existe (ou checksum não bateu), baixar
        if [ ! -f "$dest" ]; then
            log_info "Baixando patch: $url"
            download_with_cache "$dest" "$url"

            # Verificar checksum após download, se definido
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

        # Adiciona o patch baixado à lista de patches a aplicar
        PKG_PATCHES+=("$dest")
    done
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
    # stdin: edges "A B" meaning A depende de B (B deve vir antes de A)
    awk '
    {
        if (!seen[$1] && $1 != "") { pkg[$1]=1; seen[$1]=1; n_pkg++ }
        if (!seen[$2] && $2 != "") { pkg[$2]=1; seen[$2]=1; n_pkg++ }
        if ($1 != "" && $2 != "") {
            edge[$1 SUBSEP $2]=1
            indeg[$1] += 0
            indeg[$2]++
        }
    }
    END {
        # inicializa fila com nós de indegree 0
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
    # extrair todos os nós
    all_pkgs=($(awk '{print $1; print $2}' "$edges_file" | sort -u))
    # adicionar pkgs pedidos que possam não ter deps
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

    # manter apenas pacotes necessários na ordem
    local needed
    needed=()
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

    # Se já está instalado para este profile, não reconstrói.
    if is_installed; then
        log_ok "$(pkg_id) já instalado, pulando (sem rebuild desnecessário)."
        return 0
    fi

    # Se existir binário no cache, usa ele em vez de rebuild.
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
    if [ "$state" = "none" ] || [ "$state" = "downloaded" ]; then
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

    # Se acabamos de extrair (primeiro build), baixar/aplicar patches agora.
    if [ "$state" = "extracted" ]; then
        # Baixa patches remotos declarados em PKG_PATCH_URLS/PKG_PATCH_SHA256/MD5
        # e adiciona ao array PKG_PATCHES.
        ensure_patches_downloaded

        # Aplica todos os patches listados em PKG_PATCHES.
        apply_patches "$srcdir"
    fi

    pushd "$srcdir" >/dev/null
    run_hook_if_exists "pre_build"

    if [ "$state" = "extracted" ] || [ "$state" = "none" ]; then
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

        # Snapshot antes/depois para gerar manifest de arquivos instalados
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

        # Metadados do pacote
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

        # Gera pacote binário em cache a partir do DESTDIR
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
    # gera pares "dep user" para pacotes instalados
    local profile_dir
    profile_dir="$(profile_db_dir)"
    local meta
    for meta in "$profile_dir"/*/meta; do
        [ -f "$meta" ] || continue
        # shellcheck disable=SC1090
        . "$meta"
        local d
        for d in $depends; do
            echo "$d $name"
        done
    done
}

collect_uninstall_closure() {
    # dado conjunto inicial, inclui dependentes diretos que não terão mais dependentes externos
    local initial=("$@")
    local tmp_edges tmp_set
    tmp_edges=$(mktemp)
    reverse_dependency_map > "$tmp_edges"

    tmp_set=$(mktemp)
    printf "%s\n" "${initial[@]}" | sort -u > "$tmp_set"

    local changed=1
    while [ "$changed" -eq 1 ]; do
        changed=0
        local pkg
        for pkg in $(awk '{print $1 "\n" $2}' "$tmp_edges" | sort -u); do
            # se pkg já marcado para remoção, ignore
            if grep -qx "$pkg" "$tmp_set"; then
                continue
            fi
            # todos os pacotes que dependem de pkg
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
        log_warn "Manifesto ausente para $(pkg_id); não é possível remoção segura."
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
    log_info "Pacotes a remover (com dependentes órfãos): ${closure[*]}"

    # ordem reversa de dependências: usamos grafo inverso e toposort, depois invertido
    local edges_file
    edges_file=$(mktemp)
    reverse_dependency_map > "$edges_file"
    local sorted
    if ! sorted=$(cat "$edges_file" | kahn_toposort); then
        log_warn "Ciclo em deps durante uninstall, removendo na ordem pedida."
        sorted="${closure[*]}"
    fi
    rm -f "$edges_file"

    # filtrar apenas pacotes do closure e inverter
    local ordered=()
    local p
    for p in $sorted; do
        if printf '%s\n' "${closure[@]}" | grep -qx "$p"; then
            ordered+=("$p")
        fi
    done
    # inverter
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
adm - sistema de build source-based para LFS

Uso:
  adm build     [-P profile] pacote1 [pacote2 ...]
  adm uninstall [-P profile] pacote1 [pacote2 ...]
  adm sync
  adm list      [-P profile]
  adm info      pacote

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
    local profile="glibc"
    local pkgs=()

    while [ $# -gt 0 ]; do
        case "$1" in
            -P|--profile)
                profile="$2"; shift 2 ;;
            -*)
                log_error "Opção desconhecido: $1"
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
        printf "  %s-%s\n" "$name" "$version"
    done
}

cmd_info() {
    local pkg="${1:-}"
    if [ -z "$pkg" ]; then
        log_error "Uso: adm info pacote"
        exit 1
    fi
    load_package_def "$pkg"
    echo "Pacote: $PKG_NAME"
    echo "Versão: $PKG_VERSION"
    echo "Categoria: ${PKG_CATEGORY:-}"
    echo "URLs:"
    local u
    for u in "${PKG_SOURCE_URLS[@]}"; do
        echo "  $u"
    done
    echo "Depends: ${PKG_DEPENDS[*]-}"
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
        -h|--help|help) usage ;;
        *)
            log_error "Comando desconhecido: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
