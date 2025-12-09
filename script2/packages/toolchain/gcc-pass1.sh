# /opt/adm/packages/toolchain/gcc-pass1.sh
#
# GCC-15.2.0 - Pass 1 (cross, temporary tools)
# Constrói um cross-GCC temporário e instala em $ADM_ROOT/tools/$ADM_PROFILE,
# sem sujar os rootfs glibc-rootfs / musl-rootfs.
#
# Compatível com o gerenciador "adm" definido anteriormente.

PKG_NAME="gcc-pass1"
PKG_VERSION="15.2.0"
PKG_CATEGORY="toolchain"

# Tarball principal do GCC 
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://sourceware.org/pub/gcc/releases/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="gcc-${PKG_VERSION}.tar.xz"

# MD5 oficial do LFS/BLFS para gcc-15.2.0.tar.xz 
PKG_MD5="b861b092bf1af683c46a8aa2e689a6fd"

# GCC Pass 1 depende de binutils-pass1 (toolchain já inicializado)
PKG_DEPENDS=( "binutils-pass1" )

PKG_PATCHES=()

# ---------------------------------------------------------------------
# Prérequisitos GMP/MPFR/MPC (versões usadas no LFS / GCC infra)
# ---------------------------------------------------------------------

_GMP_VERSION="6.3.0"
_MPFR_VERSION="4.2.2"
_MPC_VERSION="1.3.1"

_GMP_TARBALL="gmp-${_GMP_VERSION}.tar.xz"
_MPFR_TARBALL="mpfr-${_MPFR_VERSION}.tar.xz"
_MPC_TARBALL="mpc-${_MPC_VERSION}.tar.gz"

# URLs (principal + mirrors) 6
_GMP_URLS=(
  "https://ftp.gnu.org/gnu/gmp/${_GMP_TARBALL}"
)
_MPFR_URLS=(
  "https://ftp.gnu.org/gnu/mpfr/${_MPFR_TARBALL}"
)
_MPC_URLS=(
  "https://ftp.gnu.org/gnu/mpc/${_MPC_TARBALL}"
)

# MD5 das tarballs, a partir de LFS/Debian/Fossies:
#   gmp-6.3.0.tar.xz    -> d4a3890b5e28df535b653b07798b11b2 7
#   mpfr-4.2.2.tar.xz   -> 7c32c39b8b6e3ae85f25156228156061 8
#   mpc-1.3.1.tar.gz    -> 5c9bc658c9fd0f940e8e3e0f09530c62 9
_GMP_MD5="d4a3890b5e28df535b653b07798b11b2"
_MPFR_MD5="7c32c39b8b6e3ae85f25156228156061"
_MPC_MD5="5c9bc658c9fd0f940e8e3e0f09530c62"

# ---------------------------------------------------------------------
# Helpers locais
# ---------------------------------------------------------------------

_gcc_tools_prefix() {
    local adm_root="${ADM_ROOT:-/opt/adm}"
    printf "%s/tools/%s" "$adm_root" "${ADM_PROFILE}"
}

_fetch_prereq_to_cache() {
    # $1 = tarball, $2 = md5, demais = URLs
    local tarball="$1"; shift
    local md5_expected="$1"; shift
    local urls=("$@")

    local cache_dir="${SOURCE_CACHE:-/opt/adm/cache/sources}"
    local cache_file="${cache_dir}/${tarball}"

    mkdir -p "$cache_dir"

    if [ -f "$cache_file" ]; then
        if [ -n "$md5_expected" ]; then
            local md5_have
            md5_have="$(md5sum_file "$cache_file")"
            if [ "$md5_have" != "$md5_expected" ]; then
                log_warn "MD5 de ${tarball} no cache não confere, removendo e baixando de novo."
                rm -f "$cache_file"
            fi
        fi
    fi

    if [ ! -f "$cache_file" ]; then
        log_info "Baixando pré-requisito ${tarball}..."
        download_with_cache "$cache_file" "${urls[@]}"
        if [ -n "$md5_expected" ]; then
            local md5_have
            md5_have="$(md5sum_file "$cache_file")"
            if [ "$md5_have" != "$md5_expected" ]; then
                log_error "MD5 de ${tarball} não confere (esperado=${md5_expected}, obtido=${md5_have})."
                exit 1
            fi
        fi
    else
        log_info "Pré-requisito em cache: ${cache_file}"
    fi

    printf "%s" "$cache_file"
}

_integrate_gmp_mpfr_mpc() {
    # Executado dentro do diretório de source do GCC (gcc-15.2.0)
    local mpfr_tar gmp_tar mpc_tar

    mpfr_tar="$(_fetch_prereq_to_cache "${_MPFR_TARBALL}" "${_MPFR_MD5}" "${_MPFR_URLS[@]}")"
    gmp_tar="$(_fetch_prereq_to_cache "${_GMP_TARBALL}"  "${_GMP_MD5}"  "${_GMP_URLS[@]}")"
    mpc_tar="$(_fetch_prereq_to_cache "${_MPC_TARBALL}"  "${_MPC_MD5}"  "${_MPC_URLS[@]}")"

    log_info "Extraindo MPFR/GMP/MPC dentro da árvore do GCC..."

    tar -xf "$mpfr_tar"
    mv -v "mpfr-${_MPFR_VERSION}" mpfr

    tar -xf "$gmp_tar"
    mv -v "gmp-${_GMP_VERSION}" gmp

    tar -xf "$mpc_tar"
    mv -v "mpc-${_MPC_VERSION}" mpc
}

# ---------------------------------------------------------------------
# Hooks do pacote
# ---------------------------------------------------------------------

pre_build() {
    # Estamos dentro de $srcdir (gcc-15.2.0) quando o adm chama pre_build()
    local tools_prefix
    tools_prefix="$(_gcc_tools_prefix)"

    mkdir -p "${tools_prefix}"

    log_info "GCC Pass 1: usando tools_prefix=${tools_prefix}"
    log_info "Profile=${ADM_PROFILE} TARGET=${ADM_TARGET} SYSROOT=${ADM_SYSROOT}"

    # Integrar MPFR, GMP e MPC dentro da árvore do GCC, como recomendado pelo LFS.
    _integrate_gmp_mpfr_mpc

    # Ajuste para x86_64: biblioteca 64-bit em lib (não lib64), igual LFS 10
    case "$(uname -m)" in
        x86_64)
            sed -e '/m64=/s/lib64/lib/' \
                -i.orig gcc/config/i386/t-linux64
            ;;
    esac
}

build() {
    local tools_prefix
    tools_prefix="$(_gcc_tools_prefix)"

    # Garante que o toolchain Binutils Pass 1 esteja na frente do PATH
    export PATH="${tools_prefix}/bin:${PATH}"

    mkdir -v build
    cd build

    # Opções comuns, baseadas no LFS – GCC-15.2.0 Pass 1 11
    local conf_opts=(
        "../configure"
        "--target=${ADM_TARGET}"
        "--prefix=${tools_prefix}"
        "--with-sysroot=${ADM_SYSROOT}"
        "--with-newlib"
        "--without-headers"
        "--enable-default-pie"
        "--enable-default-ssp"
        "--disable-nls"
        "--disable-shared"
        "--disable-multilib"
        "--disable-threads"
        "--disable-libatomic"
        "--disable-libgomp"
        "--disable-libquadmath"
        "--disable-libssp"
        "--disable-libvtv"
        "--disable-libstdcxx"
        "--enable-languages=c,c++"
    )

    # Para perfis baseados em glibc, replicamos --with-glibc-version como no LFS.
    # Para musl, isso não faz sentido conceitualmente, então omitimos.
    case "${ADM_PROFILE}" in
        glibc* )
            conf_opts+=("--with-glibc-version=2.42")
            ;;
        * )
            ;;
    esac

    log_info "Configurando GCC Pass 1 com: ${conf_opts[*]}"

    "${conf_opts[@]}"

    log_info "Compilando GCC Pass 1..."
    make
}

install_pkg() {
    # Estamos dentro de build/ (pois build() fez cd build)
    local tools_prefix
    tools_prefix="$(_gcc_tools_prefix)"

    log_info "Instalando GCC Pass 1 em ${tools_prefix} (tools/, não rootfs)..."

    # Instala diretamente em tools_prefix (não usamos DESTDIR para não tocar rootfs)
    make install

    # Após a instalação, criamos o limits.h interno completo, conforme LFS 12
    (
        cd ..
        local target_gcc libgcc_dir

        target_gcc="${tools_prefix}/bin/${ADM_TARGET}-gcc"
        if [ ! -x "${target_gcc}" ]; then
            log_error "Não encontrei ${target_gcc} após install do GCC Pass 1."
            exit 1
        fi

        libgcc_dir="$(dirname "$("${target_gcc}" -print-libgcc-file-name)")"

        mkdir -p "${libgcc_dir}/include"

        log_info "Gerando ${libgcc_dir}/include/limits.h (limitx.h + glimits.h + limity.h)..."
        cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
            "${libgcc_dir}/include/limits.h"
    )
}

post_install() {
    local tools_prefix
    tools_prefix="$(_gcc_tools_prefix)"
    local target_gcc="${tools_prefix}/bin/${ADM_TARGET}-gcc"

    # Checagem simples de “sanidade” do cross-GCC recém-instalado
    if [ ! -x "${target_gcc}" ]; then
        log_error "sanity-check: ${target_gcc} não encontrado."
        exit 1
    fi

    if ! "${target_gcc}" --version >/dev/null 2>&1; then
        log_error "sanity-check: falha ao executar ${target_gcc} --version."
        exit 1
    fi

    log_ok "sanity-check: GCC-${PKG_VERSION} Pass 1 OK em ${tools_prefix} para profile ${ADM_PROFILE} (target ${ADM_TARGET})."
}

pre_uninstall() {
    # Mesmo aviso do binutils-pass1: o manifest do adm é baseado em SYSROOT,
    # mas este pacote instala em tools/, então o uninstall padrão não vai limpar
    # tools/. A remoção de tools/ deve ser planejada separadamente.
    log_warn "pre_uninstall: gcc-pass1 é toolchain temporário; uninstall automático não limpará tools/."
}

post_uninstall() {
    log_info "post_uninstall: nenhuma ação extra para gcc-pass1 (toolchain temporário)."
}
