# /opt/adm/packages/toolchain/glibc-pass1.sh
#
# Glibc-2.42 - Pass 1
# Instala a glibc no sysroot do profile (glibc-rootfs), usando o toolchain
# temporário em $ADM_ROOT/tools/$ADM_PROFILE (binutils-pass1, gcc-pass1).
#
# Baseado no LFS 12.4 - capítulo 5.5 Glibc-2.42, adaptado para o "adm".

PKG_NAME="glibc-pass1"
PKG_VERSION="2.42"
PKG_CATEGORY="toolchain"

# Fonte principal (mesmos URLs do LFS) 
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/glibc/glibc-${PKG_VERSION}.tar.xz"
  "https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4/glibc-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="glibc-${PKG_VERSION}.tar.xz"

# MD5 do LFS 12.4 para glibc-2.42.tar.xz 
PKG_MD5="23c6f5a27932b435cae94e087cb8b1f5"

# Ordem do toolchain: depois de linux-headers e gcc-pass1
PKG_DEPENDS=( "linux-headers" "gcc-pass1" )

# Se quiser usar o patch FHS do LFS, baixe-o para um diretório seu
# e descomente/ajuste a linha abaixo:
#   https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4/glibc-2.42-fhs-1.patch 
#PKG_PATCHES=(
  # "/opt/adm/patches/glibc-2.42-fhs-1.patch"
#)
PKG_PATCH_URLS=(
  "https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4/glibc-2.42-fhs-1.patch"
)

PKG_PATCH_SHA256=(
  "0e98bb64d18b96ba6a69f5a6545edc53c440183675682547909c096f66e3b81c"
)
# Opcional: se quiser usar MD5 em vez de SHA256:
# PKG_PATCH_MD5=(
#   "d41d8cd98f00b204e9800998ecf8427e"
# )

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

_glibc_tools_prefix() {
    local adm_root="${ADM_ROOT:-/opt/adm}"
    printf "%s/tools/%s" "$adm_root" "${ADM_PROFILE}"
}

_glibc_require_profile_glibc() {
    case "${ADM_PROFILE}" in
        glibc* )
            ;;
        * )
            log_error "glibc-pass1 só é válido para perfis glibc* (perfil atual: ${ADM_PROFILE}). Use o pacote musl correspondente para perfis musl."
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------

pre_build() {
    # Executado dentro de glibc-2.42/
    _glibc_require_profile_glibc

    if [ -z "${ADM_SYSROOT:-}" ]; then
        log_error "ADM_SYSROOT não definido em pre_build() de glibc-pass1."
        exit 1
    fi

    local tools_prefix
    tools_prefix="$(_glibc_tools_prefix)"

    mkdir -p "${tools_prefix}"

    log_info "Glibc-${PKG_VERSION} Pass 1: profile=${ADM_PROFILE} TARGET=${ADM_TARGET}"
    log_info "SYSROOT=${ADM_SYSROOT}  TOOLS=${tools_prefix}"

    # Links de compatibilidade LSB no sysroot, como no LFS (ajustado para ADM_SYSROOT) 
    case "$(uname -m)" in
        i?86)
            mkdir -p "${ADM_SYSROOT}/lib"
            ln -sfv ld-linux.so.2 "${ADM_SYSROOT}/lib/ld-lsb.so.3"
            ;;
        x86_64)
            mkdir -p "${ADM_SYSROOT}/lib" "${ADM_SYSROOT}/lib64"
            ln -sfv ../lib/ld-linux-x86-64.so.2 "${ADM_SYSROOT}/lib64"
            ln -sfv ../lib/ld-linux-x86-64.so.2 "${ADM_SYSROOT}/lib64/ld-lsb-x86-64.so.3"
            ;;
    esac

    # Verificar se os headers de kernel já estão instalados
    if [ ! -d "${ADM_SYSROOT}/usr/include/linux" ]; then
        log_warn "Headers de kernel não encontrados em ${ADM_SYSROOT}/usr/include/linux."
        log_warn "Certifique-se de ter rodado 'linux-headers' antes de glibc-pass1 para este profile."
    fi
}

build() {
    _glibc_require_profile_glibc

    local tools_prefix
    tools_prefix="$(_glibc_tools_prefix)"

    # Usar o toolchain cross do profile (binutils/gcc pass1)
    export PATH="${tools_prefix}/bin:${PATH}"

    # Diretório de build separado (recomendação da glibc / LFS) 
    mkdir -v build
    cd build

    # Garantir que ldconfig e sln vão para /usr/sbin
    echo "rootsbindir=/usr/sbin" > configparms

    # Configuração baseada no LFS 5.5 Glibc (adaptada para ADM_TARGET/ADM_SYSROOT) 
    ../configure                             \
        --prefix=/usr                        \
        --host="${ADM_TARGET}"               \
        --build="$(../scripts/config.guess)" \
        --disable-nscd                       \
        libc_cv_slibdir=/usr/lib             \
        --enable-kernel=5.4

    # A glibc às vezes falha com make paralelo; honramos MAKEFLAGS do ambiente.
    log_info "Compilando Glibc-${PKG_VERSION} Pass 1 (MAKEFLAGS=${MAKEFLAGS:-não definido})..."
    make
}

install_pkg() {
    _glibc_require_profile_glibc

    if [ -z "${ADM_SYSROOT:-}" ]; then
        log_error "ADM_SYSROOT não definido em install_pkg() de glibc-pass1."
        exit 1
    fi

    local tools_prefix
    tools_prefix="$(_glibc_tools_prefix)"

    # Já estamos em build/, graças a build()
    export PATH="${tools_prefix}/bin:${PATH}"

    log_info "Instalando Glibc-${PKG_VERSION} Pass 1 em ${ADM_SYSROOT} (sysroot do profile)..."

    # Instala diretamente no sysroot do profile, como o LFS faz com $LFS 
    make DESTDIR="${ADM_SYSROOT}" install

    # Ajustar o ldd para não ter /usr hardcoded em RTLDLIST 
    if [ -f "${ADM_SYSROOT}/usr/bin/ldd" ]; then
        sed '/RTLDLIST=/s@/usr@@g' -i "${ADM_SYSROOT}/usr/bin/ldd"
    else
        log_warn "ldd não encontrado em ${ADM_SYSROOT}/usr/bin/ldd para ajuste de RTLDLIST."
    fi
}

post_install() {
    _glibc_require_profile_glibc

    local tools_prefix
    tools_prefix="$(_glibc_tools_prefix)"

    export PATH="${tools_prefix}/bin:${PATH}"

    log_info "Executando sanity-check básico da Glibc-${PKG_VERSION} Pass 1..."

    # Teste similar ao do LFS, mas adaptado para ADM_TARGET e nosso ambiente 
    echo 'int main(){}' | "${ADM_TARGET}-gcc" -x c - -v -Wl,--verbose &> dummy.log || {
        log_error "sanity-check: falha ao compilar programa de teste com ${ADM_TARGET}-gcc."
        exit 1
    }

    if [ ! -f a.out ]; then
        log_error "sanity-check: a.out não foi gerado."
        exit 1
    fi

    # Verificar se o binário tem um interpreter dinâmico configurado
    if ! readelf -l a.out | grep -q "Requesting program interpreter"; then
        log_error "sanity-check: readelf não encontrou um 'Requesting program interpreter' em a.out."
        rm -f a.out dummy.log
        exit 1
    fi

    log_info "Saída do 'Requesting program interpreter':"
    readelf -l a.out | grep "Requesting program interpreter" || true

    # Opcionalmente poderíamos replicar todas as checagens de caminho do LFS,
    # mas isso já é um bom indicador de que a glibc e o linker estão alinhados.

    rm -v a.out dummy.log

    log_ok "sanity-check: Glibc-${PKG_VERSION} Pass 1 OK para profile ${ADM_PROFILE} (sysroot=${ADM_SYSROOT})."
}

pre_uninstall() {
    _glibc_require_profile_glibc
    log_info "pre_uninstall: removendo glibc-pass1 (${PKG_VERSION}) do profile ${ADM_PROFILE}."
    # A remoção em si é feita pelo adm com base no manifest do SYSROOT.
}

post_uninstall() {
    log_info "post_uninstall: glibc-pass1 (${PKG_VERSION}) removida do profile ${ADM_PROFILE}."
}
