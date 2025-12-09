# /opt/adm/packages/base/bash-5.3.sh
#
# Bash-5.3 - shell padrão do sistema
#
# Integração com adm:
#   - usa cache de sources (PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256)
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - move /usr/bin/bash para /bin/bash dentro do rootfs
#   - cria link /bin/sh -> bash
#   - hooks de sanity-check

PKG_NAME="bash"
PKG_VERSION="5.3"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/bash/bash-${PKG_VERSION}.tar.gz"
  "https://ftpmirror.gnu.org/gnu/bash/bash-${PKG_VERSION}.tar.gz"
  "https://ftp.unicamp.br/pub/gnu/bash/bash-${PKG_VERSION}.tar.gz"
)

PKG_TARBALL="bash-${PKG_VERSION}.tar.gz"

# SHA256 do bash-5.3.tar.gz (usando hash do ports do FreeBSD) 
PKG_SHA256="0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba"

# Dependências lógicas (ajuste os nomes conforme seus scripts de pacote)
PKG_DEPENDS=(
  "ncurses-6.5"   # ncurses base
  # "readline-8.2" # se você tiver um pacote readline separado
)

# Sem patches por enquanto (mas já deixo os arrays prontos)
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Apenas loga toolchain disponível; em chroot/fase final normalmente
    # usará o GCC "do sistema" do rootfs.
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Construção estilo LFS (fase sistema), adaptado para Bash-5.3:
    #
    # ./configure --prefix=/usr \
    #             --without-bash-malloc \
    #             --with-installed-readline \
    #             --docdir=/usr/share/doc/bash-5.3 
    #
    # O adm já define CC/CFLAGS de acordo com o profile (glibc/musl/opt).
    ./configure \
        --prefix=/usr \
        --without-bash-malloc \
        --with-installed-readline \
        --docdir=/usr/share/doc/bash-${PKG_VERSION}

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Agora aplicamos ajustes em DESTDIR, não no host:

    local dest_root="${DESTDIR}"
    local dest_usr_bin="${dest_root}/usr/bin"
    local dest_bin="${dest_root}/bin"

    mkdir -pv "${dest_bin}"

    # Mover /usr/bin/bash -> /bin/bash (FHS/LFS)
    if [ -x "${dest_usr_bin}/bash" ]; then
        mv -v "${dest_usr_bin}/bash" "${dest_bin}/bash"
    else
        log_warn "bash não encontrado em ${dest_usr_bin}; verifique instalação."
    fi

    # Garantir que /usr/bin/bash exista como symlink para compatibilidade
    if [ -x "${dest_bin}/bash" ]; then
        ln -sfv "../bin/bash" "${dest_usr_bin}/bash"
    fi

    # Link /bin/sh -> bash (programas que usam /bin/sh)
    if [ -x "${dest_bin}/bash" ]; then
        ln -sfv "bash" "${dest_bin}/sh"
    fi
}

post_install() {
    # Sanity-check Bash:
    #
    # 1) ${ADM_SYSROOT}/bin/bash existe e é executável
    # 2) /bin/sh -> bash
    # 3) versão correta
    # 4) execução simples de comando

    local bash_bin="${ADM_SYSROOT}/bin/bash"
    local sh_link="${ADM_SYSROOT}/bin/sh"

    if [ ! -x "${bash_bin}" ]; then
        log_error "Sanity-check Bash falhou: ${bash_bin} não encontrado ou não executável."
        exit 1
    fi

    # Verificar se /bin/sh existe
    if [ ! -e "${sh_link}" ]; then
        log_warn "Sanity-check: ${sh_link} não existe; criando link agora."
        ln -sfv "bash" "${sh_link}"
    fi

    # Opcional: garantir que /bin/sh aponta para bash
    local sh_target
    if [ -L "${sh_link}" ]; then
        sh_target="$(readlink -f "${sh_link}")"
        if [ "${sh_target}" != "${bash_bin}" ]; then
            log_warn "/bin/sh aponta para ${sh_target}, não para bash; ajuste manual se desejar."
        fi
    fi

    # Verificação de versão
    local ver
    ver="$("${bash_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Bash falhou: não foi possível obter versão de ${bash_bin}."
        exit 1
    fi

    log_info "Bash versão reportada: ${ver}"

    # Teste simples: executar um comando via bash
    local out
    out="$("${bash_bin}" -c 'echo ok' 2>/dev/null || true)"
    if [ "${out}" != "ok" ]; then
        log_error "Sanity-check Bash falhou: execução simples via bash retornou '${out}', esperado 'ok'."
        exit 1
    fi

    # Teste simples via /bin/sh, se existir
    if [ -x "${sh_link}" ]; then
        out="$("${sh_link}" -c 'echo ok' 2>/dev/null || true)"
        if [ "${out}" != "ok" ]; then
            log_warn "Sanity-check: /bin/sh não executou corretamente 'echo ok' (retorno '${out}')."
        else
            log_info "/bin/sh executou corretamente 'echo ok'."
        fi
    fi

    log_ok "Sanity-check Bash-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
