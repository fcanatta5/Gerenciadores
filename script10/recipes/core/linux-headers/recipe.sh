# /var/lib/adm/recipes/core/linux-headers/recipe.sh
# Linux kernel UAPI headers (para userspace: libc, toolchain, etc.)

pkgname="linux-headers"
pkgver="6.6.8"
srcext="tar.xz"
srcurl="https://www.kernel.org/pub/linux/kernel/v6.x/linux-${pkgver}.tar.xz"

# SHA256 do linux-6.6.8.tar.xz (kernel.org sha256sums.asc v6.x) 
sha256="88ee6aea239b27a80ba07f7fa7d78079e783ade50add5d6c309fcc73d992154e"
md5=""

description="Linux kernel UAPI headers (make headers_install) para userspace"
category="core"

# Headers normalmente são pré-requisito da libc/toolchain, então NÃO force deps aqui.
deps=()
provides=("dir:/usr/include/linux" "dir:/usr/include/asm")

# O adm chama install_pkg com PREFIX=/usr e DESTDIR=<staging> 
build() {
  # Nada a compilar aqui (só instalação). Mas fazemos um sanity leve:
  [[ -f Makefile ]] || { echo "Makefile do kernel não encontrado"; return 1; }
}

install_pkg() {
  # headers_install coloca os headers em:
  #   $INSTALL_HDR_PATH/include/...
  #
  # Então o target correto é:
  #   DESTDIR + /usr  -> gera DESTDIR/usr/include/...
  #
  # Também é prática comum limpar e sanitizar UAPI:
  #   make headers_install
  # que inclui scripts para limpar headers exportados.

  make mrproper

  make \
    ARCH=x86_64 \
    INSTALL_HDR_PATH="${DESTDIR}${PREFIX:-/usr}" \
    headers_install

  # Opcional (minimalismo): remover arquivo ".*" e lixo eventual
  find "${DESTDIR}${PREFIX:-/usr}/include" -name '.*' -type f -delete 2>/dev/null || true

  # Opcional: garantir permissões “padrão”
  chmod -R a+rX "${DESTDIR}${PREFIX:-/usr}/include" 2>/dev/null || true
}
