# /opt/adm/packages/base/ncurses-6.5.sh
#
# Ncurses-6.5 - pacote base
# Integração com adm:
#   - usa cache de sources (PKG_SOURCE_URLS/PKG_TARBALL/PKG_SHA256)
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - configura ABI wide-char (w) como padrão (curses.h)
#   - gera symlinks compatíveis (libncurses.so, libcurses.so, .pc)
#   - hooks de sanity-check

PKG_NAME="ncurses"
PKG_VERSION="6.5"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirror do autor)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/ncurses/ncurses-${PKG_VERSION}.tar.gz"
  "https://invisible-island.net/archives/ncurses/ncurses-${PKG_VERSION}.tar.gz"
)

PKG_TARBALL="ncurses-${PKG_VERSION}.tar.gz"

# SHA256 oficial (mesmo usado pelo port do FreeBSD) 
PKG_SHA256="136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6"

# Dependências lógicas (ajuste conforme os nomes no seu tree)
PKG_DEPENDS=(
  "glibc-pass1"       # ou "musl-pass1" dependendo do profile
  "libstdcxx-pass1"   # C++ bindings compartilhados
)

# Nenhum patch necessário aqui
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Apenas loga qual toolchain está ativo
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Construção estilo LFS capítulo 8.30 (sistema final), adaptado para adm:
    # ./configure + make dentro da árvore de source.
    #
    # LFS usa: ./configure --prefix=/usr --mandir=/usr/share/man \
    #   --with-shared --without-debug --without-normal --with-cxx-shared \
    #   --enable-pc-files --with-pkg-config-libdir=/usr/lib/pkgconfig 

    ./configure \
        --prefix=/usr \
        --mandir=/usr/share/man \
        --with-shared \
        --without-debug \
        --without-normal \
        --with-cxx-shared \
        --enable-pc-files \
        --with-pkg-config-libdir=/usr/lib/pkgconfig

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm fará rsync para ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Agora aplicamos os ajustes em DESTDIR (não no host),
    # seguindo a ideia do LFS, mas dentro do SYSROOT do profile.

    local dest_usr="${DESTDIR}/usr"
    local dest_lib="${dest_usr}/lib"
    local dest_inc="${dest_usr}/include"
    local dest_pc="${dest_usr}/lib/pkgconfig"

    # Garantir diretórios
    mkdir -pv "${dest_lib}" "${dest_inc}" "${dest_pc}"

    # Forçar uso da ABI wide-char no curses.h
    # (equivalente ao sed do LFS, mas aplicado em DESTDIR) 
    if [ -f "${dest_inc}/curses.h" ]; then
        sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "${dest_inc}/curses.h"
    else
        log_warn "curses.h não encontrado em ${dest_inc}; não foi possível aplicar sed para ABI wide-char."
    fi

    # Symlinks de compatibilidade: ncurses, form, panel, menu e libcurses
    # (igual ao LFS, mas no DESTDIR) 
    local lib
    for lib in ncurses form panel menu; do
        if [ -f "${dest_lib}/lib${lib}w.so" ]; then
            ln -sfv "lib${lib}w.so" "${dest_lib}/lib${lib}.so"
        fi
        if [ -f "${dest_pc}/${lib}w.pc" ]; then
            ln -sfv "${lib}w.pc" "${dest_pc}/${lib}.pc"
        fi
    done

    if [ -f "${dest_lib}/libncursesw.so" ]; then
        ln -sfv "libncursesw.so" "${dest_lib}/libcurses.so"
    fi

    # (Opcional) documentação:
    # mkdir -pv "${dest_usr}/share/doc/ncurses-${PKG_VERSION}"
    # cp -av doc/* "${dest_usr}/share/doc/ncurses-${PKG_VERSION}/"
}

post_install() {
    # Sanity-check Ncurses:
    #
    # 1) libs wide-char em ${ADM_SYSROOT}/usr/lib
    # 2) curses.h wide-char em ${ADM_SYSROOT}/usr/include/curses.h
    # 3) tput funcionando minimamente

    local usrlib="${ADM_SYSROOT}/usr/lib"
    local usrinc="${ADM_SYSROOT}/usr/include"
    local pcdir="${ADM_SYSROOT}/usr/lib/pkgconfig"

    if [ ! -d "${usrlib}" ]; then
        log_error "Sanity-check Ncurses falhou: diretório ${usrlib} não existe."
        exit 1
    fi
    if [ ! -d "${usrinc}" ]; then
        log_error "Sanity-check Ncurses falhou: diretório ${usrinc} não existe."
        exit 1
    fi

    local libncursesw="${usrlib}/libncursesw.so"
    if [ ! -e "${libncursesw}" ]; then
        # pode ser libncursesw.so.6.5 apenas, tentamos localizar
        libncursesw="$(find "${usrlib}" -maxdepth 1 -type f -name 'libncursesw.so*' 2>/dev/null | head -n1 || true)"
    fi

    if [ -z "${libncursesw}" ] || [ ! -e "${libncursesw}" ]; then
        log_error "Sanity-check Ncurses falhou: libncursesw.so* não encontrada em ${usrlib}."
        exit 1
    fi

    log_info "Ncurses: libncursesw encontrada em ${libncursesw}"

    local curses_h="${usrinc}/curses.h"
    if [ ! -f "${curses_h}" ]; then
        log_error "Sanity-check Ncurses falhou: ${curses_h} não encontrado."
        exit 1
    fi

    # Verificar se curses.h foi “wide-ificado”
    if ! grep -q '^#if 1' "${curses_h}"; then
        log_warn "curses.h não parece ter sido ajustado para ABI wide-char (#if 1 não encontrado)."
    else
        log_info "curses.h ajustado para ABI wide-char."
    fi

    # Checar alguns .pc
    if [ -d "${pcdir}" ]; then
        if [ -f "${pcdir}/ncursesw.pc" ]; then
            log_info "Encontrado ncursesw.pc em ${pcdir}"
        fi
    fi

    # Teste simples com tput (se existir)
    local tput_bin="${ADM_SYSROOT}/usr/bin/tput"
    if [ -x "${tput_bin}" ]; then
        if "${tput_bin}" cols >/dev/null 2>&1; then
            log_info "Ncurses: tput cols executado com sucesso."
        else
            log_warn "Ncurses: tput existe mas falhou ao rodar 'tput cols'."
        fi
    else
        log_warn "Ncurses: tput não encontrado em ${ADM_SYSROOT}/usr/bin; pulando teste de tput."
    fi

    log_ok "Sanity-check Ncurses-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
