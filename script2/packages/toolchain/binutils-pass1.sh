# /opt/adm/packages/toolchain/binutils-pass1.sh

PKG_NAME="binutils-pass1"
PKG_VERSION="2.45.1"
PKG_CATEGORY="toolchain"

# URLs de download do tarball principal (múltiplos mirrors possíveis)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/binutils/binutils-${PKG_VERSION}.tar.xz"
)

# Nome do arquivo no cache de sources
PKG_TARBALL="binutils-${PKG_VERSION}.tar.xz"

# Deixe vazio se não tiver o hash real ainda (o adm só vai logar WARN)
PKG_SHA256=""
# ou, se quiser múltiplos SHA256 aceitos:
# PKG_SHA256_LIST=(
#   "sha256_mirror1"
#   "sha256_mirror2"
# )

# Dependências (opcional; ajuste quando tiver outros pacotes definidos)
PKG_DEPENDS=(
  # "linux-headers"
)

# Se algum patch for necessário no futuro:
# PKG_PATCH_URLS=(
#   "https://exemplo.org/patches/binutils-2.45.1-algo.patch"
# )
# PKG_PATCH_SHA256=(
#   "xxxxxxxx..."
# )

#
# Binutils Pass 1:
# - constrói um cross-binutils mínimo para o target ($ADM_TARGET)
# - instala em /tools dentro do rootfs alvo ($ADM_SYSROOT/tools)
# - NÃO suja o sistema host
#

build() {
    # /tools fica DENTRO do rootfs do profile (glibc-rootfs, musl-rootfs, etc.)
    local tools_dir="${ADM_SYSROOT}/tools"
    mkdir -pv "${tools_dir}"

    # Diretório de build isolado
    mkdir -v build
    cd build

    # Configuração estilo LFS Pass 1, mas usando variáveis do adm
    ../configure \
        --prefix=/tools \
        --with-sysroot="${ADM_SYSROOT}" \
        --target="${ADM_TARGET}" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror

    make
}

install_pkg() {
    # Instalamos em DESTDIR, assim o adm rastreia tudo via manifesto
    #
    # Resultado final real:
    #   ${ADM_SYSROOT}/tools/bin/${ADM_TARGET}-ld
    #   ${ADM_SYSROOT}/tools/bin/${ADM_TARGET}-as
    #   etc.
    make DESTDIR="${DESTDIR}" install
}

post_install() {
    # Diretório do toolchain dentro do rootfs do profile
    local tools_dir="${ADM_SYSROOT}/tools"
    local target_ld="${tools_dir}/bin/${ADM_TARGET}-ld"
    local target_as="${tools_dir}/bin/${ADM_TARGET}-as"

    # Verifica se o linker e o assembler do target existem
    if [ ! -x "${target_ld}" ]; then
        log_error "Sanity-check Binutils Pass 1 falhou: ${target_ld} não encontrado ou não executável."
        exit 1
    fi

    if [ ! -x "${target_as}" ]; then
        log_error "Sanity-check Binutils Pass 1 falhou: ${target_as} não encontrado ou não executável."
        exit 1
    fi

    # Mostra versões para registro
    log_info "Binutils Pass 1: ${target_ld} --version:"
    "${target_ld}" --version | head -n1 || log_warn "Não foi possível obter versão de ${target_ld}"

    log_info "Binutils Pass 1: ${target_as} --version:"
    "${target_as}" --version | head -n1 || log_warn "Não foi possível obter versão de ${target_as}"

    log_ok "Sanity-check Binutils Pass 1 OK para TARGET=${ADM_TARGET}, profile=${ADM_PROFILE}."
}
