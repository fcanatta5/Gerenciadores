PKG_NAME="musl"
PKG_VERSION="1.2.5"
PKG_DESC="musl C library"
PKG_DEPENDS="linux-headers"
PKG_LIBC="musl"

build() {
    local url="https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"
    local tar="musl-${PKG_VERSION}.tar.gz"
    local src

    src="$(fetch_source "$url" "$tar")"

    mkdir -p "$PKG_BUILD_WORK"
    cd "$PKG_BUILD_WORK"
    rm -rf "musl-${PKG_VERSION}"
    tar xf "$src"
    cd "musl-${PKG_VERSION}"

    local bootstrap_root="/opt/adm/profiles/bootstrap/rootfs"
    export PATH="$bootstrap_root/tools/bin:$PATH"

    local target
    target="$(uname -m)-lfs-linux-musl"

    ./configure \
        --prefix=/usr \
        --target="$target"

    make
    make install DESTDIR="$PKG_BUILD_ROOT"
}
