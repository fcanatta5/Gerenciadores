pkgname="zlib"
pkgver="1.3.1"
srcext="tar.gz"
srcurl="https://zlib.net/${pkgname}-${pkgver}.tar.gz"
sha256="9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
description="zlib - biblioteca de compressão (deflate) essencial para toolchain e userland"
deps=( "core/make" )

build() {
  # zlib usa configure próprio (não é autotools)
  CHOST="${CHOST:-x86_64-linux-musl}"

  # Evita instalar em /usr/local por acidente
  ./configure --prefix="${PREFIX:-/usr}"

  make -j"${JOBS:-1}"
}

install_pkg() {
  make DESTDIR="${DESTDIR:?}" install

  # Opcional: evita deixar exemplos/lixo se você quiser mais minimalismo:
  rm -rf "${DESTDIR:?}${PREFIX:-/usr}/share" 2>/dev/null || true
}
