# /opt/adm/packages/toolchain/gcc-pass1.sh

PKG_NAME="gcc-pass1"
PKG_VERSION="15.2.0"
PKG_CATEGORY="toolchain"

# Fonte principal do GCC (múltiplos mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
)
PKG_TARBALL="gcc-${PKG_VERSION}.tar.xz"

# MD5 oficial (BLFS) para gcc-15.2.0.tar.xz
# https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz  
PKG_MD5="b861b092bf1af683c46a8aa2e689a6fd"

# Dependências lógicas (ajuste o nome do pacote conforme você usou)
PKG_DEPENDS=(
  "binutils-pass1"
  # "linux-headers"   # se você quiser forçar essa ordem
)

# --------------------------------------------------------------------
# GCC Pass 1:
# - constrói um cross-GCC mínimo para TARGET=${ADM_TARGET}
# - instala em /tools dentro do rootfs do profile (${ADM_SYSROOT}/tools)
# - integra GMP/MPFR/MPC *in-tree* via adm_fetch_file
# - não suja o host
# --------------------------------------------------------------------

# Pré-build: baixar GMP, MPFR, MPC e integrar no source do GCC
pre_build() {
    # Versões alinhadas com LFS GCC-15.2.0 Pass 1 
    local gmp_ver="6.3.0"
    local mpfr_ver="4.2.2"
    local mpc_ver="1.3.1"

    # Baixar tarballs extras usando o mecanismo do adm (cache + múltiplos URLs)
    adm_fetch_file "gmp-${gmp_ver}.tar.xz" \
        "https://ftp.gnu.org/gnu/gmp/gmp-${gmp_ver}.tar.xz https://gmplib.org/download/gmp/gmp-${gmp_ver}.tar.xz" \
        "" ""  # preencha SHA256/MD5 depois se quiser travar

    adm_fetch_file "mpfr-${mpfr_ver}.tar.xz" \
        "https://ftp.gnu.org/gnu/mpfr/mpfr-${mpfr_ver}.tar.xz https://www.mpfr.org/mpfr-${mpfr_ver}/mpfr-${mpfr_ver}.tar.xz" \
        "" ""  # idem

    adm_fetch_file "mpc-${mpc_ver}.tar.gz" \
        "https://ftp.gnu.org/gnu/mpc/mpc-${mpc_ver}.tar.gz https://ftpmirror.gnu.org/mpc/mpc-${mpc_ver}.tar.gz" \
        "" ""  # idem

    # Agora estamos dentro de gcc-15.2.0/ (srcdir do adm)
    # Integração "in-tree" (como LFS manda):
    tar -xf "${SOURCE_CACHE}/mpfr-${mpfr_ver}.tar.xz"
    mv -v "mpfr-${mpfr_ver}" mpfr

    tar -xf "${SOURCE_CACHE}/gmp-${gmp_ver}.tar.xz"
    mv -v "gmp-${gmp_ver}" gmp

    tar -xf "${SOURCE_CACHE}/mpc-${mpc_ver}.tar.gz"
    mv -v "mpc-${mpc_ver}" mpc

    # Ajustes para x86_64, semelhantes ao LFS multilib (opcionais)
    case "$ADM_TARGET" in
        x86_64-*-linux*)
            if [ -f gcc/config/i386/t-linux64 ]; then
                sed -e '/m64=/s/lib64/lib/' \
                    -e '/m32=/s/m32=.*/m32=..\/lib32$(call if_multiarch,:i386-linux-gnu)/' \
                    -i gcc/config/i386/t-linux64
            fi
            if [ -f gcc/config/i386/i386.h ]; then
                sed '/STACK_REALIGN_DEFAULT/s/0/(!TARGET_64BIT \&\& TARGET_SSE)/' \
                    -i gcc/config/i386/i386.h
            fi
            ;;
    esac
}

build() {
    local tools_dir="${ADM_SYSROOT}/tools"
    mkdir -pv "${tools_dir}"

    mkdir -v build
    cd build

    # Para Pass 1, fazemos um GCC mínimo, sem headers da libc e sem libs extras.
    ../configure \
        --target="${ADM_TARGET}" \
        --prefix=/tools \
        --with-glibc-version=2.42 \
        --with-sysroot="${ADM_SYSROOT}" \
        --with-newlib \
        --without-headers \
        --enable-default-pie \
        --enable-default-ssp \
        --enable-initfini-array \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-decimal-float \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdcxx \
        --enable-languages=c,c++

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm vai fazer o rsync para ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install
}

post_install() {
    local tools_dir="${ADM_SYSROOT}/tools"
    local xgcc="${tools_dir}/bin/${ADM_TARGET}-gcc"

    # Estamos em gcc-15.2.0/build/ aqui; precisamos voltar um nível
    # para acessar gcc/limit*.h
    local saved_pwd
    saved_pwd="$(pwd)"
    cd ..

    # ----------------------------------------------------------------
    # Passo estilo LFS: gerar um limits.h "completo" para o toolchain
    # ----------------------------------------------------------------
    if [ -x "${xgcc}" ]; then
        local libgcc_dir
        libgcc_dir="$("${xgcc}" -print-libgcc-file-name 2>/dev/null | xargs dirname)"

        if [ -d "${libgcc_dir}/include" ]; then
            log_info "Gerando limits.h interno em ${libgcc_dir}/include/limits.h"
            cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
                "${libgcc_dir}/include/limits.h"
        else
            log_warn "Diretório include de libgcc não encontrado em ${libgcc_dir}; pulando geração de limits.h."
        fi
    else
        log_warn "Não foi possível localizar ${xgcc} para gerar limits.h (mas GCC pode estar instalado)."
    fi

    cd "${saved_pwd}"

    # ----------------------------------------------------------------
    # Sanity-check do GCC Pass 1
    # ----------------------------------------------------------------

    if [ ! -x "${xgcc}" ]; then
        log_error "Sanity-check GCC Pass 1 falhou: ${xgcc} não encontrado ou não executável."
        exit 1
    fi

    log_info "GCC Pass 1: ${xgcc} --version:"
    "${xgcc}" --version | head -n1 || \
        log_warn "Não foi possível obter versão de ${xgcc}"

    # Compilar um dummy.c simples para garantir que o toolchain funciona
    local tmpdir
    tmpdir="$(mktemp -d)"
    cat > "${tmpdir}/dummy.c" << 'EOF'
int main(void) { return 0; }
EOF

    if ! "${xgcc}" -c "${tmpdir}/dummy.c" -o "${tmpdir}/dummy.o"; then
        log_error "Sanity-check GCC Pass 1 falhou: não foi possível compilar dummy.c com ${xgcc}."
        rm -rf "${tmpdir}"
        exit 1
    fi

    if [ ! -f "${tmpdir}/dummy.o" ]; then
        log_error "Sanity-check GCC Pass 1 falhou: dummy.o não foi gerado."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check GCC Pass 1 OK para TARGET=${ADM_TARGET}, profile=${ADM_PROFILE}."
}
