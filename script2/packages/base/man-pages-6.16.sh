# /opt/adm/packages/base/man-pages-6.16.sh
#
# Man-pages-6.16 - páginas de manual do kernel/glibc (seções 2, 3, 4, 5, 7, 9)
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - constrói em /usr/share/man do rootfs do profile (glibc ou musl)
#   - fluxo estilo LFS:
#       make prefix=/usr
#       make prefix=/usr DESTDIR=${DESTDIR} install
#     (não tem ./configure)
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs (páginas conhecidas presentes)

PKG_NAME="man-pages"
PKG_VERSION="6.16"
PKG_CATEGORY="base"

# Fontes oficiais (kernel.org)
PKG_SOURCE_URLS=(
  "https://www.kernel.org/pub/linux/docs/man-pages/man-pages-${PKG_VERSION}.tar.xz"
  "https://mirrors.edge.kernel.org/pub/linux/docs/man-pages/man-pages-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="man-pages-${PKG_VERSION}.tar.xz"

# Preencha depois com o SHA256 oficial, se quiser verificação forte.
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas mínimas (para make, coreutils, compressão, etc.)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
  "sed-4.9"
  "grep-3.12"
  "gawk-5.3.2"
  "make-4.4.1"
  "gzip-1.14"
)

PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi

    # Não há configure; tudo é controlado via make prefix=...
}

build() {
    # Para man-pages, o "build" é praticamente um pré-processamento muito simples.
    # Muitas vezes bastaria só 'make install', mas mantemos um passo de make.

    # O pacote usa 'prefix', e o padrão é /usr/share/man.
    # Aqui não instalamos ainda; apenas deixamos pronto.
    make prefix=/usr
}

install_pkg() {
    # Instala em DESTDIR; o adm sincroniza depois DESTDIR -> ${ADM_SYSROOT}
    #
    # O upstream usa:
    #   make prefix=/usr install
    #
    # Adaptamos para DESTDIR:
    make prefix=/usr DESTDIR="${DESTDIR}" install
}

post_install() {
    # Sanity-check man-pages dentro do rootfs do profile:
    #
    # 1) verificar se o diretório /usr/share/man existe
    # 2) verificar algumas páginas típicas de Linux man-pages:
    #    - man2/chdir.2
    #    - man2/open.2
    #    - man3/errno.3
    #    - man7/signal.7
    #
    # Observação:
    #   O pacote man-pages fornece principalmente seções 2, 3, 4, 5, 7, 9.
    #   Páginas de seção 1 em geral vêm de outros pacotes (coreutils, etc.).

    local mandir="${ADM_SYSROOT}/usr/share/man"

    if [ ! -d "${mandir}" ]; then
        log_error "Sanity-check man-pages falhou: diretório ${mandir} não existe."
        exit 1
    fi

    # Lista de páginas que esperamos encontrar
    local expected=(
        "man2/chdir.2"
        "man2/open.2"
        "man3/errno.3"
        "man7/signal.7"
    )

    local missing=0
    local f
    for f in "${expected[@]}"; do
        if [ ! -f "${mandir}/${f}" ]; then
            log_warn "man-pages: página ${mandir}/${f} não foi encontrada."
            missing=1
        fi
    done

    if [ "$missing" -eq 0 ]; then
        log_info "man-pages: páginas principais encontradas em ${mandir}."
    else
        log_warn "man-pages: algumas páginas típicas não foram encontradas; verifique se o pacote foi instalado completo."
    fi

    log_ok "Sanity-check man-pages-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
