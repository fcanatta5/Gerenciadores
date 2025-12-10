# /opt/adm/packages/base/readline-8.3.sh
#
# Readline-8.3 - biblioteca de edição de linha (usada por bash, etc.)
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - constrói e instala em /usr do rootfs do profile (glibc/musl)
#   - fluxo estilo LFS adaptado para DESTDIR:
#       ./configure --prefix=/usr --disable-static --with-curses \
#                   --docdir=/usr/share/doc/readline-8.3
#       make
#       make DESTDIR=${DESTDIR} install
#       instalar docs
#   - adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
#   - hooks de sanity-check no rootfs (libreadline.so + teste de link com -lreadline)

PKG_NAME="readline"
PKG_VERSION="8.3"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/readline/readline-${PKG_VERSION}.tar.gz"
  "https://ftpmirror.gnu.org/readline/readline-${PKG_VERSION}.tar.gz"
  "https://ftp.unicamp.br/pub/gnu/readline/readline-${PKG_VERSION}.tar.gz"
)

PKG_TARBALL="readline-${PKG_VERSION}.tar.gz"

# Preencha depois com o SHA256 oficial se quiser verificação rígida
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas (ajuste os nomes para bater com seus scripts)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
  "sed-4.9"
  "grep-3.12"
  "gawk-5.3.2"
  "make-4.4.1"
  "gcc-15.2.0"
  "ncurses-6.5"
)

PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# Se você precisar de patches (por exemplo, compatibilidade com novas versões de bash),
# pode adicionar URLs acima ou caminhos locais em PKG_PATCHES=().

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
        log_warn "Readline-${PKG_VERSION} idealmente deve ser construída dentro do chroot; profile=${ADM_PROFILE}, SYSROOT=${ADM_SYSROOT}."
    fi
}

build() {
    # Build padrão com suporte a curses/ncurses:
    #
    #   ./configure --prefix=/usr \
    #               --disable-static \
    #               --with-curses \
    #               --docdir=/usr/share/doc/readline-8.3
    #   make
    #
    # Em alguns sistemas recomenda-se SHLIB_LIBS='-lncursesw'; se você tiver
    # problemas de linkagem, pode adicionar:
    #   make SHLIB_LIBS="-lncursesw"
    #
    # Aqui usamos o caminho "normal" primeiro.

    ./configure \
        --prefix=/usr \
        --disable-static \
        --with-curses \
        --docdir="/usr/share/doc/readline-${PKG_VERSION}"

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm sincroniza depois DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Instalar documentação (exemplos, etc.)
    install -v -d -m755 "${DESTDIR}/usr/share/doc/readline-${PKG_VERSION}"
    cp -v README* NEWS* ChangeLog* \
       "${DESTDIR}/usr/share/doc/readline-${PKG_VERSION}" 2>/dev/null || true
    if [ -d "doc" ]; then
        cp -v doc/* "${DESTDIR}/usr/share/doc/readline-${PKG_VERSION}" 2>/dev/null || true
    fi
}

post_install() {
    # Sanity-check Readline dentro do rootfs do profile:
    #
    # 1) verificar libreadline.so* em ${ADM_SYSROOT}/usr/lib
    # 2) verificar header readline/readline.h em ${ADM_SYSROOT}/usr/include
    # 3) se estiver em chroot e tiver gcc, compilar e executar um teste que
    #    linka com -lreadline (e -lncursesw).

    local libdir="${ADM_SYSROOT}/usr/lib"
    local incdir="${ADM_SYSROOT}/usr/include"
    local have_lib=0

    if [ -d "${libdir}" ]; then
        if find "${libdir}" -maxdepth 1 -name 'libreadline.so*' | head -n1 >/dev/null 2>&1; then
            have_lib=1
        fi
    fi

    if [ "${have_lib}" -ne 1 ]; then
        log_error "Sanity-check readline falhou: libreadline.so* não encontrada em ${libdir}."
        exit 1
    fi
    log_info "readline: bibliotecas libreadline.so* encontradas em ${libdir}."

    if [ ! -f "${incdir}/readline/readline.h" ]; then
        log_warn "readline: header readline.h não encontrado em ${incdir}/readline/readline.h."
    else
        log_info "readline: header readline.h encontrado em ${incdir}/readline/readline.h."
    fi

    # Teste extra apenas se estivermos dentro do chroot e houver gcc
    if [ "${ADM_IN_CHROOT:-0}" = "1" ] && command -v gcc >/dev/null 2>&1; then
        local tmpdir
        tmpdir="$(mktemp -d)"

        cat > "${tmpdir}/rltst.c" << 'EOF'
#include <stdio.h>
#include <readline/readline.h>
#include <readline/history.h>

int main(void) {
    rl_readline_name = "rltst";
    using_history();
    printf("ok-readline\n");
    return 0;
}
EOF

        # Tentamos linkar com -lreadline -lncursesw; se falhar, avisamos
        if gcc -o "${tmpdir}/rltst" "${tmpdir}/rltst.c" -lreadline -lncursesw >/dev/null 2>&1; then
            local out
            out="$("${tmpdir}/rltst" 2>/dev/null || true)"
            if [ "${out}" != "ok-readline" ]; then
                log_warn "readline: programa de teste não retornou 'ok-readline'. Saída: '${out}'"
            else
                log_info "readline: programa de teste linkado com -lreadline/-lncursesw executado com sucesso."
            fi
        else
            log_warn "readline: gcc não conseguiu linkar programa de teste com -lreadline -lncursesw; verifique ncurses e libs."
        fi

        rm -rf "${tmpdir}"
    else
        log_warn "readline: teste de execução não realizado (ADM_IN_CHROOT!=1 ou gcc ausente)."
    fi

    log_ok "Sanity-check readline-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
