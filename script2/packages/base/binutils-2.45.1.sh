# /opt/adm/packages/base/binutils-2.45.1.sh
#
# Binutils-2.45.1 - conjunto de ferramentas de link/assemblador (final do sistema)
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - constrói em diretório "build" separado, no estilo LFS para binutils final
#   - configura com:
#       ../configure --prefix=/usr --sysconfdir=/etc \
#                    --enable-gold --enable-ld=default \
#                    --enable-plugins --enable-shared \
#                    --disable-werror --enable-64-bit-bfd \
#                    --build=$(../config.guess) \
#                    --host=$ADM_TARGET --target=$ADM_TARGET
#   - make tooldir=/usr
#   - make DESTDIR=${DESTDIR} tooldir=/usr install
#   - remove libs estáticas libbfd.a/libctf*.a/libopcodes.a em DESTDIR
#   - hooks de sanity-check no rootfs do profile (ld/as/objdump)

PKG_NAME="binutils"
PKG_VERSION="2.45.1"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/binutils/binutils-${PKG_VERSION}.tar.xz"
  "https://ftp.unicamp.br/pub/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="binutils-${PKG_VERSION}.tar.xz"

# Como 2.45.1 é nova, deixe SHA vazio enquanto não tiver o valor oficial.
# O adm apenas vai avisar e pular a verificação de checksum.
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas (ajuste os nomes conforme seus scripts de pacote)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
  "make-4.4.1"
)

# Nenhum patch externo por padrão
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
    # Binutils final do sistema, estilo LFS (adaptado):
    #
    #   mkdir -v build
    #   cd build
    #   ../configure --prefix=/usr --sysconfdir=/etc \
    #       --enable-gold --enable-ld=default \
    #       --enable-plugins --enable-shared \
    #       --disable-werror --enable-64-bit-bfd \
    #       --build=$(../config.guess) \
    #       --host=$ADM_TARGET --target=$ADM_TARGET
    #   make tooldir=/usr
    #
    # Aqui o adm já define CC/CFLAGS/LDFLAGS de acordo com o profile (glibc/musl).

    mkdir -pv build
    pushd build >/dev/null

    local build_triplet
    if [ -x "../config.guess" ]; then
        build_triplet="$(../config.guess)"
    else
        build_triplet="$(uname -m)-unknown-linux-gnu"
    fi

    ../configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --enable-gold \
        --enable-ld=default \
        --enable-plugins \
        --enable-shared \
        --disable-werror \
        --enable-64-bit-bfd \
        --build="${build_triplet}" \
        --host="${ADM_TARGET}" \
        --target="${ADM_TARGET}"

    # Compila binutils e ld com tooldir=/usr para não gerar /usr/${TARGET}/bin/*
    make tooldir=/usr

    popd >/dev/null
}

install_pkg() {
    # Instala a partir do diretório build em DESTDIR; o adm sincroniza depois
    pushd build >/dev/null

    make DESTDIR="${DESTDIR}" tooldir=/usr install

    popd >/dev/null

    # Remover libs estáticas de desenvolvimento que não devem ser linkadas por terceiros
    # (igual recomendação do LFS, mas aplicado dentro do DESTDIR)
    local dest_usr_lib="${DESTDIR}/usr/lib"
    if [ -d "${dest_usr_lib}" ]; then
        rm -fv "${dest_usr_lib}"/libbfd.a            2>/dev/null || true
        rm -fv "${dest_usr_lib}"/libctf.a           2>/dev/null || true
        rm -fv "${dest_usr_lib}"/libctf-nobfd.a     2>/dev/null || true
        rm -fv "${dest_usr_lib}"/libopcodes.a       2>/dev/null || true
    fi
}

post_install() {
    # Sanity-check Binutils final dentro do rootfs do profile:
    #
    # 1) ${ADM_SYSROOT}/usr/bin/ld é executável
    # 2) ${ADM_SYSROOT}/usr/bin/as é executável
    # 3) ld --version e as --version funcionam
    # 4) objdump -f em um binário ELF simples funciona (se existir)

    local usrbin="${ADM_SYSROOT}/usr/bin"
    local ld_bin="${usrbin}/ld"
    local as_bin="${usrbin}/as"
    local objdump_bin="${usrbin}/objdump"

    # ld
    if [ ! -x "${ld_bin}" ]; then
        log_error "Sanity-check Binutils falhou: ${ld_bin} não encontrado ou não executável."
        exit 1
    fi

    local ld_ver
    ld_ver="$("${ld_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ld_ver}" ]; then
        log_error "Sanity-check Binutils falhou: não foi possível obter versão de ${ld_bin}."
        exit 1
    fi
    log_info "Binutils: ld --version → ${ld_ver}"

    # as
    if [ ! -x "${as_bin}" ]; then
        log_error "Sanity-check Binutils falhou: ${as_bin} não encontrado ou não executável."
        exit 1
    fi

    local as_ver
    as_ver="$("${as_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${as_ver}" ]; then
        log_error "Sanity-check Binutils falhou: não foi possível obter versão de ${as_bin}."
        exit 1
    fi
    log_info "Binutils: as --version → ${as_ver}"

    # Teste opcional com objdump em algum ELF simples
    local candidate_elf=""
    if [ -x "${ADM_SYSROOT}/bin/sh" ]; then
        candidate_elf="${ADM_SYSROOT}/bin/sh"
    elif [ -x "${ADM_SYSROOT}/usr/bin/ls" ]; then
        candidate_elf="${ADM_SYSROOT}/usr/bin/ls"
    fi

    if [ -x "${objdump_bin}" ] && [ -n "${candidate_elf}" ]; then
        local out
        out="$("${objdump_bin}" -f "${candidate_elf}" 2>/dev/null || true)"
        if [ -z "${out}" ]; then
            log_warn "Binutils: objdump -f em ${candidate_elf} não produziu saída; verifique manualmente se necessário."
        else
            log_info "Binutils: objdump -f em ${candidate_elf} executado com sucesso."
        fi
    else
        log_warn "Binutils: objdump ou binário ELF de teste não encontrados; teste extra pulado."
    fi

    log_ok "Sanity-check Binutils-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
