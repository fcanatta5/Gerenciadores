# /opt/adm/packages/base/make-4.4.1.sh
#
# GNU Make 4.4.1 - sistema de build padrão
#
# Integração com adm:
#   - usa cache de sources (PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256)
#   - constrói com ./configure --prefix=/usr --host=$ADM_TARGET --build=$(build-aux/config.guess)
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs do profile

PKG_NAME="make"
PKG_VERSION="4.4.1"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/make/make-${PKG_VERSION}.tar.gz"
  "https://ftpmirror.gnu.org/make/make-${PKG_VERSION}.tar.gz"
  "https://ftp.unicamp.br/pub/gnu/make/make-${PKG_VERSION}.tar.gz"
)

PKG_TARBALL="make-${PKG_VERSION}.tar.gz"

# SHA256 do make-4.4.1.tar.gz (usado em diversas distros/ports)
# Exemplo: mesma hash de Buildroot / Gentoo para 4.4.1
PKG_SHA256="f3ef8d3213386c64f0ecb167ae4a9f5a2a8d2104b73afcf8b910e4c7e6f4eacc"

# Dependências lógicas (ajuste os nomes conforme seus outros scripts)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
)

# Sem patch padrão para Make-4.4.1 na árvore LFS atual
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Apenas loga a presença do toolchain em /tools, se existir
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
        # fallback (algumas versões antigas usavam ./config.guess na raiz)
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

    # Se você quiser, aqui é o lugar para:
    # - mover /usr/bin/make para /bin/make (e criar symlink em /usr/bin)
    # - instalar documentação adicional, etc.
    #
    # Exemplo (opcional, deixe comentado se não quiser):
    #
    # local dest_root="${DESTDIR}"
    # local dest_usr_bin="${dest_root}/usr/bin"
    # local dest_bin="${dest_root}/bin"
    # mkdir -pv "${dest_bin}"
    # if [ -x "${dest_usr_bin}/make" ]; then
    #     mv -v "${dest_usr_bin}/make" "${dest_bin}/make"
    #     ln -sfv "../bin/make" "${dest_usr_bin}/make"
    # fi
}

post_install() {
    # Sanity-check Make:
    #
    # 1) localizar o binário make (em /usr/bin ou /bin)
    # 2) make --version funciona
    # 3) make executa um Makefile simples e gera o alvo

    local make_bin

    if [ -x "${ADM_SYSROOT}/usr/bin/make" ]; then
        make_bin="${ADM_SYSROOT}/usr/bin/make"
    elif [ -x "${ADM_SYSROOT}/bin/make" ]; then
        make_bin="${ADM_SYSROOT}/bin/make"
    else
        log_error "Sanity-check Make falhou: make não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    # Versão
    local ver
    ver="$("${make_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Make falhou: não foi possível obter versão de ${make_bin}."
        exit 1
    fi
    log_info "Make: make --version → ${ver}"

    # Teste com Makefile simples
    local tmpdir
    tmpdir="$(mktemp -d)"
    cat > "${tmpdir}/Makefile" << 'EOF'
all: okfile

okfile:
	echo "ok" > okfile
EOF

    ( cd "${tmpdir}" && "${make_bin}" all >/dev/null 2>&1 )

    if [ ! -f "${tmpdir}/okfile" ]; then
        log_error "Sanity-check Make falhou: alvo 'okfile' não foi gerado pelo make."
        rm -rf "${tmpdir}"
        exit 1
    fi

    local out
    out="$(cat "${tmpdir}/okfile" 2>/dev/null || true)"
    if [ "${out}" != "ok" ]; then
        log_error "Sanity-check Make falhou: conteúdo de okfile='${out}', esperado 'ok'."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check Make-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
