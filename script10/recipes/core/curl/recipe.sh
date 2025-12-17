# /var/lib/adm/recipes/core/curl/recipe.sh

pkgname="curl"
pkgver="8.17.0"
srcext="tar.gz"

# O site oficial lista os source archives do curl 8.17.0 (inclui .tar.gz). 6
srcurl="https://curl.se/download/curl-${pkgver}.tar.gz"

# SHA256 verificável via Debian orig tarball 8.17.0 7
# (Se você preferir, posso ajustar para PGP + assinatura .asc em vez de SHA256.)
sha256="e8e74cdeefe5fb78b3ae6e90cd542babf788fa9480029cfcee6fd9ced42b7910"
md5=""

description="curl + libcurl - ferramenta e biblioteca para transferências via URL (HTTP/HTTPS etc.)"
category="core"

# Para HTTPS real, você precisa de um backend TLS.
# Aqui assumimos OpenSSL + zlib (mínimo comum). Se você ainda não tem esses recipes, gere-os antes do curl.
deps=("core/zlib" "core/openssl" "core/bzip2")
provides=("cmd:curl" "lib:libcurl")

: "${CURL_DISABLE_NLS:=1}"
: "${CURL_MINIMAL:=1}"

build() {
  rm -rf .adm-build
  mkdir -p .adm-build
  cd .adm-build

  local prefix="${PREFIX:-/usr}"
  local cfg=(
    "--prefix=${prefix}"
    "--disable-static"
    "--enable-shared"
    "--with-ssl"          # usa OpenSSL via pkg-config/detect
    "--with-zlib"
    "--with-bz2"
  )

  if [[ "${CURL_DISABLE_NLS}" == "1" ]]; then
    cfg+=("--disable-nls")
  fi

  if [[ "${CURL_MINIMAL}" == "1" ]]; then
    # Minimalismo sem quebrar o básico de HTTP/HTTPS:
    cfg+=(
      "--disable-ldap"
      "--disable-ldaps"
      "--disable-rtsp"
      "--disable-dict"
      "--disable-telnet"
      "--disable-tftp"
      "--disable-pop3"
      "--disable-imap"
      "--disable-smtp"
      "--disable-gopher"
      "--disable-mqtt"
      "--disable-manual"
      "--without-libidn2"
      "--without-brotli"
      "--without-zstd"
    )
  fi

  ../configure "${cfg[@]}"
  make -j"${JOBS}"
}

install_pkg() {
  cd .adm-build
  make DESTDIR="${DESTDIR}" install

  # Opcional: remove docs pesadas se você quer root bem minimal
  # rm -rf "${DESTDIR}/usr/share/doc" 2>/dev/null || true

  # Copia files/ se existir
  if [[ -d "${FILES_DIR}" ]]; then
    cp -a "${FILES_DIR}/." "${DESTDIR}/"
  fi
}
