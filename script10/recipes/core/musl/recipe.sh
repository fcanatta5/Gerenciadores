# /var/lib/adm/recipes/core/musl/recipe.sh
# musl 1.2.5 + patches CVE-2025-26519 (aplicados via patches/ automaticamente)

pkgname="musl"
pkgver="1.2.5"
srcext="tar.gz"
srcurl="https://musl.libc.org/releases/musl-${pkgver}.tar.gz"

# SHA256 conhecido do tarball musl-1.2.5.tar.gz 2
sha256="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"
md5=""

description="musl libc (core) - 1.2.5 + patches de segurança CVE-2025-26519"
category="core"

deps=()
provides=("so:libc.so=0" "cmd:ldd")

# O seu adm chama install_pkg com PREFIX=/usr e DESTDIR=<staging> 3
# musl loader deve ficar em /lib (syslibdir), mantendo /usr limpo.
: "${MUSL_SYSLIBDIR:=/lib}"
: "${MUSL_DISABLE_GCC_WRAPPER:=1}"

build() {
  local cfg=(
    "--prefix=${PREFIX:-/usr}"
    "--syslibdir=${MUSL_SYSLIBDIR}"
  )

  if [[ "${MUSL_DISABLE_GCC_WRAPPER}" == "1" ]]; then
    cfg+=("--disable-gcc-wrapper")
  fi

  ./configure "${cfg[@]}"
  make -j"${JOBS}"
}

install_pkg() {
  make DESTDIR="${DESTDIR}" install

  # Garante /etc/ld-musl-x86_64.path (musl usa esse arquivo para lookup de libs)
  # Não use hook post_install: no seu adm os hooks não herdam DESTDIR de forma confiável.
  install -d "${DESTDIR}/etc"
  if [[ -d "${FILES_DIR}" ]]; then
    cp -a "${FILES_DIR}/." "${DESTDIR}/"
  fi

  # Fallback seguro para ldd (geralmente o musl instala, mas garantimos)
  if [[ ! -e "${DESTDIR}/usr/bin/ldd" ]]; then
    install -d "${DESTDIR}/usr/bin"
    cat > "${DESTDIR}/usr/bin/ldd" <<'EOF'
#!/bin/sh
exec /lib/libc.so "$@"
EOF
    chmod +x "${DESTDIR}/usr/bin/ldd"
  fi
}
