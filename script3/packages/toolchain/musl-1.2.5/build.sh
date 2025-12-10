#!/usr/bin/env bash
# musl-1.2.5 para o sistema ADM (perfil musl)
# Constrói e instala a libc musl no rootfs-musl, usando toolchain cross existente.

set -euo pipefail

adm_metadata() {
    # Nome interno (deve bater com diretório em /opt/adm/packages)
    PKG_NAME="toolchain/musl-1.2.5"
    PKG_VERSION="1.2.5"
    PKG_RELEASE=1
    PKG_CATEGORY="toolchain"

    # Fonte oficial do musl
    PKG_SOURCES=(
        "https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"
    )

    # SHA256 do tarball musl-1.2.5.tar.gz
    PKG_SHA256=(
        "a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"
    )

    # MD5 não utilizado
    PKG_MD5=()

    # Dependências lógicas no ADM:
    #  - Linux headers instalados no rootfs-musl
    #  - GCC final e binutils para target musl
    PKG_DEPENDS=(
        "core/linux-headers"
        "toolchain/gcc-final"
        "toolchain/binutils-pass2"
    )

    # Este pacote só é válido para o perfil musl
    PKG_PROFILE_SUPPORT=("musl")

    # Notas de segurança:
    #  - musl 1.2.5 é afetado por CVE-2025-26519 (iconv EUC-KR -> UTF-8).
    #  - Patches oficiais: commits c47ad25e... e e5adcd97... na árvore do musl.
    #  - Distros como Alpine já disponibilizam um backport combinado:
    #    CVE-2025-26519.patch.
    #
    # NO ADM:
    #  - coloque patches de segurança (ex: CVE-2025-26519.patch) no mesmo
    #    diretório deste build.sh:
    #       /opt/adm/packages/toolchain/musl-1.2.5/*.patch
    #  - o próprio sistema adm já aplica automaticamente todos os *.patch
    #    antes do build.
}

adm_build() {
    : "${PKG_BUILD_DIR:?PKG_BUILD_DIR não definido}"
    : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"
    : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
    : "${ADM_PROFILE:?ADM_PROFILE não definido}"

    if [[ "${ADM_PROFILE}" != "musl" ]]; then
        echo "[MUSL-1.2.5] ERRO: este pacote só é suportado no perfil 'musl' (perfil atual: ${ADM_PROFILE})." >&2
        exit 1
    fi

    local jobs="${ADM_JOBS:-1}"

    # Target padrão: x86_64-adm-linux-musl (pode sobrescrever com ADM_TARGET)
    local default_target="x86_64-adm-linux-musl"
    local target="${ADM_TARGET:-$default_target}"

    echo "[MUSL-1.2.5] Perfil: ${ADM_PROFILE}"
    echo "[MUSL-1.2.5] ROOTFS: ${ADM_ROOTFS}"
    echo "[MUSL-1.2.5] DESTDIR: ${PKG_DESTDIR}"
    echo "[MUSL-1.2.5] BUILD_DIR: ${PKG_BUILD_DIR}"
    echo "[MUSL-1.2.5] Target: ${target}"
    echo "[MUSL-1.2.5] Jobs: ${jobs}"

    # Target precisa terminar em -musl
    if [[ "${target}" != *"-musl" ]]; then
        echo "[MUSL-1.2.5] ERRO: target '${target}' não parece ser um triplo musl (deveria terminar com '-musl')." >&2
        exit 1
    fi

    cd "${PKG_BUILD_DIR}"

    local srcdir="${PKG_BUILD_DIR}/musl-${PKG_VERSION}"
    if [[ ! -d "${srcdir}" ]]; then
        echo "[MUSL-1.2.5] ERRO: diretório de fontes não encontrado: ${srcdir}" >&2
        exit 1
    fi

    # Diretório de build isolado
    local builddir="${PKG_BUILD_DIR}/build-musl"
    rm -rf "${builddir}"
    mkdir -p "${builddir}"
    cd "${builddir}"

    # Garante que usamos o toolchain do rootfs-musl
    export PATH="${ADM_ROOTFS}/tools/bin:${ADM_ROOTFS}/usr/bin:${PATH}"

    export CC="${target}-gcc"
    export CXX="${target}-g++"
    export AR="${target}-ar"
    export RANLIB="${target}-ranlib"

    export CFLAGS="-O2 -pipe"
    export CXXFLAGS="-O2 -pipe"

    # Configuração recomendada para cross:
    #  - CROSS_COMPILE: prefixo dos binários (gcc, ar, etc)
    #  - --target: triplo musl
    #  - --build: máquina de build (detectada)
    #  - --prefix=/usr: instalação lógica em /usr
    #  - --syslibdir=/lib: libc/dynamic loader em /lib (ld-musl-*.so.1)
    #  - --includedir=/usr/include: headers no lugar “normal”
    #  - --disable-gcc-wrapper: não instalar musl-gcc wrapper
    CROSS_COMPILE="${target}-" \
    "${srcdir}/configure" \
        --prefix=/usr \
        --target="${target}" \
        --build="$("${srcdir}/config.guess")" \
        --syslibdir=/lib \
        --includedir=/usr/include \
        --disable-gcc-wrapper

    # Build da libc musl
    make -j"${jobs}"

    # Instalar em DESTDIR; o ADM depois mescla DESTDIR -> ${ADM_ROOTFS}
    make DESTDIR="${PKG_DESTDIR}" install

    echo "[MUSL-1.2.5] Instalação concluída em DESTDIR=${PKG_DESTDIR}"
    echo "[MUSL-1.2.5] Lembre-se: patches de segurança (*.patch) já devem ter sido aplicados pelo adm antes deste build."
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
