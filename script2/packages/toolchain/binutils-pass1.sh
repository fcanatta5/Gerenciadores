# /opt/adm/packages/toolchain/binutils-pass1.sh
#
# Binutils 2.45.1 - Pass 1 (cross, temporary tools)
# Constrói em modo cross e instala em $ADM_ROOT/tools/$ADM_PROFILE
# para não sujar o rootfs de glibc / musl.
#
# Compatível com o gerenciador "adm" descrito anteriormente.

PKG_NAME="binutils-pass1"
PKG_VERSION="2.45.1"
PKG_CATEGORY="toolchain"

# Tarball oficial (LFS usa este URL como referência) 1
PKG_SOURCE_URLS=(
  "https://sourceware.org/pub/binutils/releases/binutils-${PKG_VERSION}.tar.xz"
  "https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
  "https://ftp.wayne.edu/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="binutils-${PKG_VERSION}.tar.xz"

# MD5 oficial do livro LFS/LFS multilib (para o tar.xz) 2
PKG_MD5="ff59f8dc1431edfa54a257851bea74e7"

# Passo 1 de toolchain: normalmente sem dependências de runtime
PKG_DEPENDS=()

# Sem patches por padrão
PKG_PATCHES=()

# ---------------------------------------------------------------------
# Helpers locais
# ---------------------------------------------------------------------

_binutils_tools_prefix() {
    # Usamos o mesmo ADM_ROOT do "adm" (default /opt/adm)
    local adm_root="${ADM_ROOT:-/opt/adm}"
    # tools por profile (glibc, musl, etc.)
    printf "%s/tools/%s" "$adm_root" "${ADM_PROFILE}"
}

# ---------------------------------------------------------------------
# Hooks do pacote
# ---------------------------------------------------------------------

pre_build() {
    # Garante que o diretório de tools do profile exista
    local tools_prefix
    tools_prefix="$(_binutils_tools_prefix)"
    mkdir -p "${tools_prefix}"

    log_info "Binutils Pass 1: usando tools_prefix=${tools_prefix}"
    log_info "Profile=${ADM_PROFILE} TARGET=${ADM_TARGET} SYSROOT=${ADM_SYSROOT}"
}

build() {
    local tools_prefix
    tools_prefix="$(_binutils_tools_prefix)"

    # Construção em diretório separado (recomendação da documentação / LFS) 3
    mkdir -v build
    cd build

    # Configuração baseada no LFS Binutils Pass 1,
    # adaptada para o esquema de profiles do adm.
    ../configure \
        --prefix="${tools_prefix}" \
        --with-sysroot="${ADM_SYSROOT}" \
        --target="${ADM_TARGET}" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror \
        --enable-new-dtags \
        --enable-default-hash-style=gnu

    # Compilação
    make
}

install_pkg() {
    # Nesta fase, já estamos dentro de $srcdir/build por causa do fluxo do adm
    local tools_prefix
    tools_prefix="$(_binutils_tools_prefix)"

    log_info "Instalando Binutils Pass 1 em ${tools_prefix} (não toca no rootfs)"

    # Instala diretamente no prefix de tools.
    # NÃO usamos DESTDIR aqui de propósito, para não sujar o rootfs.
    make install

    # Observação:
    # - O gerenciador adm ainda vai tentar gerar um manifest comparando o SYSROOT
    #   (glibc-rootfs/musl-rootfs) antes/depois, mas como nada foi instalado lá,
    #   o manifest ficará vazio, e o rootfs permanece limpo.
    # - Os binários cross ficarão em ${tools_prefix}/bin/${ADM_TARGET}-*,
    #   como esperado para um toolchain temporário de Binutils Pass 1. 4
}

_post_sanity_check() {
    local tools_prefix bindir
    tools_prefix="$(_binutils_tools_prefix)"
    bindir="${tools_prefix}/bin"

    local failed=0
    local prog
    local targets=(
        addr2line
        ar
        as
        ld
        ld.bfd
        nm
        objcopy
        objdump
        ranlib
        readelf
        size
        strings
        strip
    )

    log_info "Executando sanity-check de Binutils Pass 1 em ${bindir}"

    for prog in "${targets[@]}"; do
        local path="${bindir}/${ADM_TARGET}-${prog}"
        if [ ! -x "${path}" ]; then
            log_error "sanity-check: ferramenta não encontrada: ${path}"
            failed=1
            continue
        fi

        # Teste simples de execução
        if ! "${path}" --version >/dev/null 2>&1; then
            log_error "sanity-check: falha ao executar: ${path} --version"
            failed=1
        fi
    done

    if [ "${failed}" -ne 0 ]; then
        log_error "sanity-check: Binutils-${PKG_VERSION} Pass 1 FALHOU para profile ${ADM_PROFILE} (target ${ADM_TARGET})."
        log_error "Verifique o log de build e a saída das ferramentas acima."
        exit 1
    fi

    log_ok "sanity-check: Binutils-${PKG_VERSION} Pass 1 OK em ${tools_prefix} para profile ${ADM_PROFILE} (target ${ADM_TARGET})."
}

post_install() {
    # Sanity-check depois da instalação nos tools/
    _post_sanity_check
}

pre_uninstall() {
    # Atenção: como este pacote instala diretamente em tools/, o manifesto
    # gerado pelo adm para o SYSROOT fica vazio. Na prática, o uninstall
    # padrão do adm não remove estes binários.
    # Se quiser limpeza de tools, remova ${ADM_ROOT}/tools/${ADM_PROFILE} manualmente
    # ou implemente aqui uma rotina específica.
    log_warn "pre_uninstall: binutils-pass1 é um pacote de toolchain temporário; uninstall automático pode não limpar tools/."
}

post_uninstall() {
    log_info "post_uninstall: nenhuma ação adicional para binutils-pass1 (toolchain temporário)."
}
