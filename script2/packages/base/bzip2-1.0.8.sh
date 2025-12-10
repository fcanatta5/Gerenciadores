# /opt/adm/packages/base/bzip2-1.0.8.sh
#
# Bzip2-1.0.8 - utilitários e biblioteca de compressão bzip2
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - constrói e instala em /usr do rootfs do profile (glibc/musl)
#   - fluxo baseado em LFS, adaptado para DESTDIR:
#       make -f Makefile-libbz2_so
#       make clean
#       make
#       make PREFIX=/usr DESTDIR=${DESTDIR} install
#       instalar libbz2.so* em /usr/lib e criar symlinks
#   - adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
#   - hooks de sanity-check no rootfs (bzip2 funcional e libbz2.so linkando)

PKG_NAME="bzip2"
PKG_VERSION="1.0.8"
PKG_CATEGORY="base"

# Fontes oficiais
PKG_SOURCE_URLS=(
  "https://sourceware.org/pub/bzip2/bzip2-${PKG_VERSION}.tar.gz"
  "https://fossies.org/linux/misc/bzip2-${PKG_VERSION}.tar.gz"
)

PKG_TARBALL="bzip2-${PKG_VERSION}.tar.gz"

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

# Se você tiver patches locais (por exemplo para hardening):
# PKG_PATCHES=("/opt/adm/patches/bzip2-1.0.8-hardening.patch")

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
        log_warn "Bzip2-1.0.8 idealmente deve ser construída dentro do chroot; profile=${ADM_PROFILE}, SYSROOT=${ADM_SYSROOT}."
    fi
}

build() {
    # O bzip2 não usa autotools. O procedimento clássico é:
    #
    #   make -f Makefile-libbz2_so
    #   make clean
    #   make
    #
    # Isso gera a lib compartilhada e os binários.

    make -f Makefile-libbz2_so
    make clean
    make
}

install_pkg() {
    # Instala em DESTDIR; o adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}.
    #
    # O upstream usa:
    #   make PREFIX=/usr install
    #
    # Adaptamos para DESTDIR.
    make PREFIX=/usr DESTDIR="${DESTDIR}" install

    # Instalar lib compartilhada em /usr/lib com os symlinks corretos
    install -v -m755 libbz2.so.1.0.8 "${DESTDIR}/usr/lib/libbz2.so.1.0.8"
    ln -svf libbz2.so.1.0.8 "${DESTDIR}/usr/lib/libbz2.so.1.0"
    ln -svf libbz2.so.1.0.8 "${DESTDIR}/usr/lib/libbz2.so"

    # Instalar headers se ainda não estiverem em /usr/include
    install -v -m644 bzlib.h "${DESTDIR}/usr/include/bzlib.h"

    # Opcional: instalar docs
    install -v -d -m755 "${DESTDIR}/usr/share/doc/bzip2-${PKG_VERSION}"
    cp -v README* CHANGES LICENSE* \
       "${DESTDIR}/usr/share/doc/bzip2-${PKG_VERSION}" 2>/dev/null || true

    # Garantir que os symlinks dos binários clássicos existam:
    # bunzip2 -> bzip2, bzcat -> bzip2
    local dest_usr_bin="${DESTDIR}/usr/bin"
    if [ -x "${dest_usr_bin}/bzip2" ]; then
        ln -svf bzip2 "${dest_usr_bin}/bunzip2"
        ln -svf bzip2 "${dest_usr_bin}/bzcat"
    fi
}

post_install() {
    # Sanity-check bzip2 dentro do rootfs do profile:
    #
    # 1) verificar /usr/bin/bzip2 (ou /bin/bzip2)
    # 2) bzip2 --version
    # 3) comprimir e descomprimir um arquivo pequeno
    # 4) verificar libbz2.so* em /usr/lib
    #

    local bzip2_bin=""

    if [ -x "${ADM_SYSROOT}/usr/bin/bzip2" ]; then
        bzip2_bin="${ADM_SYSROOT}/usr/bin/bzip2"
    elif [ -x "${ADM_SYSROOT}/bin/bzip2" ]; then
        bzip2_bin="${ADM_SYSROOT}/bin/bzip2"
    else
        log_error "Sanity-check bzip2 falhou: bzip2 não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    local ver
    ver="$("${bzip2_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check bzip2 falhou: não foi possível obter versão de ${bzip2_bin}."
        exit 1
    fi
    log_info "bzip2: bzip2 --version → ${ver}"

    # Teste de compressão/descompressão
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "teste-bzip2" > "${tmpdir}/in.txt"

    if ! "${bzip2_bin}" -k "${tmpdir}/in.txt" >/dev/null 2>&1; then
        log_error "Sanity-check bzip2 falhou: não conseguiu comprimir in.txt."
        rm -rf "${tmpdir}"
        exit 1
    fi

    if [ ! -f "${tmpdir}/in.txt.bz2" ]; then
        log_error "Sanity-check bzip2 falhou: arquivo in.txt.bz2 não foi gerado."
        rm -rf "${tmpdir}"
        exit 1
    fi

    if ! "${bzip2_bin}" -dk "${tmpdir}/in.txt.bz2" >/dev/null 2>&1; then
        log_error "Sanity-check bzip2 falhou: não conseguiu descomprimir in.txt.bz2."
        rm -rf "${tmpdir}"
        exit 1
    fi

    local original decompressed
    original="$(cat "${tmpdir}/in.txt")"
    decompressed="$(cat "${tmpdir}/in.txt.out" 2>/dev/null || cat "${tmpdir}/in.txt")"

    if [ "${original}" != "${decompressed}" ]; then
        log_error "Sanity-check bzip2 falhou: conteúdo descomprimido difere do original."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"
    log_info "bzip2: compressão/descompressão de teste OK."

    # Verificar libbz2.so em /usr/lib
    local libdir="${ADM_SYSROOT}/usr/lib"
    local have_lib=0
    if [ -d "${libdir}" ]; then
        if find "${libdir}" -maxdepth 1 -name 'libbz2.so*' | head -n1 >/dev/null 2>&1; then
            have_lib=1
        fi
    fi

    if [ "${have_lib}" -ne 1 ]; then
        log_error "Sanity-check bzip2 falhou: libbz2.so* não encontrada em ${libdir}."
        exit 1
    fi

    log_ok "Sanity-check bzip2-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
