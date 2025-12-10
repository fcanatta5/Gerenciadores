# /opt/adm/packages/base/bison-3.8.2.sh
#
# Bison-3.8.2 - gerador de analisadores (parser generator)
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - constrói em modo "normal" (não pass1), em /usr do rootfs do profile
#   - fluxo estilo LFS adaptado para cross/profile:
#       ./configure --prefix=/usr --host=$ADM_TARGET --build=$(config.guess) \
#                   --disable-static \
#                   --docdir=/usr/share/doc/bison-3.8.2
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR (adm faz rsync)
#   - hooks de sanity-check no rootfs (bison gerando um parser simples)

PKG_NAME="bison"
PKG_VERSION="3.8.2"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/bison/bison-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/bison/bison-${PKG_VERSION}.tar.xz"
  "https://ftp.unicamp.br/pub/gnu/bison/bison-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="bison-${PKG_VERSION}.tar.xz"

# SHA256 pode ser preenchido depois com o valor oficial.
# Enquanto vazio, o adm apenas não verifica o checksum.
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas (ajuste os nomes exatamente como estão nos seus outros scripts)
PKG_DEPENDS=(
  "m4-1.4.20"
  "bash-5.3"
  "coreutils-9.9"
  "grep-3.12"
  "sed-4.9"
)

# Sem patches por padrão
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# Se tiver patches locais, pode usar:
# PKG_PATCHES=("/opt/adm/patches/bison-3.8.2-fix-xyz.patch")

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Log do toolchain disponível no rootfs se houver /tools
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Construção padrão, adaptada ao esquema cross/profile:
    #
    #   ./configure --prefix=/usr \
    #               --host=$LFS_TGT \
    #               --build=$(build-aux/config.guess) \
    #               --disable-static \
    #               --docdir=/usr/share/doc/bison-3.8.2
    #   make
    #
    # Mapas:
    #   LFS_TGT -> ADM_TARGET
    #   DESTDIR -> gerenciado pelo adm (rsync para ADM_SYSROOT)

    local build_triplet

    if [ -x "./build-aux/config.guess" ]; then
        build_triplet="$(./build-aux/config.guess)"
    else
        build_triplet="$(./config.guess)"
    fi

    ./configure \
        --prefix=/usr \
        --host="${ADM_TARGET}" \
        --build="${build_triplet}" \
        --disable-static \
        --docdir="/usr/share/doc/bison-${PKG_VERSION}"

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm faz o sync depois para ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Se quiser, pode instalar apenas o binário principal e libs,
    # e remover partes não desejadas (ex.: docs pesadas).
    # Aqui, deixamos o padrão do Bison.
}

post_install() {
    # Sanity-check Bison dentro do rootfs do profile:
    #
    # 1) localizar /usr/bin/bison (ou /bin/bison se você mover futuramente)
    # 2) bison --version funciona
    # 3) gerar um parser simples a partir de uma gramática mínima (.y)
    #
    local bison_bin=""

    if [ -x "${ADM_SYSROOT}/usr/bin/bison" ]; then
        bison_bin="${ADM_SYSROOT}/usr/bin/bison"
    elif [ -x "${ADM_SYSROOT}/bin/bison" ]; then
        bison_bin="${ADM_SYSROOT}/bin/bison"
    else
        log_error "Sanity-check Bison falhou: bison não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    # Versão
    local ver
    ver="$("${bison_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Bison falhou: não foi possível obter versão de ${bison_bin}."
        exit 1
    fi
    log_info "Bison: bison --version → ${ver}"

    # Teste real: gerar um parser simples
    local tmpdir
    tmpdir="$(mktemp -d)"

    cat > "${tmpdir}/calc.y" << 'EOF'
%{
#include <stdio.h>
#include <stdlib.h>
int yylex(void);
void yyerror(const char *s) { fprintf(stderr, "erro: %s\n", s); }
%}

%token NUM
%left '+' '-'
%left '*' '/'

%%
input:
    /* vazio */
  | input line
  ;

line:
    '\n'
  | expr '\n'   { /* resultado descartado no teste */ }
  ;

expr:
    NUM               { /* terminal */ }
  | expr '+' expr
  | expr '-' expr
  | expr '*' expr
  | expr '/' expr
  ;

%%
int main(void) {
    return yyparse();
}
EOF

    # Gerar arquivos a partir da gramática
    if ! "${bison_bin}" -d "${tmpdir}/calc.y" -o "${tmpdir}/calc.tab.c" >/dev/null 2>&1; then
        log_error "Sanity-check Bison falhou: não foi possível gerar parser a partir de calc.y."
        rm -rf "${tmpdir}"
        exit 1
    fi

    if [ ! -f "${tmpdir}/calc.tab.c" ] || [ ! -f "${tmpdir}/calc.tab.h" ]; then
        log_error "Sanity-check Bison falhou: arquivos calc.tab.c/calc.tab.h não foram gerados."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check Bison-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
