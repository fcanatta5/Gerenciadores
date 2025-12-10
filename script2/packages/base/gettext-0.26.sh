# /opt/adm/packages/base/gettext-0.26.sh
#
# Gettext-0.26 - internacionalização (gettext, msgfmt, msgmerge, etc.)
#
# Integração com adm:
#   - usa cache de sources (PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256)
#   - fluxo estilo LFS adaptado para cross/profile:
#       ./configure --prefix=/usr --host=$ADM_TARGET --build=$(config.guess) \
#                   --disable-static \
#                   --docdir=/usr/share/doc/gettext-0.26
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs do profile (gettext/msgfmt)

PKG_NAME="gettext"
PKG_VERSION="0.26"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/gettext/gettext-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/gettext/gettext-${PKG_VERSION}.tar.xz"
  "https://ftp.unicamp.br/pub/gnu/gettext/gettext-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="gettext-${PKG_VERSION}.tar.xz"

# Deixe vazio enquanto não tiver o SHA256 oficial; o adm apenas avisa e não verifica.
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas (ajuste os nomes conforme a sua árvore de pacotes)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
  "sed-4.9"
  "grep-3.12"
  "tar-1.35"
  "xz-5.8.1"
  "gcc-15.2.0"
)

# Sem patches por padrão
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# Se quiser usar patches locais, adicione caminhos em PKG_PATCHES=() no script.

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Log do toolchain
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
    #               --docdir=/usr/share/doc/gettext-${PKG_VERSION}
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
        --docdir="/usr/share/doc/gettext-${PKG_VERSION}"

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm sincroniza depois DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Ajuste clássico de permissões para a lib preloadable (se existir)
    local preload="${DESTDIR}/usr/lib/preloadable_libintl.so"
    if [ -f "${preload}" ]; then
        chmod 0755 "${preload}"
    fi
}

post_install() {
    # Sanity-check Gettext dentro do rootfs do profile:
    #
    # 1) localizar /usr/bin/gettext e /usr/bin/msgfmt (ou /bin, se você mover)
    # 2) gettext --version e msgfmt --version funcionam
    # 3) compilar um .po simples com msgfmt e verificar se o .mo foi gerado

    local gettext_bin=""
    local msgfmt_bin=""

    if [ -x "${ADM_SYSROOT}/usr/bin/gettext" ]; then
        gettext_bin="${ADM_SYSROOT}/usr/bin/gettext"
    elif [ -x "${ADM_SYSROOT}/bin/gettext" ]; then
        gettext_bin="${ADM_SYSROOT}/bin/gettext"
    else
        log_error "Sanity-check Gettext falhou: gettext não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    if [ -x "${ADM_SYSROOT}/usr/bin/msgfmt" ]; then
        msgfmt_bin="${ADM_SYSROOT}/usr/bin/msgfmt"
    elif [ -x "${ADM_SYSROOT}/bin/msgfmt" ]; then
        msgfmt_bin="${ADM_SYSROOT}/bin/msgfmt"
    else
        log_error "Sanity-check Gettext falhou: msgfmt não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    # Versões
    local gv mv
    gv="$("${gettext_bin}" --version 2>/dev/null | head -n1 || true)"
    mv="$("${msgfmt_bin}"   --version 2>/dev/null | head -n1 || true)"

    if [ -z "${gv}" ]; then
        log_error "Sanity-check Gettext falhou: não foi possível obter versão de ${gettext_bin}."
        exit 1
    fi
    if [ -z "${mv}" ]; then
        log_error "Sanity-check Gettext falhou: não foi possível obter versão de ${msgfmt_bin}."
        exit 1
    fi

    log_info "Gettext: gettext --version → ${gv}"
    log_info "Gettext: msgfmt  --version → ${mv}"

    # Teste real com msgfmt: compilar um .po simples
    local tmpdir
    tmpdir="$(mktemp -d)"

    cat > "${tmpdir}/hello.po" << 'EOF'
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"

msgid "hello"
msgstr "olá"
EOF

    if ! "${msgfmt_bin}" -c -o "${tmpdir}/hello.mo" "${tmpdir}/hello.po" >/dev/null 2>&1; then
        log_error "Sanity-check Gettext falhou: msgfmt não conseguiu compilar arquivo .po de teste."
        rm -rf "${tmpdir}"
        exit 1
    fi

    if [ ! -f "${tmpdir}/hello.mo" ]; then
        log_error "Sanity-check Gettext falhou: arquivo hello.mo não foi gerado."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check Gettext-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
