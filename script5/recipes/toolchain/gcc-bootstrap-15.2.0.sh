# /opt/adm/packages/toolchain/gcc-bootstrap-15.2.0.sh
#
# GCC - Pass 1 (bootstrap cross-compiler)
# 100% compatível com adm.sh (categorias + profiles):
# - Usa PKG_BUILD_ROOT como DESTDIR (adm empacota e extrai em PKG_ROOTFS)
# - Instala em /tools (dentro do rootfs do profile)
# - Alinhado ao profile "bootstrap" via env.sh (LFS_TGT, PATH, etc.)
# - Depende de linux-headers + binutils-bootstrap
#
# Resultado esperado (profile bootstrap):
#   $PKG_ROOTFS/tools/bin/${LFS_TGT}-gcc
#   $PKG_ROOTFS/tools/lib/gcc/${LFS_TGT}/15.2.0/libgcc.a  (e afins)

PKG_NAME="gcc-bootstrap"
PKG_VERSION="15.2.0"
PKG_DESC="GCC - Pass 1 (bootstrap cross-compiler)"
PKG_DEPENDS="binutils-bootstrap linux-headers"
PKG_CATEGORY="toolchain"
PKG_LIBC=""   # segue o profile atual (ex.: bootstrap)

build() {
    # Fontes oficiais
    local gcc_url="https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
    local gcc_tar="gcc-${PKG_VERSION}.tar.xz"

    # Dependências internas (embutidas na árvore do GCC; padrão LFS)
    local mpfr_url="https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz"
    local mpfr_tar="mpfr-4.2.1.tar.xz"
    local gmp_url="https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
    local gmp_tar="gmp-6.3.0.tar.xz"
    local mpc_url="https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"
    local mpc_tar="mpc-1.3.1.tar.gz"

    local gcc_src mpfr_src gmp_src mpc_src
    gcc_src="$(fetch_source "$gcc_url" "$gcc_tar")"
    mpfr_src="$(fetch_source "$mpfr_url" "$mpfr_tar")"
    gmp_src="$(fetch_source "$gmp_url" "$gmp_tar")"
    mpc_src="$(fetch_source "$mpc_url" "$mpc_tar")"

    mkdir -p "$PKG_BUILD_WORK"
    cd "$PKG_BUILD_WORK"
    rm -rf "gcc-${PKG_VERSION}" build-gcc

    # Extrai GCC
    tar xf "$gcc_src"
    cd "gcc-${PKG_VERSION}"

    # Embute MPFR/GMP/MPC na árvore do GCC
    tar xf "$mpfr_src"
    mv -v mpfr-* mpfr
    tar xf "$gmp_src"
    mv -v gmp-* gmp
    tar xf "$mpc_src"
    mv -v mpc-* mpc

    # Build fora da árvore
    cd "$PKG_BUILD_WORK"
    mkdir -p build-gcc
    cd build-gcc

    # Target: do profile bootstrap/env.sh (LFS_TGT) ou fallback
    local target="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"

    # sysroot do profile atual
    local sysroot="$PKG_ROOTFS"

    # Garante /tools/bin do rootfs do profile no PATH (binutils-bootstrap)
    export PATH="${sysroot}/tools/bin:${PATH:-}"

    # GCC Pass 1: sem headers libc, mas usando sysroot para caminho futuro
    # Nota: --without-headers impede usar headers libc; linux-headers já estão em $sysroot/usr/include
    ../gcc-${PKG_VERSION}/configure \
        --target="$target" \
        --prefix=/tools \
        --with-sysroot="$sysroot" \
        --with-newlib \
        --without-headers \
        --enable-initfini-array \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-decimal-float \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdcxx \
        --enable-languages=c

    # Compila somente o necessário para Pass 1
    make all-gcc
    make all-target-libgcc

    # Instala em DESTDIR para o adm empacotar
    make install-gcc DESTDIR="$PKG_BUILD_ROOT"
    make install-target-libgcc DESTDIR="$PKG_BUILD_ROOT"
}

pre_install() {
    echo "==> [gcc-bootstrap-${PKG_VERSION}] Instalando GCC Pass 1 em /tools (via adm)"
}

post_install() {
    echo "==> [gcc-bootstrap-${PKG_VERSION}] Sanity-check (pós-instalação) do GCC Pass 1"

    local sysroot="${PKG_ROOTFS:-$ADM_CURRENT_ROOTFS}"
    local tools_bin="${sysroot}/tools/bin"
    local target="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"

    local cc="${tools_bin}/${target}-gcc"
    local ld="${tools_bin}/${target}-ld"
    local as="${tools_bin}/${target}-as"

    # 1) Verifica binários essenciais do toolchain
    if [ ! -x "$cc" ]; then
        echo "ERRO: ${cc} não encontrado ou não executável."
        exit 1
    fi
    if [ ! -x "$ld" ]; then
        echo "ERRO: ${ld} não encontrado ou não executável (binutils-bootstrap ausente?)."
        exit 1
    fi
    if [ ! -x "$as" ]; then
        echo "ERRO: ${as} não encontrado ou não executável (binutils-bootstrap ausente?)."
        exit 1
    fi

    # 2) Confirma PATH (adm.sh + env.sh do profile devem garantir)
    if ! command -v "${target}-gcc" >/dev/null 2>&1; then
        echo "ERRO: ${target}-gcc não está no PATH."
        echo "PATH atual: $PATH"
        exit 1
    fi

    # 3) Verifica versão e specs básicas
    echo "---- ${target}-gcc -v (resumo) ----"
    "${target}-gcc" -v >/dev/null 2>&1 || {
        echo "ERRO: ${target}-gcc -v falhou."
        exit 1
    }

    # 4) Teste de compilação: gera objeto (sem linkar) e garante que encontra os Linux API headers
    #    (alinhado com linux-headers: $sysroot/usr/include)
    local test_c="dummy-gcc-pass1.c"
    local test_o="dummy-gcc-pass1.o"
    local hdr="${sysroot}/usr/include/linux/types.h"

    if [ ! -f "$hdr" ]; then
        echo "ERRO: Linux API headers não encontrados em ${hdr} (linux-headers não instalado?)."
        exit 1
    fi

    cat > "$test_c" <<EOF
#include <linux/types.h>
int main(void) { return 0; }
EOF

    # -c: não linka (não há libc ainda), mas valida pré-processamento + compilação
    if ! "${target}-gcc" -c "$test_c" -o "$test_o"; then
        echo "ERRO: compilação do teste falhou (GCC Pass 1)."
        rm -f "$test_c" "$test_o"
        exit 1
    fi

    # 5) Verifica que libgcc foi instalada no local esperado dentro de /tools
    # (caminho típico do GCC)
    local libgcc_a="${sysroot}/tools/lib/gcc/${target}/${PKG_VERSION}/libgcc.a"
    if [ ! -f "$libgcc_a" ]; then
        # Alguns layouts podem variar; tentamos localizar de forma tolerante
        local found
        found="$(find "${sysroot}/tools/lib/gcc/${target}" -maxdepth 3 -name libgcc.a 2>/dev/null | head -n1 || true)"
        if [ -z "$found" ]; then
            echo "ERRO: libgcc.a não encontrada em ${sysroot}/tools/lib/gcc/${target}/... (install-target-libgcc falhou?)."
            rm -f "$test_c" "$test_o"
            exit 1
        fi
    fi

    echo "Sanity-check GCC Pass 1 (${PKG_VERSION}) OK."
    rm -f "$test_c" "$test_o"
}
