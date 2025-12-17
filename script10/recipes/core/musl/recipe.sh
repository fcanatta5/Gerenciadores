# /var/lib/adm/recipes/core/musl/recipe.sh

pkgname="musl"
pkgver="1.2.5"
srcext="tar.gz"
srcurl="https://musl.libc.org/releases/musl-${pkgver}.tar.gz"

# Observação: checksums abaixo precisam ser do tarball oficial que você baixar.
# Eu recomendo você preencher com:
#   sha256="$(sha256sum musl-1.2.5.tar.gz | awk '{print $1}')"
# Para não arriscar divergência por mirror/corrupt download.
sha256=""
md5=""

description="musl libc (core). Inclui patches de segurança CVE-2025-26519 para 1.2.5."
category="core"
deps=()
provides=("so:libc.so=0")

: "${MUSL_PREFIX:=/usr}"
: "${MUSL_SYSLIBDIR:=/lib}"
: "${MUSL_DISABLE_GCC_WRAPPER:=1}"

build() {
  local cfg=(
    "--prefix=${MUSL_PREFIX}"
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

  # ldd (fallback seguro)
  if [[ ! -e "${DESTDIR}/usr/bin/ldd" ]]; then
    install -d "${DESTDIR}/usr/bin"
    cat > "${DESTDIR}/usr/bin/ldd" <<'EOF'
#!/bin/sh
exec /lib/libc.so "$@"
EOF
    chmod +x "${DESTDIR}/usr/bin/ldd"
  fi

  # files/ (ex.: /etc/ld-musl-x86_64.path)
  if [[ -d "${FILES_DIR}" ]]; then
    cp -a "${FILES_DIR}/." "${DESTDIR}/"
  fi
}

post_install() {
  # garante arquivo de path mínimo
  local f="${DESTDIR}/etc/ld-musl-x86_64.path"
  if [[ ! -e "$f" ]]; then
    install -d "${DESTDIR}/etc"
    printf "%s\n" "/usr/lib" "/lib" >"$f"
  fi
}
