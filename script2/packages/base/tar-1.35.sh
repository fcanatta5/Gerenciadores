# /opt/adm/packages/base/tar-1.35.sh
#
# Tar-1.35 - utilitário GNU tar
#
# Integração com adm:
#   - usa cache de sources (PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256)
#   - fluxo estilo LFS adaptado para cross/profile:
#       ./configure --prefix=/usr --host=$ADM_TARGET --build=$(build-aux/config.guess)
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs do profile (cria/extrai um tar de teste)

PKG_NAME="tar"
PKG_VERSION="1.35"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/tar/tar-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/tar/tar-${PKG_VERSION}.tar.xz"
  "https://ftp.unicamp.br/pub/gnu/tar/tar-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="tar-${PKG_VERSION}.tar.xz"

# Deixe vazio se não tiver certeza da hash; o adm apenas vai pular a verificação.
# Se quiser travar, preencha com o SHA256 oficial:
PKG_SHA256=""
# Ou MD5:
PKG_MD5=""

# Dependências lógicas (ajuste os nomes conforme seus outros scripts)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
  "gzip-1.14"
)

# Sem patch padrão aqui
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Apenas loga se houver toolchain adicional em /tools
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
    #               --build=$(build-aux/config.guess)
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
        --build="${build_triplet}"

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Opcional: mover tar para /bin e criar symlink em /usr/bin,
    # caso queira tar no conjunto mínimo de /bin.
    #
    # Descomente se quiser:
    #
    # local dest_root="${DESTDIR}"
    # local dest_usr_bin="${dest_root}/usr/bin"
    # local dest_bin="${dest_root}/bin"
    # mkdir -pv "${dest_bin}"
    #
    # if [ -x "${dest_usr_bin}/tar" ]; then
    #     mv -v "${dest_usr_bin}/tar" "${dest_bin}/tar"
    #     ln -sfv "../bin/tar" "${dest_usr_bin}/tar"
    # fi
}

post_install() {
    # Sanity-check Tar:
    #
    # 1) localizar o binário tar (em /usr/bin ou /bin)
    # 2) tar --version funciona
    # 3) criar um tar simples, extrair e comparar conteúdo

    local tar_bin=""

    if [ -x "${ADM_SYSROOT}/usr/bin/tar" ]; then
        tar_bin="${ADM_SYSROOT}/usr/bin/tar"
    elif [ -x "${ADM_SYSROOT}/bin/tar" ]; then
        tar_bin="${ADM_SYSROOT}/bin/tar"
    else
        log_error "Sanity-check Tar falhou: tar não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    # Versão
    local ver
    ver="$("${tar_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Tar falhou: não foi possível obter versão de ${tar_bin}."
        exit 1
    fi
    log_info "Tar: tar --version → ${ver}"

    # Round-trip de teste: criar um tar com um arquivo de texto e extrair
    local tmpdir
    tmpdir="$(mktemp -d)"
    local srcdir="${tmpdir}/src"
    local dstdir="${tmpdir}/dst"
    local archive="${tmpdir}/teste.tar"

    mkdir -p "${srcdir}" "${dstdir}"
    cat > "${srcdir}/arquivo.txt" << 'EOF'
linha1
linha2
linha3
EOF

    # criar tar
    ( cd "${srcdir}" && "${tar_bin}" -cf "${archive}" . 2>/dev/null )

    if [ ! -f "${archive}" ]; then
        log_error "Sanity-check Tar falhou: arquivo de teste ${archive} não foi criado."
        rm -rf "${tmpdir}"
        exit 1
    fi

    # extrair tar
    ( cd "${dstdir}" && "${tar_bin}" -xf "${archive}" 2>/dev/null )

    if [ ! -f "${dstdir}/arquivo.txt" ]; then]
        log_error "Sanity-check Tar falhou: arquivo não foi extraído corretamente em ${dstdir}/arquivo.txt."
        rm -rf "${tmpdir}"
        exit 1
    fi

    # comparar conteúdo
    if ! cmp -s "${srcdir}/arquivo.txt" "${dstdir}/arquivo.txt"; then
        log_error "Sanity-check Tar falhou: conteúdo do arquivo extraído difere do original."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check Tar-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
