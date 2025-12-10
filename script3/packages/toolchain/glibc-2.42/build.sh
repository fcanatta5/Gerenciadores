#!/usr/bin/env bash
# Glibc-2.42 para o sistema ADM
# Constrói a libc glibc dentro do rootfs glibc, usando o toolchain cross em /tools.

set -euo pipefail

adm_metadata() {
    # Nome interno do pacote conforme caminho em /opt/adm/packages
    PKG_NAME="toolchain/Glibc-2.42"
    PKG_VERSION="2.42"
    PKG_RELEASE=1
    PKG_CATEGORY="toolchain"

    # Fonte oficial (tar.xz)
    PKG_SOURCES=(
        "https://ftp.gnu.org/gnu/glibc/glibc-${PKG_VERSION}.tar.xz"
    )

    # SHA256 do tarball (mesmo do glibc_2.42.orig.tar.xz do Debian)
    PKG_SHA256=(
        "69c1e915c8edd75981cbfc6b7654e8fc4e52a48d06b9f706f463492749a9b6fb"
    )

    # MD5 não usado
    PKG_MD5=()

    # Dependências lógicas no ADM
    #  - Linux headers já instalados no rootfs
    #  - Toolchain cross básico (binutils e gcc pass1)
    PKG_DEPENDS=(
        "core/linux-headers"
        "toolchain/binutils-pass1"
        "toolchain/gcc-pass1"
    )

    # Este pacote só faz sentido no perfil glibc
    PKG_PROFILE_SUPPORT=("glibc")
}

adm_build() {
    : "${PKG_BUILD_DIR:?PKG_BUILD_DIR não definido}"
    : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"
    : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
    : "${ADM_PROFILE:?ADM_PROFILE não definido}"

    if [[ "${ADM_PROFILE}" != "glibc" ]]; then
        echo "[GLIBC-2.42] ERRO: este pacote só é suportado no perfil 'glibc' (perfil atual: ${ADM_PROFILE})." >&2
        exit 1
    fi

    local jobs="${ADM_JOBS:-1}"

    # Triplo alvo: por padrão x86_64-adm-linux-gnu (mesma lógica do binutils/gcc pass1)
    local default_target="x86_64-adm-linux-gnu"
    local target="${ADM_TARGET:-$default_target}"

    echo "[GLIBC-2.42] Perfil: ${ADM_PROFILE}"
    echo "[GLIBC-2.42] ROOTFS: ${ADM_ROOTFS}"
    echo "[GLIBC-2.42] DESTDIR: ${PKG_DESTDIR}"
    echo "[GLIBC-2.42] BUILD_DIR: ${PKG_BUILD_DIR}"
    echo "[GLIBC-2.42] Target: ${target}"
    echo "[GLIBC-2.42] Jobs: ${jobs}"

    # Checagem básica: target tem que ser glibc (terminar em '-gnu')
    if [[ "${target}" == *"-musl" ]]; then
        echo "[GLIBC-2.42] ERRO: target '${target}' parece ser musl; esta libc é glibc." >&2
        exit 1
    fi

    cd "${PKG_BUILD_DIR}"

    local srcdir="${PKG_BUILD_DIR}/glibc-${PKG_VERSION}"
    if [[ ! -d "${srcdir}" ]]; then
        echo "[GLIBC-2.42] ERRO: diretório de fontes não encontrado: ${srcdir}" >&2
        exit 1
    fi

    # Garante que lib64 existe e cria os symlinks LSB (podem ficar pendentes até a instalação)
    mkdir -p "${ADM_ROOTFS}/lib64"
    ln -sf ../lib/ld-linux-x86-64.so.2 "${ADM_ROOTFS}/lib64/ld-linux-x86-64.so.2"
    ln -sf ../lib/ld-linux-x86-64.so.2 "${ADM_ROOTFS}/lib64/ld-lsb-x86-64.so.3"

    # Diretório de build isolado
    local builddir="${PKG_BUILD_DIR}/build-glibc"
    rm -rf "${builddir}"
    mkdir -p "${builddir}"

    cd "${builddir}"

    # Garante que vamos usar o toolchain cross de ${ADM_ROOTFS}/tools
    export PATH="${ADM_ROOTFS}/tools/bin:${PATH}"

    export CC="${target}-gcc"
    export CXX="${target}-g++"
    export AR="${target}-ar"
    export RANLIB="${target}-ranlib"

    # Otimizações simples
    export CFLAGS="-O2 -pipe"
    export CXXFLAGS="-O2 -pipe"

    # Colocar ldconfig/sln em /usr/sbin
    echo "rootsbindir=/usr/sbin" > configparms

    # Se você tiver o patch FHS (glibc-2.42-fhs-1.patch) no diretório de patches
    # o próprio adm deve aplicar antes do build. Não repetimos aqui.

    # Configuração do glibc (similar à abordagem LFS, adaptada ao ADM)
    # --with-headers aponta para os Linux headers instalados no rootfs
    ../configure \
        --prefix=/usr \
        --host="${target}" \
        --build="$("${srcdir}/scripts/config.guess")" \
        --disable-nscd \
        --with-headers="${ADM_ROOTFS}/usr/include" \
        libc_cv_slibdir=/usr/lib \
        --enable-kernel=5.4

    # Build da glibc
    # ATENÇÃO: glibc às vezes tem problemas com make paralelo; se der erro,
    # rode novamente com ADM_JOBS=1.
    make -j"${jobs}"

    # Instalação em DESTDIR; o adm depois mescla em ${ADM_ROOTFS}
    make DESTDIR="${PKG_DESTDIR}" install

    # Corrige ldd dentro do DESTDIR (equivalente ao sed do LFS)
    if [[ -f "${PKG_DESTDIR}/usr/bin/ldd" ]]; then
        sed -i '/RTLDLIST=/s@/usr@@g' "${PKG_DESTDIR}/usr/bin/ldd"
    fi

    echo "[GLIBC-2.42] Instalação concluída em DESTDIR=${PKG_DESTDIR}"
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
