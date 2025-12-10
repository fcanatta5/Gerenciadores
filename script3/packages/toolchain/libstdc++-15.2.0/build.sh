#!/usr/bin/env bash
# Libstdc++ from GCC-15.2.0 para o sistema ADM
# Constrói apenas a libstdc++-v3 a partir da árvore do GCC-15.2.0.

set -euo pipefail

adm_metadata() {
    # Nome interno deve bater com o caminho em /opt/adm/packages
    PKG_NAME="toolchain/libstdc++-15.2.0"
    PKG_VERSION="15.2.0"
    PKG_RELEASE=1
    PKG_CATEGORY="toolchain"

    # Usamos somente o tarball do GCC; libstdc++ está dentro de libstdc++-v3/
    PKG_SOURCES=(
        "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
    )

    # SHA256 do gcc-15.2.0.tar.xz (de distinfo do FreeBSD ports)
    PKG_SHA256=(
        "438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e"
    )

    PKG_MD5=()

    # Dependências lógicas dentro do ADM:
    #  - glibc/musl e headers já instalados no rootfs
    #  - GCC final com suporte a C++ para o target (por ex. toolchain/gcc-final)
    PKG_DEPENDS=(
        "core/linux-headers"
        "toolchain/Glibc-2.42"
        "toolchain/gcc-final"
    )

    # libstdc++ pode ser construída tanto para glibc quanto para musl,
    # desde que o toolchain do perfil exista.
    PKG_PROFILE_SUPPORT=("glibc" "musl")
}

adm_build() {
    : "${PKG_BUILD_DIR:?PKG_BUILD_DIR não definido}"
    : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"
    : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
    : "${ADM_PROFILE:?ADM_PROFILE não definido}"

    local jobs="${ADM_JOBS:-1}"

    # Libc no triplo (gnu para glibc, musl para musl)
    local libc
    case "${ADM_PROFILE}" in
        musl) libc="musl" ;;
        *)    libc="gnu"  ;;
    esac

    # Target padrão (pode sobrescrever com ADM_TARGET)
    local default_target="x86_64-adm-linux-${libc}"
    local target="${ADM_TARGET:-$default_target}"

    echo "[LIBSTDC++-15.2.0] Perfil: ${ADM_PROFILE}"
    echo "[LIBSTDC++-15.2.0] ROOTFS: ${ADM_ROOTFS}"
    echo "[LIBSTDC++-15.2.0] DESTDIR: ${PKG_DESTDIR}"
    echo "[LIBSTDC++-15.2.0] BUILD_DIR: ${PKG_BUILD_DIR}"
    echo "[LIBSTDC++-15.2.0] Target: ${target}"
    echo "[LIBSTDC++-15.2.0] Jobs: ${jobs}"

    cd "${PKG_BUILD_DIR}"

    local srcdir="${PKG_BUILD_DIR}/gcc-${PKG_VERSION}"
    if [[ ! -d "${srcdir}" ]]; then
        echo "[LIBSTDC++-15.2.0] ERRO: diretório de fontes não encontrado: ${srcdir}" >&2
        exit 1
    fi

    # Diretório de build isolado apenas para libstdc++
    local builddir="${PKG_BUILD_DIR}/build-libstdc++"
    rm -rf "${builddir}"
    mkdir -p "${builddir}"
    cd "${builddir}"

    # Garante que enxergamos o toolchain no rootfs (tanto /tools quanto /usr)
    export PATH="${ADM_ROOTFS}/tools/bin:${ADM_ROOTFS}/usr/bin:${PATH}"

    # Usa o compilador do target (já instalado pelo seu pacote GCC final)
    export CC="${target}-gcc"
    export CXX="${target}-g++"
    export AR="${target}-ar"
    export RANLIB="${target}-ranlib"

    export CFLAGS="-O2 -pipe"
    export CXXFLAGS="-O2 -pipe"

    # Configuração típica de libstdc++ fora do build principal do GCC
    # --host        = triplo do target
    # --build       = máquina de build (detectada pelo config.guess do GCC)
    # --prefix=/usr = instalação final em /usr (ADM depois mescla DESTDIR -> ROOTFS)
    "${srcdir}/libstdc++-v3/configure" \
        --host="${target}" \
        --build="$("${srcdir}/config.guess")" \
        --prefix=/usr \
        --disable-multilib \
        --disable-nls \
        --disable-libstdcxx-pch

    # Compila e instala somente a libstdc++
    make -j"${jobs}"
    make DESTDIR="${PKG_DESTDIR}" install

    echo "[LIBSTDC++-15.2.0] Instalação de libstdc++ concluída em DESTDIR=${PKG_DESTDIR}"
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
