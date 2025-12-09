# /opt/adm/packages/base/xz-5.8.1.sh
#
# Xz-5.8.1 - utilitários xz / lzma e liblzma
#
# Integração com adm:
#   - usa cache de sources (PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256)
#   - fluxo padrão estilo LFS adaptado ao esquema cross/profile:
#       ./configure --prefix=/usr --host=$ADM_TARGET --build=$(config.guess) \
#                   --disable-static
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - opcional: mover xz para /bin e criar symlink em /usr/bin
#   - hooks de sanity-check no rootfs (compressão/descompressão .xz)

PKG_NAME="xz"
PKG_VERSION="5.8.1"
PKG_CATEGORY="base"

# Fontes oficiais (XZ Utils e mirrors usuais)
PKG_SOURCE_URLS=(
  "https://tukaani.org/xz/xz-${PKG_VERSION}.tar.xz"
  "https://github.com/tukaani-project/xz/releases/download/v${PKG_VERSION}/xz-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="xz-${PKG_VERSION}.tar.xz"

# Preencha com o SHA256 oficial quando tiver; enquanto vazio, o adm só emite warning.
PKG_SHA256=""
# Ou MD5, se preferir (deixe em branco se não tiver):
PKG_MD5=""

# Dependências lógicas (ajuste nomes conforme seus scripts)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
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

    # Log do toolchain (se estiver usando /tools)
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Construção padrão adaptada a cross/profile:
    #
    #   ./configure --prefix=/usr --host=$LFS_TGT --build=$(config.guess) \
    #               --disable-static
    #   make
    #
    # Mapas:
    #   LFS_TGT -> ADM_TARGET
    #   DESTDIR -> gerenciado pelo adm (que faz rsync para ADM_SYSROOT)

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
        --disable-static

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm sincroniza depois para ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Opcional: mover xz para /bin e criar symlink em /usr/bin.
    # Comente se não quiser isso.
    #
    # local dest_root="${DESTDIR}"
    # local dest_usr_bin="${dest_root}/usr/bin"
    # local dest_bin="${dest_root}/bin"
    # mkdir -pv "${dest_bin}"
    #
    # if [ -x "${dest_usr_bin}/xz" ]; then
    #     mv -v "${dest_usr_bin}/xz" "${dest_bin}/xz"
    #     ln -sfv "../bin/xz" "${dest_usr_bin}/xz"
    # fi
}

post_install() {
    # Sanity-check Xz:
    #
    # 1) encontrar xz (em /usr/bin ou /bin)
    # 2) xz --version funciona
    # 3) round-trip simples: compactar um arquivo em .xz e descompactar
    #

    local xz_bin=""

    if [ -x "${ADM_SYSROOT}/usr/bin/xz" ]; then
        xz_bin="${ADM_SYSROOT}/usr/bin/xz"
    elif [ -x "${ADM_SYSROOT}/bin/xz" ]; then
        xz_bin="${ADM_SYSROOT}/bin/xz"
    else
        log_error "Sanity-check Xz falhou: xz não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    # Versão
    local ver
    ver="$("${xz_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Xz falhou: não foi possível obter versão de ${xz_bin}."
        exit 1
    fi
    log_info "Xz: xz --version → ${ver}"

    # Round-trip de teste
    local tmpdir
    tmpdir="$(mktemp -d)"
    local orig="${tmpdir}/orig.txt"
    local xzfile="${tmpdir}/orig.txt.xz"
    local out="${tmpdir}/out.txt"

    printf 'teste-xz-adm-123\nsegunda-linha\n' > "${orig}"

    # Compactar (-k para manter o original)
    "${xz_bin}" -k "${orig}" 2>/dev/null

    if [ ! -f "${xzfile}" ]; then
        log_error "Sanity-check Xz falhou: arquivo compactado ${xzfile} não foi criado."
        rm -rf "${tmpdir}"
        exit 1
    fi

    # Descompactar para um arquivo separado usando -dc
    "${xz_bin}" -dc "${xzfile}" > "${out}" 2>/dev/null || true

    if ! cmp -s "${orig}" "${out}"; then
        log_error "Sanity-check Xz falhou: conteúdo após compressão/descompressão difere do original."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check Xz-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
