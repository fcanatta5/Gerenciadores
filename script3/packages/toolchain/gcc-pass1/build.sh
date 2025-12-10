#!/usr/bin/env bash
# GCC-15.2.0 - Pass 1 para o sistema ADM
# Constrói um cross-compiler C-only sem libc em /tools dentro do rootfs do perfil.

set -euo pipefail

adm_metadata() {
    # Identidade do pacote no ADM
    PKG_NAME="toolchain/gcc-pass1"
    PKG_VERSION="15.2.0"
    PKG_RELEASE=1
    PKG_CATEGORY="toolchain"

    # Fontes:
    #  - GCC
    #  - MPFR
    #  - GMP
    #  - MPC
    PKG_SOURCES=(
        "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
        "https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz"
        "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
        "https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"
    )

    # SHA256 dos sources (mesma ordem de PKG_SOURCES)
    PKG_SHA256=(
        "438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e" # gcc-15.2.0.tar.xz
        "b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01" # mpfr-4.2.2.tar.xz
        "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898" # gmp-6.3.0.tar.xz
        "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8" # mpc-1.3.1.tar.gz
    )

    # Se quiser MD5, pode preencher aqui; senão, deixa vazio
    PKG_MD5=()

    # Dependências lógicas dentro do ADM
    # Binutils Pass 1 precisa estar instalado em ${ADM_ROOTFS}/tools
    PKG_DEPENDS=(
        "toolchain/binutils-pass1"
    )

    # Perfis suportados
    PKG_PROFILE_SUPPORT=("glibc" "musl")
}

adm_build() {
    : "${PKG_BUILD_DIR:?PKG_BUILD_DIR não definido}"
    : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"
    : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
    : "${ADM_PROFILE:?ADM_PROFILE não definido}"

    local jobs="${ADM_JOBS:-1}"

    # Determina libc/padrão de target pelo perfil
    local libc
    case "${ADM_PROFILE}" in
        musl) libc="musl" ;;
        *)    libc="gnu"  ;;
    esac

    # Permite sobrescrever via ADM_TARGET
    local target="${ADM_TARGET:-x86_64-adm-linux-${libc}}"

    echo "[GCC-PASS1] Perfil: ${ADM_PROFILE}"
    echo "[GCC-PASS1] ROOTFS: ${ADM_ROOTFS}"
    echo "[GCC-PASS1] DESTDIR: ${PKG_DESTDIR}"
    echo "[GCC-PASS1] BUILD_DIR: ${PKG_BUILD_DIR}"
    echo "[GCC-PASS1] Target: ${target}"
    echo "[GCC-PASS1] Jobs: ${jobs}"

    cd "${PKG_BUILD_DIR}"

    local gcc_srcdir="${PKG_BUILD_DIR}/gcc-${PKG_VERSION}"
    local mpfr_srcdir="${PKG_BUILD_DIR}/mpfr-4.2.2"
    local gmp_srcdir="${PKG_BUILD_DIR}/gmp-6.3.0"
    local mpc_srcdir="${PKG_BUILD_DIR}/mpc-1.3.1"

    if [[ ! -d "${gcc_srcdir}" ]]; then
        echo "[GCC-PASS1] ERRO: diretório de fonte não encontrado: ${gcc_srcdir}" >&2
        exit 1
    fi

    # Embute MPFR/GMP/MPC dentro da árvore do GCC para build auto-contido
    if [[ -d "${mpfr_srcdir}" && ! -d "${gcc_srcdir}/mpfr" ]]; then
        mv "${mpfr_srcdir}" "${gcc_srcdir}/mpfr"
    fi

    if [[ -d "${gmp_srcdir}" && ! -d "${gcc_srcdir}/gmp" ]]; then
        mv "${gmp_srcdir}" "${gcc_srcdir}/gmp"
    fi

    if [[ -d "${mpc_srcdir}" && ! -d "${gcc_srcdir}/mpc" ]]; then
        mv "${mpc_srcdir}" "${gcc_srcdir}/mpc"
    fi

    # Diretório de build isolado
    local builddir="${PKG_BUILD_DIR}/build-gcc-pass1"
    rm -rf "${builddir}"
    mkdir -p "${builddir}"
    cd "${builddir}"

    # Prefixo /tools dentro do rootfs
    local prefix="/tools"

    # Garante que o binutils cross esteja visível no PATH
    export PATH="${ADM_ROOTFS}${prefix}/bin:${PATH}"

    # Flags mínimas (pode ajustar depois)
    export CFLAGS="-O2 -pipe"
    export CXXFLAGS="-O2 -pipe"

    # Configuração típica de GCC Pass 1 (sem headers, C-only, sem libs extras)
    "${gcc_srcdir}/configure" \
        --target="${target}" \
        --prefix="${prefix}" \
        --with-sysroot="${ADM_ROOTFS}" \
        --with-newlib \
        --without-headers \
        --enable-languages=c \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdcxx \
        --disable-bootstrap

    # Compila apenas o compilador e libgcc para o target
    make -j"${jobs}" all-gcc
    make -j"${jobs}" all-target-libgcc

    # Instala em DESTDIR (o ADM depois mescla em ${ADM_ROOTFS})
    make DESTDIR="${PKG_DESTDIR}" install-gcc
    make DESTDIR="${PKG_DESTDIR}" install-target-libgcc

    echo "[GCC-PASS1] Build concluído para target ${target}"
}

main() {
    local mode="${1:-}"

    case "${mode}" in
        metadata)
            adm_metadata
            ;;
        build)
            adm_build
            ;;
        *)
            echo "Uso: $0 {metadata|build}" >&2
            exit 1
            ;;
    esac
}

main "$@"
