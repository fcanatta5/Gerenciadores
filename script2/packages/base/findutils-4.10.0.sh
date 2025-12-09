# /opt/adm/packages/base/findutils-4.10.0.sh
#
# Findutils-4.10.0 - pacote base (find, locate, updatedb, xargs)
#
# Integração com adm:
#   - usa cache de sources (PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256)
#   - segue o fluxo LFS para build cross/final:
#       ./configure --prefix=/usr --localstatedir=/var/lib/locate \
#                   --host=$ADM_TARGET --build=$(build-aux/config.guess)
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs do profile
#

PKG_NAME="findutils"
PKG_VERSION="4.10.0"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors) 
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/findutils/findutils-${PKG_VERSION}.tar.xz"
  "https://ftp.unicamp.br/pub/gnu/findutils/findutils-${PKG_VERSION}.tar.xz"
  "https://gnu.mirror.constant.com/findutils/findutils-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="findutils-${PKG_VERSION}.tar.xz"

# SHA256 oficial (anúncio info-gnu + ports) 
PKG_SHA256="1387e0b67ff247d2abde998f90dfbf70c1491391a59ddfecb8ae698789f0a4f5"

# Dependências lógicas (ajuste os nomes conforme seus scripts)
PKG_DEPENDS=(
  "coreutils-9.9"
  "bash-5.3"
  "file-5.46"
)

# Não há patch padrão em LFS para Findutils-4.10.0
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Apenas loga informação sobre o toolchain disponível
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Construção baseada no LFS (cap. 6 e 8), adaptada para o adm:
    #
    #   ./configure --prefix=/usr                   \
    #               --localstatedir=/var/lib/locate \
    #               --host=$LFS_TGT                 \
    #               --build=$(build-aux/config.guess)
    #   make
    #
    # Aqui:
    #   LFS_TGT   -> ADM_TARGET
    #   DESTDIR   -> gerenciado pelo adm (adm faz rsync para ADM_SYSROOT) 

    local build_triplet
    build_triplet="$(build-aux/config.guess)"

    ./configure \
        --prefix=/usr \
        --localstatedir=/var/lib/locate \
        --host="${ADM_TARGET}" \
        --build="${build_triplet}"

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Nada especial de pós-instalação em DESTDIR aqui.
    # A criação de /var/lib/locate será feita pela própria instalação.
}

post_install() {
    # Sanity-check Findutils:
    #
    # 1) ${ADM_SYSROOT}/usr/bin/find existe e é executável
    # 2) find --version funciona
    # 3) xargs existe e funciona em um teste simples
    # 4) /var/lib/locate foi criado
    #
    local usrbin="${ADM_SYSROOT}/usr/bin"
    local find_bin="${usrbin}/find"
    local xargs_bin="${usrbin}/xargs"
    local locate_dir="${ADM_SYSROOT}/var/lib/locate"

    # find
    if [ ! -x "${find_bin}" ]; then
        log_error "Sanity-check Findutils falhou: ${find_bin} não encontrado ou não executável."
        exit 1
    fi

    local ver
    ver="$("${find_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Findutils falhou: não foi possível obter versão de ${find_bin}."
        exit 1
    fi
    log_info "Findutils: find --version → ${ver}"

    # xargs
    if [ ! -x "${xargs_bin}" ]; then
        log_error "Sanity-check Findutils falhou: ${xargs_bin} não encontrado ou não executável."
        exit 1
    fi

    # Teste simples de find + xargs em um diretório temporário
    local tmpdir
    tmpdir="$(mktemp -d)"
    touch "${tmpdir}/a" "${tmpdir}/b" "${tmpdir}/c"

    local out
    # Conta quantos arquivos 'a', 'b', 'c' serão ecoados via xargs
    out="$(cd "${tmpdir}" && find . -type f -print | "${xargs_bin}" -n1 echo 2>/dev/null | wc -l || true)"

    if [ "${out}" -lt 3 ]; then
        log_warn "Sanity-check Findutils: teste com find + xargs retornou apenas ${out} linhas (esperado >= 3)."
    else
        log_info "Findutils: teste find + xargs OK (${out} arquivos processados)."
    fi

    rm -rf "${tmpdir}"

    # Verificar diretório da base do locate conforme FHS/LFS 
    if [ -d "${locate_dir}" ]; then
        log_info "Findutils: diretório de base do locate presente em ${locate_dir}."
    else
        log_warn "Findutils: diretório ${locate_dir} ainda não existe. Ele será criado quando updatedb rodar pela primeira vez."
    fi

    log_ok "Sanity-check Findutils-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
