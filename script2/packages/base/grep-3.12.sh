# /opt/adm/packages/base/grep-3.12.sh
#
# Grep-3.12 - utilitário de busca de texto
#
# Integração com adm:
#   - usa cache de sources (PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256)
#   - fluxo simples estilo LFS (capítulo 6/8) adaptado para cross/profile:
#       ./configure --prefix=/usr --host=$ADM_TARGET --build=$(build-aux/config.guess)
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs do profile
#

PKG_NAME="grep"
PKG_VERSION="3.12"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/grep/grep-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/grep/grep-${PKG_VERSION}.tar.xz"
  "https://ftp.unicamp.br/pub/gnu/grep/grep-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="grep-${PKG_VERSION}.tar.xz"

# SHA256 do grep-3.12.tar.xz (usado em diversos ports/distros)
PKG_SHA256="2bb6363a2676f2ca1e64980a1ad66a1bbe987ae12b6b720278f251ec8d594139"

# Dependências lógicas (ajuste os nomes conforme seus outros scripts)
PKG_DEPENDS=(
  "coreutils-9.9"
  "bash-5.3"
)

# Sem patch padrão para Grep-3.12 no LFS atual
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Informar toolchain (útil para entender se está em fase /tools ou sistema)
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Construção padrão (sem hacks especiais), adaptada para cross/profile:
    #
    #   ./configure --prefix=/usr \
    #               --host=$LFS_TGT \
    #               --build=$(build-aux/config.guess)
    #   make
    #
    # Mapas:
    #   LFS_TGT -> ADM_TARGET
    #   DESTDIR -> gerenciado pelo adm (adm faz rsync para ADM_SYSROOT)

    local build_triplet
    build_triplet="$(build-aux/config.guess)"

    ./configure \
        --prefix=/usr \
        --host="${ADM_TARGET}" \
        --build="${build_triplet}"

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Não há ajustes especiais de FHS/relocalização necessários aqui.
    # Se quiser, este é o lugar para mover grep para /bin e criar symlink em /usr/bin.
    #
    # Exemplo (opcional, descomentando):
    #
    # local dest_root="${DESTDIR}"
    # local dest_usr_bin="${dest_root}/usr/bin"
    # local dest_bin="${dest_root}/bin"
    # mkdir -pv "${dest_bin}"
    #
    # if [ -x "${dest_usr_bin}/grep" ]; then
    #     mv -v "${dest_usr_bin}/grep" "${dest_bin}/grep"
    #     ln -sfv "../bin/grep" "${dest_usr_bin}/grep"
    # fi
}

post_install() {
    # Sanity-check Grep:
    #
    # 1) ${ADM_SYSROOT}/usr/bin/grep (ou /bin/grep, se você mover) existe e é executável
    # 2) grep --version funciona
    # 3) grep encontra corretamente um padrão simples
    #
    local grep_bin

    if [ -x "${ADM_SYSROOT}/usr/bin/grep" ]; then
        grep_bin="${ADM_SYSROOT}/usr/bin/grep"
    elif [ -x "${ADM_SYSROOT}/bin/grep" ]; then
        grep_bin="${ADM_SYSROOT}/bin/grep"
    else
        log_error "Sanity-check Grep falhou: grep não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    # Versão
    local ver
    ver="$("${grep_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Grep falhou: não foi possível obter versão de ${grep_bin}."
        exit 1
    fi
    log_info "Grep: grep --version → ${ver}"

    # Teste simples de busca
    local tmpdir
    tmpdir="$(mktemp -d)"
    local txt="${tmpdir}/teste.txt"

    cat > "${txt}" << 'EOF'
linha1
foo
bar
EOF

    local out
    out="$("${grep_bin}" 'foo' "${txt}" 2>/dev/null || true)"

    if echo "${out}" | grep -q 'foo'; then
        log_info "Grep: teste de busca simples OK (padrão 'foo' encontrado)."
    else
        log_error "Sanity-check Grep falhou: padrão 'foo' não encontrado em teste simples."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check Grep-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
