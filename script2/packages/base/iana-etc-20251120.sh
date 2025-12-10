# /opt/adm/packages/base/iana-etc-20251120.sh
#
# Iana-Etc-20251120 - arquivos /etc/protocols e /etc/services da IANA
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - não possui ./configure nem make de verdade: apenas arquivos texto
#   - fluxo estilo LFS:
#       (nenhum build; apenas copiar arquivos para /etc)
#   - instala em ${ADM_SYSROOT}/etc via DESTDIR
#   - hooks de sanity-check no rootfs (services, protocols existem e não estão vazios)

PKG_NAME="iana-etc"
PKG_VERSION="20251120"
PKG_CATEGORY="base"

# Fontes (ajuste as URLs conforme o mirror que você usar)
PKG_SOURCE_URLS=(
  "https://www.example.org/iana-etc/iana-etc-${PKG_VERSION}.tar.xz"
  "https://anduin.linuxfromscratch.org/BLFS/iana-etc/iana-etc-${PKG_VERSION}.tar.xz"
)

# Se o tarball real for .tar.gz, basta ajustar aqui
PKG_TARBALL="iana-etc-${PKG_VERSION}.tar.xz"

# Preencha depois com o SHA256 oficial; enquanto vazio, o adm só avisa.
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas mínimas
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
)

PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Iana-Etc não precisa de build: o tarball contém basicamente
    # os arquivos "services" e "protocols" já prontos.
    #
    # Mantemos a função build() apenas para alinhar com o adm.
    log_info "Iana-Etc: nenhum passo de compilação necessário, apenas instalação."
}

install_pkg() {
    # Instala em DESTDIR; o adm faz o sync DESTDIR -> ${ADM_SYSROOT}
    #
    # Estrutura típica do tarball:
    #   ./services
    #   ./protocols
    #
    # Copiamos para ${DESTDIR}/etc/

    local etcdir="${DESTDIR}/etc"
    mkdir -pv "${etcdir}"

    if [ -f "./services" ]; then
        install -m 0644 "./services"   "${etcdir}/services"
    else
        log_error "Iana-Etc: arquivo 'services' não encontrado no source dir."
        exit 1
    fi

    if [ -f "./protocols" ]; then
        install -m 0644 "./protocols"  "${etcdir}/protocols"
    else
        log_error "Iana-Etc: arquivo 'protocols' não encontrado no source dir."
        exit 1
    fi
}

post_install() {
    # Sanity-check Iana-Etc dentro do rootfs do profile:
    #
    # 1) verificar se ${ADM_SYSROOT}/etc/services e protocols existem
    # 2) verificar se não estão vazios (têm pelo menos algumas linhas)
    #

    local services="${ADM_SYSROOT}/etc/services"
    local protocols="${ADM_SYSROOT}/etc/protocols"

    local ok=1

    if [ ! -f "${services}" ]; then
        log_error "Sanity-check Iana-Etc falhou: ${services} não existe."
        ok=0
    else
        # pelo menos 10 linhas como sanity básico
        local n
        n="$(wc -l < "${services}" 2>/dev/null || echo 0)"
        if [ "${n}" -lt 10 ]; then
            log_warn "Iana-Etc: ${services} possui poucas linhas (${n}); verifique o conteúdo."
        else
            log_info "Iana-Etc: ${services} possui ${n} linhas."
        fi
    fi

    if [ ! -f "${protocols}" ]; then
        log_error "Sanity-check Iana-Etc falhou: ${protocols} não existe."
        ok=0
    else
        local n
        n="$(wc -l < "${protocols}" 2>/dev/null || echo 0)"
        if [ "${n}" -lt 10 ]; then
            log_warn "Iana-Etc: ${protocols} possui poucas linhas (${n}); verifique o conteúdo."
        else
            log_info "Iana-Etc: ${protocols} possui ${n} linhas."
        fi
    fi

    if [ "${ok}" -ne 1 ]; then
        log_error "Sanity-check Iana-Etc-${PKG_VERSION} falhou em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
        exit 1
    fi

    log_ok "Sanity-check Iana-Etc-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
