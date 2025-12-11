PKG_NAME="binutils-bootstrap"
PKG_VERSION="2.43"
PKG_DESC="Binutils for bootstrap toolchain"
PKG_DEPENDS="linux-headers"
PKG_LIBC=""   # usa o profile atual (bootstrap)

build() {
    local url="https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
    local tar="binutils-${PKG_VERSION}.tar.xz"
    local src

    src="$(fetch_source "$url" "$tar")"

    mkdir -p "$PKG_BUILD_WORK"
    cd "$PKG_BUILD_WORK"
    rm -rf "binutils-${PKG_VERSION}"
    tar xf "$src"
    mkdir -p build
    cd build

    # Rootfs do profile bootstrap
    local sysroot="$PKG_ROOTFS"
    mkdir -p "$PKG_BUILD_ROOT/tools"

    ../binutils-${PKG_VERSION}/configure \
        --prefix=/tools \
        --with-sysroot="$sysroot" \
        --target="$(uname -m)-lfs-linux-gnu" \
        --disable-nls \
        --disable-multilib

    make
    make install DESTDIR="$PKG_BUILD_ROOT"
}
