# /opt/adm/packages/base/lz4-1.10.0.sh
#
# Lz4-1.10.0 - utilitários e biblioteca de compressão LZ4
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - constrói e instala em /usr do rootfs do profile (glibc/musl)
#   - fluxo típico:
#       make
#       make install PREFIX=/usr DESTDIR=${DESTDIR}
#   - adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
#   - hooks de sanity-check no rootfs (binário lz4 funcional + liblz4.so)

PKG_NAME="lz4"
PKG_VERSION="1.10.0"
PKG_CATEGORY="base"

# Fontes oficiais (GitHub releases)
PKG_SOURCE_URLS=(
  "https://github.com/lz4/lz4/releases/download/v${PKG_VERSION}/lz4-${PKG_VERSION}.tar.gz"
  "https://github.com/lz4/lz4/archive/refs/tags/v${PKG_VERSION}.tar.gz"
)

PKG_TARBALL="lz4-${PKG_VERSION}.tar.gz"

# Preencha depois com o SHA256 oficial se quiser verificação rígida
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas mínimas
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
  "sed-4.9"
  "grep-3.12"
  "gawk-5.3.2"
  "make-4.4.1"
  "gcc-15.2.0"
)

PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# Se tiver patches locais:
# PKG_PATCHES=("/opt/adm/patches/lz4-1.10.0-fix-xyz.patch")

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    export LC_ALL=C

    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi

    if [ "${ADM_IN_CHROOT:-0}" != "1" ]; then
        log_warn "Lz4-${PKG_VERSION} idealmente deve ser construída dentro do chroot; profile=${ADM_PROFILE}, SYSROOT=${ADM_SYSROOT}."
    fi
}

build() {
    # LZ4 usa um Makefile simples:
    #
    #   make
    #
    # Isso constrói binários e bibliotecas (liblz4.so, liblz4.a).
    # O suporte a DESTDIR/PREFIX é feito no 'make install'.

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
    make PREFIX=/usr DESTDIR="${DESTDIR}" install

    # Garantir permissões razoáveis nas libs compartilhadas
    if [ -d "${DESTDIR}/usr/lib" ]; then
        find "${DESTDIR}/usr/lib" -maxdepth 1 -type f -name 'liblz4.so*' -exec chmod 0755 {} \; || true
    fi

    # Instalar docs básicos, se existirem
    if [ -d "doc" ]; then
        install -v -d -m755 "${DESTDIR}/usr/share/doc/lz4-${PKG_VERSION}"
        cp -v doc/* "${DESTDIR}/usr/share/doc/lz4-${PKG_VERSION}" 2>/dev/null || true
    fi
}

post_install() {
    # Sanity-check LZ4 dentro do rootfs do profile:
    #
    # 1) localizar /usr/bin/lz4 (ou /bin/lz4)
    # 2) lz4 --version
    # 3) comprimir e descomprimir um arquivo pequeno
    # 4) verificar liblz4.so* em /usr/lib

    local lz4_bin=""

    if [ -x "${ADM_SYSROOT}/usr/bin/lz4" ]; then
        lz4_bin="${ADM_SYSROOT}/usr/bin/lz4"
    elif [ -x "${ADM_SYSROOT}/bin/lz4" ]; then
        lz4_bin="${ADM_SYSROOT}/bin/lz4"
    else
        log_error "Sanity-check lz4 falhou: lz4 não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    local ver
    ver="$("${lz4_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check lz4 falhou: não foi possível obter versão de ${lz4_bin}."
        exit 1
    fi
    log_info "lz4: lz4 --version → ${ver}"

    # Teste de compressão/descompressão
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "teste-lz4" > "${tmpdir}/in.txt"

    if ! "${lz4_bin}" -q "${tmpdir}/in.txt" "${tmpdir}/in.txt.lz4" >/dev/null 2>&1; then
        log_error "Sanity-check lz4 falhou: não conseguiu comprimir in.txt."
        rm -rf "${tmpdir}"
        exit 1
    fi

    if [ ! -f "${tmpdir}/in.txt.lz4" ]; then
        log_error "Sanity-check lz4 falhou: arquivo in.txt.lz4 não foi gerado."
        rm -rf "${tmpdir}"
        exit 1
    fi

    if ! "${lz4_bin}" -dq "${tmpdir}/in.txt.lz4" "${tmpdir}/out.txt" >/dev/null 2>&1; then
        log_error "Sanity-check lz4 falhou: não conseguiu descomprimir in.txt.lz4."
        rm -rf "${tmpdir}"
        exit 1
    fi

    local original decompressed
    original="$(cat "${tmpdir}/in.txt")"
    decompressed="$(cat "${tmpdir}/out.txt" 2>/dev/null || true)"

    if [ "${original}" != "${decompressed}" ]; then
        log_error "Sanity-check lz4 falhou: conteúdo descomprimido difere do original."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"
    log_info "lz4: compressão/descompressão de teste OK."

    # Verificar liblz4.so em /usr/lib
    local libdir="${ADM_SYSROOT}/usr/lib"
    local have_lib=0
    if [ -d "${libdir}" ]; then
        if find "${libdir}" -maxdepth 1 -name 'liblz4.so*' | head -n1 >/dev/null 2>&1; then
            have_lib=1
        fi
    fi

    if [ "${have_lib}" -ne 1 ]; then
        log_error "Sanity-check lz4 falhou: liblz4.so* não encontrada em ${libdir}."
        exit 1
    fi

    log_ok "Sanity-check lz4-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
