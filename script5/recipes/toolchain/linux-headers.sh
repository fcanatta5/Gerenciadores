PKG_NAME="linux-headers"
PKG_VERSION="6.6"
PKG_DESC="Linux API headers for bootstrap"
PKG_DEPENDS=""
PKG_LIBC=""   # segue o profile atual (bootstrap, glibc, etc.)

build() {
    local url="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
    local tar="linux-${PKG_VERSION}.tar.xz"

    local src
    src="$(fetch_source "$url" "$tar")"

    mkdir -p "$PKG_BUILD_WORK"
    cd "$PKG_BUILD_WORK"
    rm -rf "linux-${PKG_VERSION}"
    tar xf "$src"
    cd "linux-${PKG_VERSION}"

    # headers "sanitizados" estilo LFS
    make mrproper
    make headers
    find usr/include -name '.*' -delete
    rm -f usr/include/Makefile

    mkdir -p "$PKG_BUILD_ROOT/usr"
    cp -rv usr/include "$PKG_BUILD_ROOT/usr/"
}
