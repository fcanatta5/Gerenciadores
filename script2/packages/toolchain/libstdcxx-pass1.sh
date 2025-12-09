# /opt/adm/packages/toolchain/libstdcxx-pass1.sh
#
# Libstdc++ a partir do GCC-15.2.0 - Pass 1
#
# - reutiliza o tarball do GCC-15.2.0 (mesmo source do gcc-pass1)
# - compila SOMENTE libstdc++-v3 para TARGET=${ADM_TARGET}
# - usa o cross-toolchain em ${ADM_SYSROOT}/tools (gcc-pass1)
# - instala em ${ADM_SYSROOT}/usr (via DESTDIR)
# - inclui sanity-check de C++ simples
#

PKG_NAME="libstdcxx-pass1"
PKG_VERSION="15.2.0"
PKG_CATEGORY="toolchain"

# Usa o mesmo tarball do GCC-15.2.0
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="gcc-${PKG_VERSION}.tar.xz"

# Opcional: preencha quando quiser travar o checksum
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas
PKG_DEPENDS=(
  "binutils-pass1"
  "gcc-pass1"
  "linux-headers"
  "glibc-pass1"   # ou "musl-pass1" em árvore separada, se você dividir por perfis
)

# Nenhum patch específico para libstdc++ aqui (herda os do gcc se você quiser)

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Garantir uso do cross-toolchain de /tools
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        export PATH="${tools_bin}:${PATH}"
        log_info "PATH ajustado para usar cross-toolchain em ${tools_bin}"
    else
        log_warn "Diretório ${tools_bin} não existe; assumindo que ${ADM_TARGET}-gcc está no PATH."
    fi

    # Forçar cross-compilador
    export CC="${ADM_TARGET}-gcc"
    export CXX="${ADM_TARGET}-g++"
    export AR="${ADM_TARGET}-ar"
    export RANLIB="${ADM_TARGET}-ranlib"

    export LC_ALL=C
}

build() {
    # Estamos no diretório de source do GCC-15.2.0 (tarball extraído pelo adm)
    #
    # Padrão LFS para construir libstdc++ separadamente:
    #   mkdir build && cd build
    #   ../libstdc++-v3/configure ...
    #
    mkdir -v build
    cd build

    local build_triplet
    build_triplet="$(../config.guess)"

    # Diretório dos includes C++ do cross toolchain (gcc-pass1):
    #
    # gcc-pass1 instalou com --prefix=/tools e --target=${ADM_TARGET}
    # Layout típico:
    #   ${ADM_SYSROOT}/tools/${ADM_TARGET}/include/c++/${PKG_VERSION}
    #
    local gxx_inc_dir="${ADM_SYSROOT}/tools/${ADM_TARGET}/include/c++/${PKG_VERSION}"

    if [ ! -d "${gxx_inc_dir}" ]; then
        log_warn "Diretório de includes C++ do toolchain não encontrado em ${gxx_inc_dir}."
        log_warn "Continuando mesmo assim, mas verifique se gcc-pass1 foi instalado corretamente."
    fi

    ../libstdc++-v3/configure \
        --host="${ADM_TARGET}" \
        --build="${build_triplet}" \
        --prefix=/usr \
        --disable-multilib \
        --disable-nls \
        --disable-libstdcxx-pch \
        --with-gxx-include-dir="${gxx_inc_dir}"

    make
}

install_pkg() {
    # Instala no DESTDIR; o adm fará rsync para ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install
}

post_install() {
    # Sanity-check Libstdc++ Pass 1:
    #
    # 1) headers em ${ADM_SYSROOT}/usr/include/c++/${PKG_VERSION}
    # 2) libstdc++.so presente em ${ADM_SYSROOT}/usr/lib (ou similar)
    # 3) compilação de um programa C++ simples com ${ADM_TARGET}-g++ --sysroot

    local cxx_inc_root="${ADM_SYSROOT}/usr/include/c++"
    local cxx_ver_dir="${cxx_inc_root}/${PKG_VERSION}"

    if [ ! -d "${cxx_inc_root}" ]; then
        log_error "Sanity-check libstdc++ Pass 1 falhou: diretório ${cxx_inc_root} não existe."
        exit 1
    fi

    if [ ! -d "${cxx_ver_dir}" ]; then
        log_error "Sanity-check libstdc++ Pass 1 falhou: diretório de headers ${cxx_ver_dir} não existe."
        exit 1
    fi

    # Procurar libstdc++.so
    local libstdcxx
    libstdcxx="$(find "${ADM_SYSROOT}/usr/lib" "${ADM_SYSROOT}/lib" -maxdepth 3 -type f -name 'libstdc++.so*' 2>/dev/null | head -n1 || true)"

    if [ -z "${libstdcxx}" ]; then
        log_error "Sanity-check libstdc++ Pass 1 falhou: libstdc++.so* não encontrado em ${ADM_SYSROOT}/usr/lib ou ${ADM_SYSROOT}/lib."
        exit 1
    fi

    log_info "libstdc++ Pass 1: libstdc++.so encontrado em ${libstdcxx}"
    log_info "libstdc++ Pass 1: headers C++ em ${cxx_ver_dir}"

    # Compilador C++ do toolchain
    local cxx_tools="${ADM_SYSROOT}/tools/bin/${ADM_TARGET}-g++"
    local cxx="${cxx_tools}"

    if [ ! -x "${cxx}" ]; then
        cxx="$(command -v "${ADM_TARGET}-g++" || true)"
    fi

    if [ -z "${cxx}" ] || [ ! -x "${cxx}" ]; then
        log_warn "Sanity-check: não foi possível localizar ${ADM_TARGET}-g++; pulando teste de compilação C++."
        log_ok "Sanity-check parcial libstdc++ Pass 1 OK (headers + libstdc++.so presentes)."
        return 0
    fi

    log_info "Usando compilador C++ para sanity-check: ${cxx}"

    local tmpdir
    tmpdir="$(mktemp -d)"
    cat > "${tmpdir}/dummy.cpp" << 'EOF'
#include <iostream>
int main() {
    std::cout << "libstdc++ dummy test\n";
    return 0;
}
EOF

    # Link dinâmico padrão contra a libstdc++ instalada no SYSROOT
    if ! "${cxx}" --sysroot="${ADM_SYSROOT}" -o "${tmpdir}/dummy" "${tmpdir}/dummy.cpp"; then
        log_error "Sanity-check libstdc++ Pass 1 falhou: não foi possível compilar dummy.cpp com ${cxx} usando SYSROOT=${ADM_SYSROOT}."
        rm -rf "${tmpdir}"
        exit 1
    fi

    if [ ! -f "${tmpdir}/dummy" ]; then
        log_error "Sanity-check libstdc++ Pass 1 falhou: binário dummy não foi gerado."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"

    log_ok "Sanity-check libstdc++ Pass 1 OK para TARGET=${ADM_TARGET}, profile=${ADM_PROFILE}."
}
