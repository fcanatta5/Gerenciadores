# /opt/adm/packages/toolchain/gcc-bootstrap-15.2.0.sh
#
# GCC - Pass 1 (bootstrap cross-compiler)
# Integração com adm.sh:
#   - Usa PKG_BUILD_ROOT como DESTDIR
#   - Usa PKG_ROOTFS como sysroot (rootfs do profile)
#   - Empacotado pelo adm.sh e instalado em /tools dentro do rootfs
#   - Hook de sanity-check em post_install, usando ${target}-gcc

PKG_NAME="gcc-bootstrap"
PKG_VERSION="15.2.0"
PKG_DESC="GCC - Pass 1 (bootstrap cross-compiler)"
PKG_DEPENDS="binutils-bootstrap linux-headers"
PKG_CATEGORY="toolchain"
PKG_LIBC=""   # usa o profile atual (ex.: bootstrap)

build() {
    # URLs das dependências incorporadas na árvore do GCC
    local gcc_url="https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
    local gcc_tar="gcc-${PKG_VERSION}.tar.xz"

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

    tar xf "$gcc_src"
    cd "gcc-${PKG_VERSION}"

    # Integra MPFR/GMP/MPC na árvore do GCC (estilo LFS)
    tar xf "$mpfr_src"
    mv -v mpfr-* mpfr

    tar xf "$gmp_src"
    mv -v gmp-* gmp

    tar xf "$mpc_src"
    mv -v mpc-* mpc

    # Diretório de build separado
    cd ..
    mkdir -p build-gcc
    cd build-gcc

    # Target LFS: <arch>-lfs-linux-gnu
    local target
    target="$(uname -m)-lfs-linux-gnu"

    # sysroot = rootfs do profile atual (ex.: /opt/adm/profiles/bootstrap/rootfs)
    local sysroot="$PKG_ROOTFS"

    # Garante toolchain do profile no PATH (binutils pass 1, etc.)
    export PATH="$sysroot/tools/bin:${PATH:-}"

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

    # Compila apenas o que é necessário para Pass 1
    make all-gcc
    make all-target-libgcc

    # IMPORTANTE: instalar no DESTDIR (PKG_BUILD_ROOT), pois o adm.sh
    # empacota a partir desse rootfs temporário.
    make install-gcc DESTDIR="$PKG_BUILD_ROOT"
    make install-target-libgcc DESTDIR="$PKG_BUILD_ROOT"
}

# Hook opcional pré-instalação (aqui só loga)
pre_install() {
    echo "==> [gcc-bootstrap] Instalando GCC Pass 1 em /tools (via adm)"
}

# Hook de sanity-check do cross-compiler (roda DEPOIS de instalado no rootfs do profile)
post_install() {
    echo "==> [gcc-bootstrap] Sanity-check do cross-compiler GCC Pass 1"

    local target
    target="$(uname -m)-lfs-linux-gnu"

    # PKG_ROOTFS aponta para o rootfs real do profile (já com /tools),
    # e o adm.sh já prefixa PATH com $ROOTFS/tools/bin.
    local sysroot="$PKG_ROOTFS"
    local tools_bin="${sysroot}/tools/bin"

    # Garante que o binário ${target}-gcc existe de fato
    if [ ! -x "${tools_bin}/${target}-gcc" ]; then
        echo "ERRO: ${tools_bin}/${target}-gcc não encontrado após instalação."
        exit 1
    fi

    # Garante também que está no PATH
    if ! command -v "${target}-gcc" >/dev/null 2>&1; then
        echo "ERRO: ${target}-gcc não está no PATH após instalação."
        echo "PATH atual: $PATH"
        exit 1
    fi

    # Teste mínimo: compilar um programa simples em modo -c (sem linkar),
    # pois esse GCC Pass 1 não tem libc completa ainda.
    local test_c="dummy-gcc-pass1.c"
    local test_o="dummy-gcc-pass1.o"

    cat > "$test_c" <<'EOF'
int main(void) { return 0; }
EOF

    if ! "${target}-gcc" -c "$test_c" -o "$test_o"; then
        echo "ERRO: sanity-check GCC Pass 1 falhou ao compilar dummy-gcc-pass1.c"
        rm -f "$test_c" "$test_o"
        exit 1
    fi

    # Opcional: inspeciona o .o com objdump/readelf se disponível
    if command -v "${target}-objdump" >/dev/null 2>&1; then
        "${target}-objdump" -f "$test_o" >/dev/null 2>&1 || true
    fi

    echo "Sanity-check GCC Pass 1: compilação de objeto simples OK."

    rm -f "$test_c" "$test_o"
}

# Hook pós-build (opcional). Aqui não usamos; o sanity principal está em post_install()
post_build() {
    :
}
