# /opt/adm/packages/toolchain/linux-headers.sh
#
# Linux-6.17.9 API Headers para o adm
# Expondo a API do kernel para uso da Glibc
#

PKG_NAME="linux-headers"
PKG_VERSION="6.17.9"
PKG_CATEGORY="toolchain"

# Fonte principal do kernel (múltiplos mirrors)
PKG_SOURCE_URLS=(
  "https://www.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
  "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
)

# Nome do tarball no cache do adm
PKG_TARBALL="linux-${PKG_VERSION}.tar.xz"

# MD5 oficial (LFS 12.2, pacote Linux-6.17.9) 
PKG_MD5="512f1c964520792d9337f43b9177b181"

# Dependências lógicas (ajuste se quiser forçar ordem)
PKG_DEPENDS=(
  # "gcc-pass1"
  # "binutils-pass1"
)

# --------------------------------------------------------------------
# Linux API Headers:
# - usa 'make mrproper' + 'make headers' + limpeza de não-*.h
# - instala cabeçalhos sanitizados em ${ADM_SYSROOT}/usr/include
# - não compila o kernel, só instala API para Glibc
# --------------------------------------------------------------------

build() {
    # Passos baseados no LFS 12.2 (adaptados para $SYSROOT/$DESTDIR) 

    # Garantir árvore limpa
    make mrproper

    # Extrair headers públicos para ./usr/include
    make headers

    # Remover arquivos que não são headers .h
    find usr/include -type f ! -name '*.h' -delete
}

install_pkg() {
    # Aqui estamos no diretório raiz do source (linux-6.17.9/)
    # Queremos que o resultado final seja ${ADM_SYSROOT}/usr/include/...
    #
    # O adm vai:
    #   - instalar em $DESTDIR/usr/include
    #   - depois fazer rsync para ${ADM_SYSROOT}/usr/include
    #
    mkdir -pv "${DESTDIR}/usr"

    # Copiar include sanitizado
    cp -rv usr/include "${DESTDIR}/usr"
}

post_install() {
    # Sanity-check: garantir que os headers estão em ${ADM_SYSROOT}/usr/include

    local include_dir="${ADM_SYSROOT}/usr/include"
    local version_h="${include_dir}/linux/version.h"

    if [ ! -d "${include_dir}" ]; then
        log_error "Sanity-check Linux API Headers falhou: diretório ${include_dir} não existe."
        exit 1
    fi

    if [ ! -f "${version_h}" ]; then
        log_error "Sanity-check Linux API Headers falhou: ${version_h} não encontrado."
        exit 1
    fi

    # Tentar extrair a versão a partir de linux/version.h
    local ver_line
    ver_line="$(grep -m1 'LINUX_VERSION_CODE' "${version_h}" || true)"

    log_info "Linux API Headers instalados em ${include_dir}"
    if [ -n "${ver_line}" ]; then
        log_info "Entrada em linux/version.h: ${ver_line}"
    fi

    log_ok "Sanity-check Linux-API Headers OK para profile=${ADM_PROFILE}, SYSROOT=${ADM_SYSROOT}."
}
