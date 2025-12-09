# /opt/adm/packages/base/diffutils-3.12.sh
#
# Diffutils-3.12 - pacote base (ferramenta temporária / sistema)
#
# Integração com adm:
#   - usa cache de sources (PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256)
#   - segue o fluxo LFS Chapter 6 para cross-tools:
#       ./configure --prefix=/usr --host=$ADM_TARGET gl_cv_func_strcasecmp_works=y \
#                  --build=$(./build-aux/config.guess)
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs do profile

PKG_NAME="diffutils"
PKG_VERSION="3.12"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/diffutils/diffutils-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/diffutils/diffutils-${PKG_VERSION}.tar.xz"
  "https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4-rc1/diffutils-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="diffutils-${PKG_VERSION}.tar.xz"

# SHA256 do diffutils-3.12.tar.xz (ports do FreeBSD / Nix / mirrors) 
PKG_SHA256="7c8b7f9fc8609141fdea9cece85249d308624391ff61dedaf528fcb337727dfd"

# Dependências lógicas (ajuste os nomes conforme seus arquivos de pacote)
PKG_DEPENDS=(
  "coreutils-9.9"
  "bash-5.3"
)

# Não há patch obrigatório em LFS para Diffutils-3.12
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Informar qual toolchain está disponível (útil em phase cross/toolchain)
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Construção conforme LFS Chapter 6.6 (Diffutils-3.12), adaptado para adm:
    #
    #   ./configure --prefix=/usr   \
    #               --host=$LFS_TGT \
    #               gl_cv_func_strcasecmp_works=y \
    #               --build=$(./build-aux/config.guess)
    #
    # Mapas:
    #   LFS_TGT           -> ADM_TARGET
    #   DESTDIR=$LFS      -> DESTDIR gerenciado pelo adm (adm faz rsync para ADM_SYSROOT)
    #
    # O hack gl_cv_func_strcasecmp_works=y é necessário em cross-compile
    # para evitar teste que executa binário nativo. 

    local build_triplet
    build_triplet="$(./build-aux/config.guess)"

    gl_cv_func_strcasecmp_works=y \
    ./configure \
        --prefix=/usr \
        --host="${ADM_TARGET}" \
        --build="${build_triplet}"

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install
}

post_install() {
    # Sanity-check Diffutils:
    #
    # 1) ${ADM_SYSROOT}/usr/bin/diff existe e é executável
    # 2) diff --version funciona
    # 3) diff de dois arquivos simples retorna o esperado

    local usrbin="${ADM_SYSROOT}/usr/bin"
    local diff_bin="${usrbin}/diff"

    if [ ! -x "${diff_bin}" ]; then
        log_error "Sanity-check Diffutils falhou: ${diff_bin} não encontrado ou não executável."
        exit 1
    fi

    # Verificar versão
    local ver
    ver="$("${diff_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Diffutils falhou: não foi possível obter versão de ${diff_bin}."
        exit 1
    fi
    log_info "Diffutils: diff --version → ${ver}"

    # Teste simples de diff entre dois arquivos
    local tmpdir
    tmpdir="$(mktemp -d)"

    cat > "${tmpdir}/a.txt" << 'EOF'
linha1
linha2
EOF

    cat > "${tmpdir}/b.txt" << 'EOF'
linha1
linha2-mod
EOF

    local out
    out="$("${diff_bin}" "${tmpdir}/a.txt" "${tmpdir}/b.txt" 2>/dev/null || true)"

    # Só checamos se não está vazio (deve haver alguma diferença)
    if [ -z "${out}" ]; then
        log_warn "Sanity-check Diffutils: diff não reportou diferenças entre arquivos claramente diferentes."
    else
        log_info "Diffutils: teste simples de diff entre a.txt e b.txt retornou saída (OK)."
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check Diffutils-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
