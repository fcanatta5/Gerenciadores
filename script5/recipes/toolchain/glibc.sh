PKG_NAME="glibc"
PKG_VERSION="2.40"
PKG_DESC="GNU C Library"
PKG_DEPENDS="linux-headers"
PKG_LIBC="glibc"

build() {
    local url="https://ftp.gnu.org/gnu/libc/glibc-${PKG_VERSION}.tar.xz"
    local tar="glibc-${PKG_VERSION}.tar.xz"
    local src

    src="$(fetch_source "$url" "$tar")"

    mkdir -p "$PKG_BUILD_WORK"
    cd "$PKG_BUILD_WORK"
    rm -rf "glibc-${PKG_VERSION}"
    tar xf "$src"
    mkdir -p build
    cd build

    # Toolchain de bootstrap
    local bootstrap_root="/opt/adm/profiles/bootstrap/rootfs"
    export PATH="$bootstrap_root/tools/bin:$PATH"

    local target
    target="$(uname -m)-lfs-linux-gnu"

    ../glibc-${PKG_VERSION}/configure \
        --prefix=/usr \
        --host="$target" \
        --build="$(../glibc-${PKG_VERSION}/scripts/config.guess)" \
        --enable-kernel=4.19 \
        --with-headers="$bootstrap_root/usr/include"

    make
    make install DESTDIR="$PKG_BUILD_ROOT"
}
