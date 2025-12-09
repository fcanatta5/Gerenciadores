# /opt/adm/packages/base/file-5.46.sh
#
# File-5.46 - utilitário 'file' e biblioteca libmagic
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_MD5 para cache de source
#   - segue o fluxo LFS 6.7 (build temporário em ./build + build cross principal)
#   - usa ADM_TARGET como --host (cross temporário ou profile musl/glibc)
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - remove libmagic.la (ruim para cross) ainda em DESTDIR
#   - hooks de sanity-check no rootfs do profile

PKG_NAME="file"
PKG_VERSION="5.46"
PKG_CATEGORY="base"

# Fontes oficiais (astron + mirrors)
PKG_SOURCE_URLS=(
  "https://astron.com/pub/file/file-${PKG_VERSION}.tar.gz"
  "ftp://ftp.astron.com/pub/file/file-${PKG_VERSION}.tar.gz"
  "http://ftp.astron.com/pub/file/file-${PKG_VERSION}.tar.gz"
  "https://fossies.org/linux/misc/file-${PKG_VERSION}.tar.gz"
)

PKG_TARBALL="file-${PKG_VERSION}.tar.gz"

# MD5 do tarball (LFS 12.3 / 12.4-systemd) 
PKG_MD5="459da2d4b534801e2e2861611d823864"

# Dependências lógicas (ajuste nomes conforme seus outros scripts)
PKG_DEPENDS=(
  "coreutils-9.9"
  "bash-5.3"
)

# Não há patch padrão para File-5.46 em LFS
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Log de contexto do toolchain
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional encontrado em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Conforme LFS 6.7.1:
    #
    #   mkdir build
    #   pushd build
    #     ../configure --disable-bzlib      \
    #                  --disable-libseccomp \
    #                  --disable-xzlib      \
    #                  --disable-zlib
    #     make
    #   popd
    #
    #   ./configure --prefix=/usr --host=$LFS_TGT --build=$(./config.guess)
    #   make FILE_COMPILE=$(pwd)/build/src/file
    #
    # Mapas:
    #   LFS_TGT -> ADM_TARGET
    #   DESTDIR=$LFS -> DESTDIR do adm (adm faz rsync para ADM_SYSROOT) 

    # 1) Build temporário do 'file' nativo do host
    mkdir -pv build
    pushd build >/dev/null

    ../configure \
        --disable-bzlib      \
        --disable-libseccomp \
        --disable-xzlib      \
        --disable-zlib

    make

    popd >/dev/null

    # 2) Build principal (cross/target) usando o 'file' recém-compilado
    local build_triplet
    build_triplet="$(./config.guess)"

    ./configure \
        --prefix=/usr           \
        --host="${ADM_TARGET}"  \
        --build="${build_triplet}"

    make FILE_COMPILE="$(pwd)/build/src/file"
}

install_pkg() {
    # Instala em DESTDIR; o adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # LFS remove libmagic.la por ser prejudicial em cenários cross: 
    local la="${DESTDIR}/usr/lib/libmagic.la"
    if [ -f "${la}" ]; then
        rm -v "${la}"
    fi
}

post_install() {
    # Sanity-check File:
    #
    # 1) ${ADM_SYSROOT}/usr/bin/file existe e é executável
    # 2) file --version funciona
    # 3) file identifica corretamente um arquivo texto simples
    # 4) se existir um binário ELF básico no rootfs, tentar identificá-lo

    local usrbin="${ADM_SYSROOT}/usr/bin"
    local file_bin="${usrbin}/file"

    if [ ! -x "${file_bin}" ]; then
        log_error "Sanity-check File falhou: ${file_bin} não encontrado ou não executável."
        exit 1
    fi

    # Versão
    local ver
    ver="$("${file_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check File falhou: não foi possível obter versão de ${file_bin}."
        exit 1
    fi
    log_info "File: file --version → ${ver}"

    # Teste com arquivo texto
    local tmpdir
    tmpdir="$(mktemp -d)"
    local txt="${tmpdir}/teste.txt"

    printf 'conteudo simples de texto\n' > "${txt}"

    local out_txt
    out_txt="$("${file_bin}" "${txt}" 2>/dev/null || true)"

    if [ -z "${out_txt}" ]; then
        log_warn "File: saída vazia ao analisar arquivo texto de teste (${txt})."
    else
        log_info "File: análise de arquivo texto → ${out_txt}"
        case "${out_txt}" in
            *text*|*ASCII*|*UTF-8*)
                log_info "File: identificação de arquivo texto parece correta."
                ;;
            *)
                log_warn "File: saída não contém 'text/ASCII/UTF-8', verifique se o magicDB está OK."
                ;;
        esac
    fi

    # Teste opcional com algum ELF (se existir)
    local candidate_elf=""
    if [ -x "${ADM_SYSROOT}/bin/sh" ]; then
        candidate_elf="${ADM_SYSROOT}/bin/sh"
    elif [ -x "${ADM_SYSROOT}/usr/bin/ls" ]; then
        candidate_elf="${ADM_SYSROOT}/usr/bin/ls"
    fi

    if [ -n "${candidate_elf}" ]; then
        local out_elf
        out_elf="$("${file_bin}" "${candidate_elf}" 2>/dev/null || true)"
        if [ -z "${out_elf}" ]; then
            log_warn "File: saída vazia ao analisar ELF de teste (${candidate_elf})."
        else
            log_info "File: análise de ELF (${candidate_elf}) → ${out_elf}"
        fi
    else
        log_warn "File: nenhum ELF simples encontrado em ${ADM_SYSROOT}/bin/sh ou /usr/bin/ls para teste extra."
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check File-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
