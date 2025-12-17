# /var/lib/adm/recipes/core/bzip2/recipe.sh

pkgname="bzip2"
pkgver="1.0.8"
srcext="tar.gz"
srcurl="https://sourceware.org/pub/bzip2/bzip2-${pkgver}.tar.gz"

# SHA256 e MD5 do bzip2-1.0.8.tar.gz (fossies) 4
sha256="ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"
md5="67e051268d0c475ea773822f7500d0e5"

description="bzip2/libbzip2 - compressor e biblioteca de compressão"
category="core"

deps=("core/musl" "core/binutils" "core/gcc")
provides=("cmd:bzip2" "cmd:bunzip2" "cmd:bzcat" "lib:libbz2")

: "${BZIP2_BUILD_SHARED:=1}"  # 1=gera .so também (recomendado para sistema geral)
: "${BZIP2_ENABLE_LFS:=1}"    # Large File Support

build() {
  # bzip2 usa Makefile (sem configure). Ajustamos flags e prefixo no install.
  local cflags="${CFLAGS:-}"
  local ldflags="${LDFLAGS:-}"

  if [[ "${BZIP2_ENABLE_LFS}" == "1" ]]; then
    cflags+=" -D_FILE_OFFSET_BITS=64"
  fi

  make -j"${JOBS}" CFLAGS="$cflags" LDFLAGS="$ldflags"

  # Build de lib compartilhada (bzip2 “clássico” não vem com build system moderno)
  if [[ "${BZIP2_BUILD_SHARED}" == "1" ]]; then
    # Alvo comum em diversas receitas: "make -f Makefile-libbz2_so"
    if [[ -f Makefile-libbz2_so ]]; then
      make -j"${JOBS}" -f Makefile-libbz2_so CFLAGS="$cflags" LDFLAGS="$ldflags"
    fi
  fi
}

install_pkg() {
  local prefix="${PREFIX:-/usr}"
  install -d "${DESTDIR}${prefix}/bin" "${DESTDIR}${prefix}/lib" "${DESTDIR}${prefix}/include" "${DESTDIR}${prefix}/share/man/man1"

  # instala binários e manpages
  make PREFIX="${prefix}" DESTDIR="${DESTDIR}" install

  # instala headers e biblioteca estática
  install -m 0644 bzlib.h "${DESTDIR}${prefix}/include/"
  install -m 0644 libbz2.a "${DESTDIR}${prefix}/lib/"

  # instala .so se gerada
  if [[ "${BZIP2_BUILD_SHARED}" == "1" && -f libbz2.so.1.0.8 ]]; then
    install -m 0755 libbz2.so.1.0.8 "${DESTDIR}${prefix}/lib/"
    ln -sf libbz2.so.1.0.8 "${DESTDIR}${prefix}/lib/libbz2.so.1.0"
    ln -sf libbz2.so.1.0.8 "${DESTDIR}${prefix}/lib/libbz2.so.1"
    ln -sf libbz2.so.1.0.8 "${DESTDIR}${prefix}/lib/libbz2.so"
  fi

  # links esperados
  ln -sf bzip2 "${DESTDIR}${prefix}/bin/bunzip2"
  ln -sf bzip2 "${DESTDIR}${prefix}/bin/bzcat"

  # Copia files/ se existir
  if [[ -d "${FILES_DIR}" ]]; then
    cp -a "${FILES_DIR}/." "${DESTDIR}/"
  fi
}
