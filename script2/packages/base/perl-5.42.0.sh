# /opt/adm/packages/base/perl-5.42.0.sh
#
# Perl-5.42.0 - interpretador Perl final do sistema
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - constrói em /usr do rootfs do profile (glibc ou musl)
#   - fluxo baseado em LFS, adaptado ao esquema do adm:
#       sh Configure -des -Dprefix=/usr ...
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs (perl -v, perl -e, libs básicas)

PKG_NAME="perl"
PKG_VERSION="5.42.0"
PKG_CATEGORY="base"

# Fontes oficiais (CPAN + mirrors)
PKG_SOURCE_URLS=(
  "https://www.cpan.org/src/5.0/perl-${PKG_VERSION}.tar.xz"
  "https://www.mirrorservice.org/sites/cpan.perl.org/CPAN/src/5.0/perl-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="perl-${PKG_VERSION}.tar.xz"

# Preencha com o SHA256 oficial quando quiser travar; enquanto vazio, o adm só avisa.
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas (ajuste os nomes conforme os scripts que você já tem)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
  "sed-4.9"
  "grep-3.12"
  "gawk-5.3.2"
  "make-4.4.1"
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

    # Perl pode usar zlib/bzip2 internos; preferimos as libs do sistema:
    export BUILD_ZLIB=0
    export BUILD_BZIP2=0

    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Para Perl, o build é em-tree (no próprio diretório de source).
    # Usamos Configure com parâmetros razoáveis para sistema final:
    #
    #  - prefix=/usr
    #  - vendorprefix=/usr
    #  - usethreads, uselargefiles, useshrplib
    #  - diretórios de libs versionados: /usr/lib/perl5/5.42/{core,site,vendor}_perl
    #
    # Assumimos que estamos rodando num ambiente compatível (idealmente chroot)
    # onde host == target; não passamos --host/--build, o Configure detecta sozinho.

    # PKG_VERSION=5.42.0 -> 5.42
    local short_ver="${PKG_VERSION%.*}"

    sh Configure -des \
        -Dprefix=/usr \
        -Dvendorprefix=/usr \
        -Dprivlib="/usr/lib/perl5/${short_ver}/core_perl" \
        -Darchlib="/usr/lib/perl5/${short_ver}/core_perl" \
        -Dsitelib="/usr/lib/perl5/${short_ver}/site_perl" \
        -Dsitearch="/usr/lib/perl5/${short_ver}/site_perl" \
        -Dvendorlib="/usr/lib/perl5/${short_ver}/vendor_perl" \
        -Dvendorarch="/usr/lib/perl5/${short_ver}/vendor_perl" \
        -Dman1dir=/usr/share/man/man1 \
        -Dman3dir=/usr/share/man/man3 \
        -Dusethreads \
        -Duselargefiles \
        -Duseshrplib

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm faz o sync DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Opcional: remover arquivos .packlist, pod desnecessário etc.
    # Mantemos a instalação padrão aqui; você pode limpar depois se quiser.
}

post_install() {
    # Sanity-check Perl dentro do rootfs do profile:
    #
    # 1) localizar /usr/bin/perl (ou /bin/perl)
    # 2) perl -v funciona
    # 3) perl -e 'print "ok-perl\n"' funciona
    # 4) diretórios básicos de libs existem

    local perl_bin=""

    if [ -x "${ADM_SYSROOT}/usr/bin/perl" ]; then
        perl_bin="${ADM_SYSROOT}/usr/bin/perl"
    elif [ -x "${ADM_SYSROOT}/bin/perl" ]; then
        perl_bin="${ADM_SYSROOT}/bin/perl"
    else
        log_error "Sanity-check Perl falhou: perl não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    # Versão
    local ver
    ver="$("${perl_bin}" -v 2>/dev/null | head -n3 | tr '\n' ' ' || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Perl falhou: não foi possível obter versão de ${perl_bin}."
        exit 1
    fi
    log_info "Perl: perl -v → ${ver}"

    # Teste simples: perl -e 'print "ok-perl\n"'
    local out
    out="$("${perl_bin}" -e 'print qq(ok-perl\n);' 2>/dev/null || true)"
    if [ "$out" != "ok-perl" ]; then
        log_error "Sanity-check Perl falhou: perl -e 'print ...' não retornou 'ok-perl'. Saída foi: '$out'"
        exit 1
    fi

    # Verificar se os diretórios de libs principais existem
    local short_ver="${PKG_VERSION%.*}"
    local core_lib="${ADM_SYSROOT}/usr/lib/perl5/${short_ver}/core_perl"
    local site_lib="${ADM_SYSROOT}/usr/lib/perl5/${short_ver}/site_perl"
    local vendor_lib="${ADM_SYSROOT}/usr/lib/perl5/${short_ver}/vendor_perl"

    local missing=0
    if [ ! -d "${core_lib}" ]; then
        log_warn "Perl: diretório core_perl não encontrado em ${core_lib}"
        missing=1
    fi
    if [ ! -d "${site_lib}" ]; then
        log_warn "Perl: diretório site_perl não encontrado em ${site_lib}"
        missing=1
    fi
    if [ ! -d "${vendor_lib}" ]; then
        log_warn "Perl: diretório vendor_perl não encontrado em ${vendor_lib}"
        missing=1
    fi

    if [ "$missing" -eq 0 ]; then
        log_info "Perl: diretórios de libs encontrados em /usr/lib/perl5/${short_ver}/{core,site,vendor}_perl."
    fi

    log_ok "Sanity-check Perl-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
