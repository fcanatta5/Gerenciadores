# /opt/adm/packages/base/gawk-5.3.2.sh
#
# Gawk-5.3.2 - interpretador AWK GNU
#
# Integração com adm:
#   - usa cache de sources (PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256)
#   - segue o fluxo LFS Cap. 6 (ferramenta temporária / cross) adaptado:
#       sed -i 's/extras//' Makefile.in
#       ./configure --prefix=/usr --host=$ADM_TARGET --build=$(build-aux/config.guess)
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - cria manpage awk.1 -> gawk.1 em DESTDIR (como no Cap. 8 de LFS) 
#   - hooks de sanity-check no rootfs do profile

PKG_NAME="gawk"
PKG_VERSION="5.3.2"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/gawk/gawk-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/gawk/gawk-${PKG_VERSION}.tar.xz"
  "https://artfiles.org/gnu.org/gawk/gawk-${PKG_VERSION}.tar.xz"
  "https://sources.voidlinux.org/gawk-5.3.2/gawk-5.3.2.tar.xz"
)

PKG_TARBALL="gawk-${PKG_VERSION}.tar.xz"

# SHA256 do gawk-5.3.2.tar.xz (Buildroot/Nix/Fossies) 
PKG_SHA256="f8c3486509de705192138b00ef2c00bbbdd0e84c30d5c07d23fc73a9dc4cc9cc"

# Dependências lógicas (ajuste os nomes conforme seus outros scripts)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
)

# Não há patch padrão em LFS para Gawk-5.3.2
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Apenas loga o toolchain disponível (se estiver usando /tools, etc.)
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Conforme LFS 6.9 (Cross Compiling Temporary Tools), adaptado:
    #
    #   sed -i 's/extras//' Makefile.in
    #   ./configure --prefix=/usr   \
    #               --host=$LFS_TGT \
    #               --build=$(build-aux/config.guess)
    #   make
    #
    # Mapas:
    #   LFS_TGT -> ADM_TARGET
    #   DESTDIR -> gerenciado pelo adm (adm faz rsync para ADM_SYSROOT) 

    # Evitar instalar "extras" desnecessários
    sed -i 's/extras//' Makefile.in

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

    # A instalação já cria /usr/bin/awk como symlink para gawk.
    # Criamos também a manpage awk.1 -> gawk.1 dentro do DESTDIR,
    # como recomendado em LFS (Cap. 8.63). 
    local man1_dir="${DESTDIR}/usr/share/man/man1"
    mkdir -pv "${man1_dir}"

    if [ ! -e "${man1_dir}/awk.1" ]; then
        ln -sv gawk.1 "${man1_dir}/awk.1"
    fi

    # (Opcional) Instala documentação em DESTDIR para ser gerenciada pelo manifest
    # Se não quiser docs, pode comentar este bloco.
    if [ -d "doc" ]; then
        install -vDm644 doc/{awkforai.txt,*.{eps,pdf,jpg}} \
            -t "${DESTDIR}/usr/share/doc/gawk-${PKG_VERSION}" || true
    fi
}

post_install() {
    # Sanity-check Gawk dentro do rootfs do profile:
    #
    # 1) ${ADM_SYSROOT}/usr/bin/gawk existe e é executável
    # 2) gawk --version funciona
    # 3) awk existe (symlink para gawk) e executa um script simples
    # 4) manpage awk.1 -> gawk.1 está presente

    local usrbin="${ADM_SYSROOT}/usr/bin"
    local man1="${ADM_SYSROOT}/usr/share/man/man1"
    local gawk_bin="${usrbin}/gawk"
    local awk_bin="${usrbin}/awk"

    # gawk binário
    if [ ! -x "${gawk_bin}" ]; then
        log_error "Sanity-check Gawk falhou: ${gawk_bin} não encontrado ou não executável."
        exit 1
    fi

    local ver
    ver="$("${gawk_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Gawk falhou: não foi possível obter versão de ${gawk_bin}."
        exit 1
    fi
    log_info "Gawk: gawk --version → ${ver}"

    # awk (symlink ou binário)
    if [ ! -x "${awk_bin}" ]; then
        log_warn "Gawk: ${awk_bin} não encontrado ou não executável. Esperado symlink para gawk."
    else
        # Teste simples com awk: imprimir "ok" via BEGIN
        local out
        out="$("${awk_bin}" 'BEGIN { print \"ok\" }' 2>/dev/null || true)"
        if [ "${out}" != "ok" ]; then
            log_warn "Gawk: teste simples com awk retornou '${out}', esperado 'ok'."
        else
            log_info "Gawk: teste simples com awk OK."
        fi
    fi

    # Manpage awk.1 -> gawk.1
    local awk_man="${man1}/awk.1"
    if [ -L "${awk_man}" ] || [ -f "${awk_man}" ]; then
        log_info "Gawk: manpage awk.1 presente em ${awk_man}."
    else
        log_warn "Gawk: manpage awk.1 não encontrada em ${awk_man}. Verifique se a criação no install_pkg() foi executada."
    fi

    log_ok "Sanity-check Gawk-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
