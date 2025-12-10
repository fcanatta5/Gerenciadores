# /opt/adm/packages/base/texinfo-7.2.sh
#
# Texinfo-7.2 - sistema de documentação (info, makeinfo, install-info)
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - constrói em /usr do rootfs do profile (glibc ou musl)
#   - fluxo estilo LFS adaptado para cross/profile:
#       ./configure --prefix=/usr --host=$ADM_TARGET --build=$(config.guess) \
#                   --disable-static \
#                   --docdir=/usr/share/doc/texinfo-7.2
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs (info, install-info, makeinfo)

PKG_NAME="texinfo"
PKG_VERSION="7.2"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/texinfo/texinfo-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/texinfo/texinfo-${PKG_VERSION}.tar.xz"
  "https://ftp.unicamp.br/pub/gnu/texinfo/texinfo-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="texinfo-${PKG_VERSION}.tar.xz"

# Preencha depois com o SHA256 oficial, se quiser travar checksum.
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas (ajuste nomes para bater com os scripts já criados)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
  "sed-4.9"
  "grep-3.12"
  "gawk-5.3.2"
  "make-4.4.1"
  "perl-5.42.0"
)

# Sem patches por padrão
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
}

build() {
    # Construção padrão Texinfo em modo "final do sistema":
    #
    #   ./configure --prefix=/usr \
    #               --host=$ADM_TARGET \
    #               --build=$(build-aux/config.guess) \
    #               --disable-static \
    #               --docdir=/usr/share/doc/texinfo-7.2
    #   make
    #
    # Em chroot, build == host == target; fora do chroot, o Configure ainda
    # consegue detectar um build-triplet coerente.

    local build_triplet

    if [ -x "./build-aux/config.guess" ]; then
        build_triplet="$(./build-aux/config.guess)"
    elif [ -x "./config.guess" ]; then
        build_triplet="$(./config.guess)"
    else
        build_triplet="$(uname -m)-unknown-linux-gnu"
    fi

    ./configure \
        --prefix=/usr \
        --host="${ADM_TARGET}" \
        --build="${build_triplet}" \
        --disable-static \
        --docdir="/usr/share/doc/texinfo-${PKG_VERSION}"

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm fará o rsync para ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Opcional: instalar documentação HTML se disponível
    # (nem todas as builds exigem, então tratamos como "best effort").
    if grep -q "^install-html:" Makefile 2>/dev/null; then
        make DESTDIR="${DESTDIR}" install-html || true
    fi
}

post_install() {
    # Sanity-check Texinfo dentro do rootfs do profile:
    #
    # 1) localizar info, install-info, makeinfo em ${ADM_SYSROOT}/usr/bin
    # 2) info --version, install-info --version, makeinfo --version funcionam
    # 3) makeinfo gera um .info simples a partir de um .texi

    local info_bin=""
    local instinfo_bin=""
    local makeinfo_bin=""

    # info
    if [ -x "${ADM_SYSROOT}/usr/bin/info" ]; then
        info_bin="${ADM_SYSROOT}/usr/bin/info"
    elif [ -x "${ADM_SYSROOT}/bin/info" ]; then
        info_bin="${ADM_SYSROOT}/bin/info"
    else
        log_error "Sanity-check Texinfo falhou: 'info' não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    # install-info
    if [ -x "${ADM_SYSROOT}/usr/bin/install-info" ]; then
        instinfo_bin="${ADM_SYSROOT}/usr/bin/install-info"
    elif [ -x "${ADM_SYSROOT}/bin/install-info" ]; then
        instinfo_bin="${ADM_SYSROOT}/bin/install-info"
    else
        log_error "Sanity-check Texinfo falhou: 'install-info' não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    # makeinfo
    if [ -x "${ADM_SYSROOT}/usr/bin/makeinfo" ]; then
        makeinfo_bin="${ADM_SYSROOT}/usr/bin/makeinfo"
    elif [ -x "${ADM_SYSROOT}/bin/makeinfo" ]; then
        makeinfo_bin="${ADM_SYSROOT}/bin/makeinfo"
    else
        log_error "Sanity-check Texinfo falhou: 'makeinfo' não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    # Versões
    local iv mv tv

    iv="$("${info_bin}" --version 2>/dev/null | head -n1 || true)"
    mv="$("${instinfo_bin}" --version 2>/dev/null | head -n1 || true)"
    tv="$("${makeinfo_bin}" --version 2>/dev/null | head -n1 || true)"

    if [ -z "${iv}" ]; then
        log_error "Sanity-check Texinfo falhou: não foi possível obter versão de ${info_bin}."
        exit 1
    fi
    if [ -z "${mv}" ]; then
        log_error "Sanity-check Texinfo falhou: não foi possível obter versão de ${instinfo_bin}."
        exit 1
    fi
    if [ -z "${tv}" ]; then
        log_error "Sanity-check Texinfo falhou: não foi possível obter versão de ${makeinfo_bin}."
        exit 1
    fi

    log_info "Texinfo: info --version         → ${iv}"
    log_info "Texinfo: install-info --version → ${mv}"
    log_info "Texinfo: makeinfo --version     → ${tv}"

    # Teste de makeinfo: gerar um .info simples
    local tmpdir
    tmpdir="$(mktemp -d)"

    cat > "${tmpdir}/test.texi" << 'EOF'
\input texinfo
@setfilename test.info
@settitle Teste Texinfo

@node Top
@top Teste Texinfo

@menu
* Cap1::  Primeiro capítulo.
@end menu

@node Cap1
@chapter Primeiro capítulo

Este é um teste simples de Texinfo.

@bye
EOF

    if ! "${makeinfo_bin}" "${tmpdir}/test.texi" -o "${tmpdir}/test.info" >/dev/null 2>&1; then
        log_error "Sanity-check Texinfo falhou: makeinfo não conseguiu gerar test.info."
        rm -rf "${tmpdir}"
        exit 1
    fi

    if [ ! -f "${tmpdir}/test.info" ]; then
        log_error "Sanity-check Texinfo falhou: arquivo test.info não foi gerado."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check Texinfo-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
