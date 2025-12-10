#!/usr/bin/env bash
# Binutils-2.45.1 - Pass 1 para o sistema ADM
# Constrói binutils cross em /tools dentro do rootfs do perfil (glibc/musl).

set -euo pipefail

adm_metadata() {
    # Nome interno do pacote (categoria/pacote = toolchain/binutils-pass1)
    PKG_NAME="toolchain/binutils-pass1"
    PKG_VERSION="2.45.1"
    PKG_RELEASE=1
    PKG_CATEGORY="toolchain"

    # Fontes
    PKG_SOURCES=(
        "https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.bz2"
    )

    # SHA256 dos sources (na mesma ordem do PKG_SOURCES)
    PKG_SHA256=(
        "860daddec9085cb4011279136fc8ad29eb533e9446d7524af7f517dd18f00224"
    )

    # Se não for usar MD5, deixe vazio
    PKG_MD5=()

    # Dependências lógicas (outros pacotes do ADM)
    # Aqui, para Pass 1, normalmente nenhuma dependência além das ferramentas do host.
    PKG_DEPENDS=()

    # Perfis suportados explicitamente
    PKG_PROFILE_SUPPORT=("glibc" "musl")
}

adm_build() {
    : "${PKG_BUILD_DIR:?PKG_BUILD_DIR não definido}"
    : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"
    : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
    : "${ADM_PROFILE:?ADM_PROFILE não definido}"

    local jobs="${ADM_JOBS:-1}"

    # Definir triplo de alvo padrão com base no perfil
    local libc
    case "$ADM_PROFILE" in
        musl) libc="musl" ;;
        *)    libc="gnu"  ;;
    esac

    # Permite sobrescrever o target por ADM_TARGET, senão usa padrão
    local target="${ADM_TARGET:-x86_64-adm-linux-${libc}}"

    echo "[BINUTILS-PASS1] Perfil: ${ADM_PROFILE}"
    echo "[BINUTILS-PASS1] ROOTFS: ${ADM_ROOTFS}"
    echo "[BINUTILS-PASS1] DESTDIR: ${PKG_DESTDIR}"
    echo "[BINUTILS-PASS1] BUILD_DIR: ${PKG_BUILD_DIR}"
    echo "[BINUTILS-PASS1] Target: ${target}"
    echo "[BINUTILS-PASS1] Jobs: ${jobs}"

    # Pastas de build
    cd "${PKG_BUILD_DIR}"

    # O ADM já extraiu o tarball aqui; assumimos diretório binutils-<versão>
    local srcdir="${PKG_BUILD_DIR}/binutils-${PKG_VERSION}"
    local builddir="${PKG_BUILD_DIR}/build"

    if [[ ! -d "$srcdir" ]]; then
        echo "[BINUTILS-PASS1] ERRO: diretório de fonte não encontrado: ${srcdir}" >&2
        exit 1
    fi

    rm -rf "${builddir}"
    mkdir -p "${builddir}"
    cd "${builddir}"

    # Prefixo /tools para toolchain temporário
    local prefix="/tools"

    # Configuração típica de Binutils Pass 1 (cross)
    # --with-sysroot aponta para o rootfs do perfil atual
    # --target é o cross target
    # --disable-nls / --disable-werror / --disable-gprofng para simplificar
    ../binutils-"${PKG_VERSION}"/configure \
        --prefix="${prefix}" \
        --with-sysroot="${ADM_ROOTFS}" \
        --target="${target}" \
        --disable-nls \
        --disable-werror \
        --disable-multilib \
        --disable-gprofng

    # Compilação
    make -j"${jobs}"

    # Instalação em DESTDIR (que o ADM depois mescla em ${ADM_ROOTFS})
    # Resultado final: ${ADM_ROOTFS}/tools/...
    make DESTDIR="${PKG_DESTDIR}" install

    echo "[BINUTILS-PASS1] Build concluído para target ${target}"
}

main() {
    local mode="${1:-}"

    case "$mode" in
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
