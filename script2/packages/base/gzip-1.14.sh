# /opt/adm/packages/base/gzip-1.14.sh
#
# Gzip-1.14 - utilitário de compressão GNU
#
# Integração com adm:
#   - usa cache de sources (PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256)
#   - fluxo LFS Chapter 6 (ferramenta temporária / cross) adaptado:
#       ./configure --prefix=/usr --host=$ADM_TARGET
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs do profile (compressão / descompressão)

PKG_NAME="gzip"
PKG_VERSION="1.14"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors) 
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/gzip/gzip-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/gzip/gzip-${PKG_VERSION}.tar.xz"
  "https://ftp.unicamp.br/pub/gnu/gzip/gzip-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="gzip-${PKG_VERSION}.tar.xz"

# SHA256 oficial (Buildroot hash após checar assinatura PGP) 
PKG_SHA256="01a7b881bd220bfdf615f97b8718f80bdfd3f6add385b993dcf6efd14e8c0ac6"

# Dependências lógicas (ajuste os nomes conforme os seus scripts)
PKG_DEPENDS=(
  "coreutils-9.9"
  "bash-5.3"
)

# Sem patch padrão para Gzip-1.14 no LFS
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Apenas loga se estiver usando toolchain em /tools
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Conforme LFS 6.11 (Gzip-1.14) para ferramentas temporárias:
    #
    #   ./configure --prefix=/usr --host=$LFS_TGT
    #   make
    #
    # Aqui:
    #   LFS_TGT -> ADM_TARGET
    #   DESTDIR -> gerenciado pelo adm (adm faz rsync para ADM_SYSROOT) 

    ./configure \
        --prefix=/usr \
        --host="${ADM_TARGET}"

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Opcional: mover gzip para /bin e criar symlink em /usr/bin, se quiser
    # seguir uma política mais FHS-like para ferramentas básicas.
    #
    # Descomentando esse bloco, você terá:
    #   /bin/gzip real
    #   /usr/bin/gzip -> ../bin/gzip
    #
    # local dest_root="${DESTDIR}"
    # local dest_usr_bin="${dest_root}/usr/bin"
    # local dest_bin="${dest_root}/bin"
    # mkdir -pv "${dest_bin}"
    #
    # if [ -x "${dest_usr_bin}/gzip" ]; then
    #     mv -v "${dest_usr_bin}/gzip" "${dest_bin}/gzip"
    #     ln -sfv "../bin/gzip" "${dest_usr_bin}/gzip"
    # fi
}

post_install() {
    # Sanity-check Gzip dentro do rootfs do profile:
    #
    # 1) localizar o binário gzip (em /usr/bin ou /bin)
    # 2) gzip --version funciona
    # 3) round-trip simples de compressão + descompressão preserva o conteúdo
    #

    local gzip_bin=""

    if [ -x "${ADM_SYSROOT}/usr/bin/gzip" ]; then
        gzip_bin="${ADM_SYSROOT}/usr/bin/gzip"
    elif [ -x "${ADM_SYSROOT}/bin/gzip" ]; then
        gzip_bin="${ADM_SYSROOT}/bin/gzip"
    else
        log_error "Sanity-check Gzip falhou: gzip não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    # Versão
    local ver
    ver="$("${gzip_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Gzip falhou: não foi possível obter versão de ${gzip_bin}."
        exit 1
    fi
    log_info "Gzip: gzip --version → ${ver}"

    # Round-trip de teste
    local tmpdir
    tmpdir="$(mktemp -d)"
    local orig="${tmpdir}/orig.txt"
    local gz="${tmpdir}/orig.txt.gz"
    local out="${tmpdir}/out.txt"

    printf 'teste-gzip-adm-123\nsegunda-linha\n' > "${orig}"

    # Comprimir
    "${gzip_bin}" -k "${orig}" 2>/dev/null

    if [ ! -f "${gz}" ]; then
        log_error "Sanity-check Gzip falhou: arquivo compactado ${gz} não foi criado."
        rm -rf "${tmpdir}"
        exit 1
    fi

    # Descomprimir (para arquivo separado, usando -c)
    "${gzip_bin}" -dc "${gz}" > "${out}" 2>/dev/null || true

    if ! cmp -s "${orig}" "${out}"; then
        log_error "Sanity-check Gzip falhou: conteúdo após compressão/descompressão difere do original."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check Gzip-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
