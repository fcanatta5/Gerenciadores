#!/usr/bin/env bash
# Linux-6.17.9 - API Headers para o sistema ADM
# Instala apenas os headers do kernel em /usr/include dentro do rootfs do perfil.

set -euo pipefail

adm_metadata() {
    # Identidade do pacote no ADM
    PKG_NAME="core/linux-headers"
    PKG_VERSION="6.17.9"
    PKG_RELEASE=1
    PKG_CATEGORY="core"

    # Fonte oficial do kernel (ajuste se quiser espelho próprio)
    PKG_SOURCES=(
        "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
    )

    # ATENÇÃO: substitua o SHA256 abaixo pelo valor REAL que você validar.
    # Exemplo de como obter:
    #   curl -O https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc
    #   grep linux-6.17.9.tar.xz sha256sums.asc
    PKG_SHA256=(
        "COLOQUE_AQUI_O_SHA256_REAL_DO_TARBALL"
    )

    # Se não for usar MD5, deixe vazio
    PKG_MD5=()

    # Dependências lógicas (no ADM)
    # Para headers, geralmente não é necessário nada além de um toolchain mínimo.
    PKG_DEPENDS=()

    # Perfis suportados
    PKG_PROFILE_SUPPORT=("glibc" "musl")
}

adm_build() {
    : "${PKG_BUILD_DIR:?PKG_BUILD_DIR não definido}"
    : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"
    : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
    : "${ADM_PROFILE:?ADM_PROFILE não definido}"

    echo "[LINUX-HEADERS] Perfil: ${ADM_PROFILE}"
    echo "[LINUX-HEADERS] ROOTFS: ${ADM_ROOTFS}"
    echo "[LINUX-HEADERS] DESTDIR: ${PKG_DESTDIR}"
    echo "[LINUX-HEADERS] BUILD_DIR: ${PKG_BUILD_DIR}"

    cd "${PKG_BUILD_DIR}"

    local srcdir="${PKG_BUILD_DIR}/linux-${PKG_VERSION}"

    if [[ ! -d "${srcdir}" ]]; then
        echo "[LINUX-HEADERS] ERRO: diretório de fonte não encontrado: ${srcdir}" >&2
        exit 1
    fi

    # Limpando árvore para garantir reprodutibilidade
    cd "${srcdir}"
    make mrproper

    # Gera headers (target 'headers' substituiu o antigo 'headers_install' + 'INSTALL_HDR_PATH')
    # Aqui usamos o caminho padrão 'usr/include' e depois copiamos pro DESTDIR.
    make headers

    # Limpa arquivos indesejados na árvore usr/include
    find usr/include -name '.*' -delete
    rm -f usr/include/Makefile

    # Copia usr/include resultante para o DESTDIR sob /usr/include
    local dest_include="${PKG_DESTDIR}/usr/include"
    mkdir -p "${dest_include}"

    # Copia mantendo estrutura
    cp -rv usr/include/* "${dest_include}/"

    echo "[LINUX-HEADERS] Headers instalados em ${dest_include}"
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
