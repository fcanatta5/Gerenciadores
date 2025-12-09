# /opt/adm/packages/base/coreutils-9.9.sh
#
# Coreutils-9.9 - pacote base de utilitários GNU
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_MD5 para cache de source
#   - usa PKG_PATCH_URLS para o patch i18n do LFS (aplicado automaticamente)
#   - constrói no srcdir com autoreconf + automake + configure (como LFS 8.61)
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - move chroot e manpage para locais FHS em DESTDIR
#   - sanity-check em post_install() dentro do rootfs do profile

PKG_NAME="coreutils"
PKG_VERSION="9.9"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/coreutils/coreutils-${PKG_VERSION}.tar.xz"
  "https://ftp.unicamp.br/pub/gnu/coreutils/coreutils-${PKG_VERSION}.tar.xz"
  "https://ftp.wayne.edu/gnu/coreutils/coreutils-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="coreutils-${PKG_VERSION}.tar.xz"

# LFS fornece o MD5 do tarball 9.9 
PKG_MD5="ce613d0dae179f4171966ecd0a898ec4"

# Dependências lógicas (ajuste os nomes conforme os scripts do seu tree)
PKG_DEPENDS=(
  "glibc-pass1"   # ou glibc final, conforme seu naming
  "bash-5.3"
  "ncurses-6.5"
)

# Patch i18n oficial do LFS para Coreutils-9.9 (opcional, mas já integrado)
# Ele será baixado e aplicado automaticamente via ensure_patches_downloaded/apply_patches
# Obs: sem checksum aqui; o adm só irá emitir warning, mas funcionará. 
PKG_PATCH_URLS=(
  "https://www.linuxfromscratch.org/patches/lfs/development/coreutils-9.9-i18n-1.patch"
)
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Apenas log informativo sobre toolchain
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Padrão LFS 8.61, adaptado para o adm:
    #
    #   (patch i18n é aplicado pelo adm via PKG_PATCH_URLS + apply_patches)
    #
    #   autoreconf -fv
    #   automake -af
    #   FORCE_UNSAFE_CONFIGURE=1 ./configure \
    #       --prefix=/usr \
    #       --enable-no-install-program=kill,uptime
    #   make
    #
    # FORCE_UNSAFE_CONFIGURE=1 é necessário quando se compila como root. 

    autoreconf -fv
    automake -af

    FORCE_UNSAFE_CONFIGURE=1 \
    ./configure \
        --prefix=/usr \
        --enable-no-install-program=kill,uptime

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm faz o rsync para ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Ajustes FHS no DESTDIR (como em LFS, mas dentro do rootfs do profile) 
    local dest_root="${DESTDIR}"
    local dest_usr_bin="${dest_root}/usr/bin"
    local dest_usr_sbin="${dest_root}/usr/sbin"
    local dest_man1="${dest_root}/usr/share/man/man1"
    local dest_man8="${dest_root}/usr/share/man/man8"

    mkdir -pv "${dest_usr_sbin}" "${dest_man8}"

    # mover chroot para /usr/sbin
    if [ -x "${dest_usr_bin}/chroot" ]; then
        mv -v "${dest_usr_bin}/chroot" "${dest_usr_sbin}/chroot"
    else
        log_warn "coreutils: /usr/bin/chroot não encontrado em DESTDIR; não movido para /usr/sbin."
    fi

    # mover manpage chroot.1 → chroot.8
    if [ -f "${dest_man1}/chroot.1" ]; then
        mv -v "${dest_man1}/chroot.1" "${dest_man8}/chroot.8"
        sed -i 's/"1"/"8"/' "${dest_man8}/chroot.8"
    else
        log_warn "coreutils: manpage chroot.1 não encontrada em DESTDIR; não movida para seção 8."
    fi

    # Se você quiser, aqui é o lugar para mover binários críticos para /bin
    # (cp, mv, rm, mkdir, ln, etc.) conforme a política do seu sistema.
    #
    # Exemplo (descomentando, se desejar):
    #
    # local dest_bin="${dest_root}/bin"
    # mkdir -pv "${dest_bin}"
    # local prog
    # for prog in cp mv rm mkdir ln chmod chown chgrp; do
    #     if [ -x "${dest_usr_bin}/${prog}" ]; then
    #         mv -v "${dest_usr_bin}/${prog}" "${dest_bin}/${prog}"
    #         ln -sfv "../bin/${prog}" "${dest_usr_bin}/${prog}"
    #     fi
    # done
}

post_install() {
    # Sanity-check Coreutils dentro do rootfs do profile:
    #
    # 1) /usr/bin/ls existe e é executável
    # 2) /usr/bin/ls --version funciona
    # 3) chroot foi movido para /usr/sbin
    # 4) manpage chroot.8 existe

    local usrlib="${ADM_SYSROOT}/usr/lib"
    local usrbin="${ADM_SYSROOT}/usr/bin"
    local usrsbin="${ADM_SYSROOT}/usr/sbin"
    local man1="${ADM_SYSROOT}/usr/share/man/man1"
    local man8="${ADM_SYSROOT}/usr/share/man/man8"

    # ls
    local ls_bin="${usrbin}/ls"
    if [ ! -x "${ls_bin}" ]; then
        log_error "Sanity-check Coreutils falhou: ${ls_bin} não encontrado ou não executável."
        exit 1
    fi

    local ver
    ver="$("${ls_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Coreutils falhou: não foi possível obter versão de ${ls_bin}."
        exit 1
    fi
    log_info "Coreutils: ls --version → ${ver}"

    # chroot
    local chroot_bin="${usrsbin}/chroot"
    if [ ! -x "${chroot_bin}" ]; then
        log_warn "Coreutils: ${chroot_bin} não encontrado; verifique se o move para /usr/sbin foi feito corretamente."
    else
        log_info "Coreutils: chroot encontrado em ${chroot_bin}"
    fi

    # manpages
    if [ -f "${man1}/chroot.1" ]; then
        log_warn "Coreutils: manpage chroot.1 ainda existe em man1; esperado somente em man8."
    fi
    if [ -f "${man8}/chroot.8" ]; then
        log_info "Coreutils: manpage chroot.8 presente em man8."
    else
        log_warn "Coreutils: manpage chroot.8 não encontrada em man8."
    fi

    # Teste simples de um utilitário extra (por exemplo, `printf`)
    local printf_bin="${usrbin}/printf"
    if [ -x "${printf_bin}" ]; then
        local out
        out="$("${printf_bin}" 'ok\n' 2>/dev/null || true)"
        if [ "${out}" != "ok" ]; then
            log_warn "Coreutils: teste simples com printf retornou '${out}', esperado 'ok'."
        else
            log_info "Coreutils: teste simples com printf OK."
        fi
    else
        log_warn "Coreutils: /usr/bin/printf não encontrado; teste extra pulado."
    fi

    log_ok "Sanity-check Coreutils-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
