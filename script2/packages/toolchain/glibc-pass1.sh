# /opt/adm/packages/toolchain/glibc-pass1.sh
#
# Glibc-2.42 - Pass 1
# Construída com o cross-toolchain em /tools, instalada em ${ADM_SYSROOT}/usr,
# usando Linux-6.17.9 API Headers e integrada ao TARGET=${ADM_TARGET}.
#

PKG_NAME="glibc-pass1"
PKG_VERSION="2.42"
PKG_CATEGORY="toolchain"

# Fonte principal (múltiplos mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/glibc/glibc-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/glibc/glibc-${PKG_VERSION}.tar.xz"
)

# Nome do tarball no cache do adm
PKG_TARBALL="glibc-${PKG_VERSION}.tar.xz"

# Deixe vazio se não tiver o hash ainda (o adm só avisa e segue)
PKG_SHA256=""
PKG_MD5=""

# Se quiser, você pode travar depois com:
# PKG_SHA256="0c83c27e4c0aa0b0e8e3cd44e4a09f7f3f0b2d4b8d3b9f0b7f9ad..."  # exemplo

# Dependências lógicas
PKG_DEPENDS=(
  "linux-headers"   # usa ${ADM_SYSROOT}/usr/include
  "binutils-pass1"
  "gcc-pass1"
)

# Patch FHS do LFS (opcional, mas recomendado)
PKG_PATCH_URLS=(
  "https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4/glibc-2.42-fhs-1.patch"
)
PKG_PATCH_SHA256=(
  "0e98bb64d18b96ba6a69f5a6545edc53c440183675682547909c096f66e3b81c"
)

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

# Antes de configurar/compilar:
# - garante que o cross-toolchain em /tools/bin está na frente no PATH
pre_build() {
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        export PATH="${tools_bin}:${PATH}"
        log_info "PATH ajustado para usar cross-toolchain em ${tools_bin}"
    else
        log_warn "Diretório ${tools_bin} não existe; assumindo que ${ADM_TARGET}-gcc está no PATH."
    fi

    # Para reduzir ruído de testes em configure da glibc (mesmo em pass1)
    export LC_ALL=C
}

build() {
    # Estamos no diretório do source glibc-2.42/
    # Construção fora da árvore (build dir separado)
    mkdir -v build
    cd build

    local build_triplet
    build_triplet="$(../scripts/config.guess)"

    # Configure baseado em LFS, adaptado para o seu ADM:
    ../configure \
        --prefix=/usr \
        --host="${ADM_TARGET}" \
        --build="${build_triplet}" \
        --enable-kernel=4.19 \
        --with-headers="${ADM_SYSROOT}/usr/include" \
        --disable-werror \
        libc_cv_slibdir=/usr/lib

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm sincroniza para ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Ajustes mínimos pós-instalação (estilo LFS) podem ser feitos aqui,
    # mas em pass1 vamos manter só o essencial para toolchain funcionar.
    #
    # Ex.: criação de /etc/ld.so.conf no SYSROOT, se você quiser:
    #
    # local etc_dir="${DESTDIR}/etc"
    # mkdir -pv "${etc_dir}"
    # cat > "${etc_dir}/ld.so.conf" << 'EOF'
    # /usr/local/lib
    # /usr/lib
    # /lib
    # EOF
}

post_install() {
    # Sanity-check Glibc Pass 1:
    #
    # 1. Headers fundamentais em ${ADM_SYSROOT}/usr/include
    # 2. Presença de libc.so.6 em algum lugar razoável
    # 3. Compilação de um programa dummy com o cross-GCC usando o SYSROOT

    local include_dir="${ADM_SYSROOT}/usr/include"
    local stdio_h="${include_dir}/stdio.h"

    if [ ! -d "${include_dir}" ]; then
        log_error "Sanity-check Glibc Pass 1 falhou: diretório ${include_dir} não existe."
        exit 1
    fi

    if [ ! -f "${stdio_h}" ]; then
        log_error "Sanity-check Glibc Pass 1 falhou: ${stdio_h} não encontrado."
        exit 1
    fi

    # Procurar uma libc.so.6 dentro do SYSROOT
    local libc_so
    libc_so="$(find "${ADM_SYSROOT}" -maxdepth 6 -type f -name 'libc.so.6' 2>/dev/null | head -n1 || true)"

    if [ -z "${libc_so}" ]; then
        log_error "Sanity-check Glibc Pass 1 falhou: libc.so.6 não encontrada em ${ADM_SYSROOT}."
        exit 1
    fi

    log_info "Glibc Pass 1: libc.so.6 encontrada em ${libc_so}"

    # Tentar compilar um dummy.c com o cross-GCC apontando para o SYSROOT
    local cc_tools="${ADM_SYSROOT}/tools/bin/${ADM_TARGET}-gcc"
    local cc="${cc_tools}"

    if [ ! -x "${cc}" ]; then
        # fallback: talvez o cross esteja em outro lugar no PATH
        cc="$(command -v "${ADM_TARGET}-gcc" || true)"
    fi

    if [ -z "${cc}" ] || [ ! -x "${cc}" ]; then
        log_warn "Sanity-check: não foi possível localizar ${ADM_TARGET}-gcc; pulando teste de compilação."
        log_ok "Sanity-check parcial Glibc Pass 1 OK (headers + libc.so.6 presentes)."
        return 0
    fi

    log_info "Usando compilador para sanity-check: ${cc}"

    local tmpdir
    tmpdir="$(mktemp -d)"
    cat > "${tmpdir}/dummy.c" << 'EOF'
#include <stdio.h>
int main(void) {
    printf("glibc dummy test\n");
    return 0;
}
EOF

    if ! "${cc}" --sysroot="${ADM_SYSROOT}" -o "${tmpdir}/dummy" "${tmpdir}/dummy.c"; then
        log_error "Sanity-check Glibc Pass 1 falhou: não foi possível compilar dummy.c com ${cc} usando SYSROOT=${ADM_SYSROOT}."
        rm -rf "${tmpdir}"
        exit 1
    fi

    # Não tentamos executar o binário aqui (pode ser rootfs diferente/montado)
    if [ ! -f "${tmpdir}/dummy" ]; then
        log_error "Sanity-check Glibc Pass 1 falhou: dummy não foi gerado."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check Glibc Pass 1 OK para TARGET=${ADM_TARGET}, profile=${ADM_PROFILE}."
}
