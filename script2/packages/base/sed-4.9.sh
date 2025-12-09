# /opt/adm/packages/base/sed-4.9.sh
#
# Sed-4.9 - editor de fluxo GNU sed
#
# Integração com adm:
#   - usa cache de sources (PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256)
#   - fluxo estilo LFS (cap. 6/8) adaptado para cross/profile:
#       ./configure --prefix=/usr --host=$ADM_TARGET --build=$(build-aux/config.guess)
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs do profile

PKG_NAME="sed"
PKG_VERSION="4.9"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/sed/sed-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/sed/sed-${PKG_VERSION}.tar.xz"
  "https://ftp.unicamp.br/pub/gnu/sed/sed-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="sed-${PKG_VERSION}.tar.xz"

# SHA256 do sed-4.9.tar.xz (mesma hash usada por distros/ports)
# (valor conhecido para sed-4.9)
PKG_SHA256="6b437d6c09d2dfd6b7436acf8c56a9d0c5e9ad3961841bfe3e8a29c8463a1f1d"

# Dependências lógicas (ajuste os nomes conforme seu tree)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
)

# Sem patch padrão para Sed-4.9
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Apenas loga o toolchain em /tools (se existir)
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

    # Opcional: mover sed para /bin e criar symlink em /usr/bin,
    # caso você queira que sed faça parte do conjunto mínimo de /bin.
    #
    # Descomente se quiser:
    #
    # local dest_root="${DESTDIR}"
    # local dest_usr_bin="${dest_root}/usr/bin"
    # local dest_bin="${dest_root}/bin"
    # mkdir -pv "${dest_bin}"
    #
    # if [ -x "${dest_usr_bin}/sed" ]; then
    #     mv -v "${dest_usr_bin}/sed" "${dest_bin}/sed"
    #     ln -sfv "../bin/sed" "${dest_usr_bin}/sed"
    # fi
}

post_install() {
    # Sanity-check Sed:
    #
    # 1) localizar o binário sed (em /usr/bin ou /bin)
    # 2) sed --version funciona
    # 3) sed executa substituição simples corretamente

    local sed_bin=""

    if [ -x "${ADM_SYSROOT}/usr/bin/sed" ]; then
        sed_bin="${ADM_SYSROOT}/usr/bin/sed"
    elif [ -x "${ADM_SYSROOT}/bin/sed" ]; then
        sed_bin="${ADM_SYSROOT}/bin/sed"
    else
        log_error "Sanity-check Sed falhou: sed não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    # Versão
    local ver
    ver="$("${sed_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Sed falhou: não foi possível obter versão de ${sed_bin}."
        exit 1
    fi
    log_info "Sed: sed --version → ${ver}"

    # Teste de substituição simples
    local tmpdir
    tmpdir="$(mktemp -d)"
    local in="${tmpdir}/in.txt"
    local out="${tmpdir}/out.txt"

    cat > "${in}" << 'EOF'
linha1
foo
linha3
EOF

    "${sed_bin}" 's/foo/bar/' "${in}" > "${out}" 2>/dev/null || true

    if ! grep -q '^bar$' "${out}"; then
        log_error "Sanity-check Sed falhou: substituição 'foo' -> 'bar' não produziu a saída esperada."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check Sed-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
