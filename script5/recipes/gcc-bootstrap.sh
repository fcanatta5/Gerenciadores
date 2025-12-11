PKG_NAME="gcc-bootstrap"
PKG_VERSION="14.2.0"
PKG_DESC="C-only GCC bootstrap compiler"
PKG_DEPENDS="binutils-bootstrap linux-headers"
PKG_LIBC=""   # profile atual (bootstrap)

build() {
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
    rm -rf "gcc-${PKG_VERSION}"
    tar xf "$gcc_src"

    cd "gcc-${PKG_VERSION}"

    # Unpack libs dentro da árvore do GCC (estilo LFS)
    tar xf "$mpfr_src"
    mv -v mpfr-* mpfr
    tar xf "$gmp_src"
    mv -v gmp-* gmp
    tar xf "$mpc_src"
    mv -v mpc-* mpc

    mkdir -p ../build-gcc
    cd ../build-gcc

    local target
    target="$(uname -m)-lfs-linux-gnu"
    local sysroot="$PKG_ROOTFS"

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

    make all-gcc
    make all-target-libgcc
    make install-gcc DESTDIR="$PKG_BUILD_ROOT"
    make install-target-libgcc DESTDIR="$PKG_BUILD_ROOT"
}
