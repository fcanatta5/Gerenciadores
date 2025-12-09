# /opt/adm/packages/toolchain/linux-headers.sh
#
# Linux-6.17.9 API Headers
# Instala os headers de API do kernel no sysroot do profile (glibc ou musl):
#   ${ADM_SYSROOT}/usr/include
#
# Integração com toolchain:
#   - depende de gcc-pass1 (que por sua vez depende de binutils-pass1)
#   - usado por Glibc/Musl na construção posterior.

PKG_NAME="linux-headers"
PKG_VERSION="6.17.9"
PKG_CATEGORY="toolchain"

# Tarball oficial em kernel.org 
PKG_SOURCE_URLS=(
  "https://www.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
  "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="linux-${PKG_VERSION}.tar.xz"

# MD5 oficial (LFS packages) 
PKG_MD5="512f1c964520792d9337f43b9177b181"

# Ordem de toolchain: depois de gcc-pass1
PKG_DEPENDS=( "gcc-pass1" )

PKG_PATCHES=()

# ---------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------

pre_build() {
    # Aqui já estamos dentro do diretório de source: linux-6.17.9/
    log_info "Linux-${PKG_VERSION} API Headers: profile=${ADM_PROFILE} SYSROOT=${ADM_SYSROOT}"

    # Nada a preparar além do padrão; se quiser aplicar patches
    # específicos de headers por arquitetura, poderia fazê-lo aqui.
}

build() {
    # Recomendação do LFS: limpar qualquer sujeira prévia 
    make mrproper

    # Gerar os headers em usr/include dentro da árvore do kernel 
    # Forçamos ARCH via ADM_ARCH (default x86_64) para ser bem determinístico.
    local arch="${ADM_ARCH:-x86_64}"

    log_info "Gerando headers do kernel para ARCH=${arch}"
    make ARCH="${arch}" headers

    # Sanitização recomendada pelo LFS: remover arquivos não .h 
    find usr/include -type f ! -name '*.h' -delete
}

install_pkg() {
    # Instalar os headers no sysroot do profile:
    #   ${ADM_SYSROOT}/usr/include
    #
    # Lembrando que o adm faz snapshot do ADM_SYSROOT antes/depois
    # para gerar manifest, então aqui precisamos realmente mexer nele.

    if [ -z "${ADM_SYSROOT:-}" ]; then
        log_error "ADM_SYSROOT não definido em install_pkg() de linux-headers."
        exit 1
    fi

    mkdir -p "${ADM_SYSROOT}/usr"

    log_info "Copiando headers para ${ADM_SYSROOT}/usr/include"
    cp -rv usr/include "${ADM_SYSROOT}/usr"

    # Sanity-check simples: verificar se alguns headers críticos existem
    local h1="${ADM_SYSROOT}/usr/include/linux/version.h"
    local h2="${ADM_SYSROOT}/usr/include/linux/limits.h"

    local failed=0

    if [ ! -f "${h1}" ]; then
        log_error "sanity-check: header ausente: ${h1}"
        failed=1
    fi

    if [ ! -f "${h2}" ]; then
        log_warn "sanity-check: header esperado não encontrado: ${h2} (pode variar por versão, verifique)."
    fi

    if [ "${failed}" -ne 0 ]; then
        log_error "sanity-check: Linux-${PKG_VERSION} API Headers falhou para profile ${ADM_PROFILE}."
        exit 1
    fi

    log_ok "Linux-${PKG_VERSION} API Headers instalados em ${ADM_SYSROOT}/usr/include para profile ${ADM_PROFILE}."
}

pre_uninstall() {
    # Nada especial, a remoção será baseada no manifest gerado pelo adm.
    log_info "pre_uninstall: removendo linux-headers (${PKG_VERSION}) do profile ${ADM_PROFILE}."
}

post_uninstall() {
    log_info "post_uninstall: linux-headers (${PKG_VERSION}) removido do profile ${ADM_PROFILE}."
}
