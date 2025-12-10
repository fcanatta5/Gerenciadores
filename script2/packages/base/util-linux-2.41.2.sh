# /opt/adm/packages/base/util-linux-2.41.2.sh
#
# Util-linux-2.41.2 - conjunto de utilitários de baixo nível do sistema
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - constrói em /usr do rootfs do profile (glibc ou musl)
#   - fluxo estilo LFS adaptado ao seu esquema:
#       ./configure --prefix=/usr --libdir=/usr/lib \
#                   --runstatedir=/run \
#                   --disable-static \
#                   --disable-chfn-chsh \
#                   --disable-login \
#                   --disable-nologin \
#                   --disable-su \
#                   --disable-setpriv \
#                   --disable-runuser \
#                   --disable-pylibmount \
#                   --without-python \
#                   --without-systemd \
#                   --without-systemdsystemunitdir \
#                   --host=$ADM_TARGET --build=$(config.guess)
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs (lsblk, blkid, fdisk, etc.)

PKG_NAME="util-linux"
PKG_VERSION="2.41.2"
PKG_CATEGORY="base"

# Fontes oficiais (kernel.org + mirrors)
PKG_SOURCE_URLS=(
  "https://www.kernel.org/pub/linux/utils/util-linux/v2.41/util-linux-${PKG_VERSION}.tar.xz"
  "https://mirrors.edge.kernel.org/pub/linux/utils/util-linux/v2.41/util-linux-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="util-linux-${PKG_VERSION}.tar.xz"

# Preencha depois com o SHA256 oficial se quiser verificação forte.
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas (nomes alinhados com os outros scripts)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
  "sed-4.9"
  "grep-3.12"
  "gawk-5.3.2"
  "make-4.4.1"
  "gettext-0.26"
)

PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# Se precisar de patches locais:
# PKG_PATCHES=("/opt/adm/patches/util-linux-2.41.2-foo.patch")

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
    # Build final do util-linux, desativando utilitários que conflitam
    # com outros pacotes (login, su, etc.) e recursos que dependem de
    # systemd/python.
    #
    # Em chroot: build == host == target; fora do chroot ainda passamos
    # --build/--host coerentes.

    local build_triplet

    if [ -x "./config.guess" ]; then
        build_triplet="$(./config.guess)"
    else
        build_triplet="$(uname -m)-unknown-linux-gnu"
    fi

    ./configure \
        --prefix=/usr \
        --libdir=/usr/lib \
        --runstatedir=/run \
        --host="${ADM_TARGET}" \
        --build="${build_triplet}" \
        --disable-static \
        --disable-chfn-chsh \
        --disable-login \
        --disable-nologin \
        --disable-su \
        --disable-setpriv \
        --disable-runuser \
        --disable-pylibmount \
        --without-python \
        --without-systemd \
        --without-systemdsystemunitdir

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm sincroniza DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Em algumas configs, util-linux instala libs em /usr/lib64; aqui,
    # como já passamos --libdir=/usr/lib, isso deve estar alinhado.
    # Se quiser tratar lib64 separado, pode ajustar aqui.
}

post_install() {
    # Sanity-check util-linux dentro do rootfs do profile:
    #
    # Verificamos a presença e funcionamento básico de:
    #   - lsblk
    #   - blkid
    #   - fdisk
    #   - mount (opcional)
    #
    # Testes são apenas de --version ou operações que não tocam discos.

    local usrbin="${ADM_SYSROOT}/usr/bin"
    local sbin="${ADM_SYSROOT}/usr/sbin"
    local bin_lsblk="${usrbin}/lsblk"
    local bin_blkid="${usrbin}/blkid"
    local bin_fdisk="${usrbin}/fdisk"
    local bin_mount="${usrbin}/mount"

    # lsblk
    if [ ! -x "${bin_lsblk}" ]; then
        log_error "Sanity-check util-linux falhou: lsblk não encontrado em ${bin_lsblk}."
        exit 1
    fi
    local lsblk_ver
    lsblk_ver="$("${bin_lsblk}" --version 2>/dev/null || true)"
    if [ -z "${lsblk_ver}" ]; then
        log_error "Sanity-check util-linux falhou: não foi possível obter versão de lsblk."
        exit 1
    fi
    log_info "util-linux: lsblk --version → ${lsblk_ver}"

    # blkid
    if [ ! -x "${bin_blkid}" ]; then
        log_error "Sanity-check util-linux falhou: blkid não encontrado em ${bin_blkid}."
        exit 1
    fi
    local blkid_ver
    blkid_ver="$("${bin_blkid}" -V 2>/dev/null || true)"
    if [ -z "${blkid_ver}" ]; then
        log_error "Sanity-check util-linux falhou: não foi possível obter versão de blkid."
        exit 1
    fi
    log_info "util-linux: blkid -V → ${blkid_ver}"

    # fdisk
    if [ ! -x "${bin_fdisk}" ]; then
        log_error "Sanity-check util-linux falhou: fdisk não encontrado em ${bin_fdisk}."
        exit 1
    fi
    local fdisk_ver
    fdisk_ver="$("${bin_fdisk}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${fdisk_ver}" ]; then
        log_error "Sanity-check util-linux falhou: não foi possível obter versão de fdisk."
        exit 1
    fi
    log_info "util-linux: fdisk --version → ${fdisk_ver}"

    # mount (nem sempre necessário, mas provavelmente existe)
    if [ -x "${bin_mount}" ]; then
        local mount_ver
        mount_ver="$("${bin_mount}" --version 2>/dev/null | head -n1 || true)"
        if [ -n "${mount_ver}" ]; then
            log_info "util-linux: mount --version → ${mount_ver}"
        else
            log_warn "util-linux: mount existe mas não retornou versão clara."
        fi
    else
        log_warn "util-linux: mount não encontrado em ${bin_mount}; verifique se está sendo fornecido por outro pacote."
    fi

    log_ok "Sanity-check util-linux-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
