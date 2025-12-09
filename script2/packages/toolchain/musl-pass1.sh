# /opt/adm/packages/toolchain/musl-pass1.sh
#
# musl-1.2.5 - Pass 1
#
# - constrói a libc musl para TARGET=${ADM_TARGET}
# - usa o toolchain cross em ${ADM_SYSROOT}/tools
# - instala no SYSROOT (${ADM_SYSROOT}) via DESTDIR
# - aplica 2 patches de segurança para CVE-2025-26519 (iconv/EUC-KR) 
#

PKG_NAME="musl-pass1"
PKG_VERSION="1.2.5"
PKG_CATEGORY="toolchain"

# Fonte principal (múltiplos mirrors / upstream)
PKG_SOURCE_URLS=(
  "https://git.musl-libc.org/cgit/musl/snapshot/musl-${PKG_VERSION}.tar.gz"
  "https://launchpad.net/debian/+source/musl/1.2.5-1/+files/musl_${PKG_VERSION}.orig.tar.gz"
)

# Nome do tarball no cache do adm
PKG_TARBALL="musl-${PKG_VERSION}.tar.gz"

# SHA-256 do tarball original (musl_1.2.5.orig.tar.gz) 
PKG_SHA256="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

# Dependências lógicas (ajuste conforme os nomes dos seus scripts)
PKG_DEPENDS=(
  "linux-headers"   # para ${ADM_SYSROOT}/usr/include do kernel
  "binutils-pass1"
  "gcc-pass1"
)

# --------------------------------------------------------------------
# Patches de segurança (CVE-2025-26519) 
#
# 1) corrige validação de entrada no decoder EUC-KR
# 2) endurece caminho de saída UTF-8 contra bugs de decoders
#
# São os patches oficiais enviados pelo Rich Felker na lista de mailing
# da musl (Openwall). Cada URL aponta para o texto do patch.
# --------------------------------------------------------------------

PKG_PATCH_URLS=(
  "https://www.openwall.com/lists/musl/2025/02/13/1/1"
  "https://www.openwall.com/lists/musl/2025/02/13/1/2"
)

# Se quiser, você pode adicionar os SHA256 dos patches aqui depois.
# Por enquanto, deixamos sem checksum e o adm apenas avisa.
PKG_PATCH_SHA256=(
  ""
  ""
)
PKG_PATCH_MD5=(
  ""
  ""
)

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Garantir que o cross-toolchain em /tools/bin vem primeiro no PATH
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        export PATH="${tools_bin}:${PATH}"
        log_info "PATH ajustado para usar cross-toolchain em ${tools_bin}"
    else
        log_warn "Diretório ${tools_bin} não existe; assumindo que ${ADM_TARGET}-gcc está no PATH."
    fi

    # Usar o toolchain cross explicitamente
    export CC="${ADM_TARGET}-gcc"
    export AR="${ADM_TARGET}-ar"
    export RANLIB="${ADM_TARGET}-ranlib"

    # Ambiente mais previsível
    export LC_ALL=C
}

build() {
    # Estamos no diretório do source musl-1.2.5/
    #
    # musl recomenda build in-tree simples para cross, mas podemos usar
    # um diretório de build separado se quisermos. Aqui, mantemos in-tree
    # (mais simples e comum para musl).

    # Apenas log informativo
    log_info "Configurando musl-1.2.5 para TARGET=${ADM_TARGET}, SYSROOT=${ADM_SYSROOT}"

    # IMPORTANTE:
    # - CC já foi definido em pre_build como ${ADM_TARGET}-gcc
    # - AR/RANLIB idem
    # - Para sysroot, usamos DESTDIR na instalação
    #
    # --prefix=/usr -> a libc e includes irão para /usr no SYSROOT
    # --target      -> target do toolchain (ex.: x86_64-pc-linux-musl)
    # --enable-wrapper não é usado aqui (toolchain já existe em /tools)
    ./configure \
        --prefix=/usr \
        --target="${ADM_TARGET}"

    # Compilar libc, libm, etc.
    make
}

install_pkg() {
    # Instala no DESTDIR; o adm faz rsync depois para ${ADM_SYSROOT}
    #
    # Resultado final típico:
    #   ${ADM_SYSROOT}/lib/libc.so
    #   ${ADM_SYSROOT}/lib/ld-musl-*.so.1
    #   ${ADM_SYSROOT}/usr/include/...
    #   ${ADM_SYSROOT}/usr/lib/...
    #
    make DESTDIR="${DESTDIR}" install
}

post_install() {
    # Sanity-check do musl Pass 1:
    #  1) headers em ${ADM_SYSROOT}/usr/include
    #  2) ld-musl-*.so.1 presente em ${ADM_SYSROOT}/lib
    #  3) libc.so presente em ${ADM_SYSROOT}/lib
    #  4) compilação de um dummy.c estática com ${ADM_TARGET}-gcc --sysroot

    local include_dir="${ADM_SYSROOT}/usr/include"
    local libc_dir="${ADM_SYSROOT}/lib"

    if [ ! -d "${include_dir}" ]; then
        log_error "Sanity-check musl Pass 1 falhou: diretório ${include_dir} não existe."
        exit 1
    fi

    if [ ! -d "${libc_dir}" ]; then
        log_error "Sanity-check musl Pass 1 falhou: diretório ${libc_dir} não existe."
        exit 1
    fi

    # ld-musl-*.so.1 típico (ex.: ld-musl-x86_64.so.1)
    local ld_musl
    ld_musl="$(find "${libc_dir}" -maxdepth 1 -type f -name 'ld-musl-*.so.1' 2>/dev/null | head -n1 || true)"

    if [ -z "${ld_musl}" ]; then
        log_error "Sanity-check musl Pass 1 falhou: não foi encontrado ld-musl-*.so.1 em ${libc_dir}."
        exit 1
    fi

    # libc.so (link para a libc real)
    local libc_so
    libc_so="$(find "${libc_dir}" -maxdepth 1 -type f -name 'libc.so' 2>/dev/null | head -n1 || true)"

    if [ -z "${libc_so}" ]; then
        log_error "Sanity-check musl Pass 1 falhou: libc.so não encontrada em ${libc_dir}."
        exit 1
    fi

    log_info "musl Pass 1: ld-musl encontrado em ${ld_musl}"
    log_info "musl Pass 1: libc.so encontrada em ${libc_so}"

    # Compilar um dummy.c estático com o cross-GCC usando SYSROOT
    local cc_tools="${ADM_SYSROOT}/tools/bin/${ADM_TARGET}-gcc"
    local cc="${cc_tools}"

    if [ ! -x "${cc}" ]; then
        # fallback: talvez o cross esteja em outro lugar no PATH
        cc="$(command -v "${ADM_TARGET}-gcc" || true)"
    fi

    if [ -z "${cc}" ] || [ ! -x "${cc}" ]; then
        log_warn "Sanity-check: não foi possível localizar ${ADM_TARGET}-gcc; pulando teste de compilação."
        log_ok "Sanity-check parcial musl Pass 1 OK (headers + ld-musl + libc.so presentes)."
        return 0
    fi

    log_info "Usando compilador para sanity-check: ${cc}"

    local tmpdir
    tmpdir="$(mktemp -d)"
    cat > "${tmpdir}/dummy.c" << 'EOF'
#include <stdio.h>
int main(void) {
    printf("musl dummy test\n");
    return 0;
}
EOF

    # Tentamos um link estático para garantir que a libc está utilizável
    if ! "${cc}" --sysroot="${ADM_SYSROOT}" -static -o "${tmpdir}/dummy" "${tmpdir}/dummy.c"; then
        log_error "Sanity-check musl Pass 1 falhou: não foi possível compilar dummy.c estaticamente com ${cc} usando SYSROOT=${ADM_SYSROOT}."
        rm -rf "${tmpdir}"
        exit 1
    fi

    if [ ! -f "${tmpdir}/dummy" ]; then
        log_error "Sanity-check musl Pass 1 falhou: binário dummy não foi gerado."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check musl Pass 1 OK para TARGET=${ADM_TARGET}, profile=${ADM_PROFILE} (com patches CVE-2025-26519 aplicados)."
}
