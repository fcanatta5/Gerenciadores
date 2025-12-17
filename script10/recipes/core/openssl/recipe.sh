# /var/lib/adm/recipes/core/openssl/recipe.sh

pkgname="openssl"
pkgver="3.5.4"
srcext="tar.gz"
srcurl="https://github.com/openssl/openssl/releases/download/openssl-${pkgver}/openssl-${pkgver}.tar.gz"

# SHA256 do openssl-3.5.4.tar.gz (referência: homebrew-core openssl@3.5) 
sha256="967311f84955316969bdb1d8d4b983718ef42338639c621ec4c34fddef355e99"
md5=""

description="OpenSSL - biblioteca e ferramentas TLS/SSL e criptografia"
category="core"

deps=("core/musl" "core/binutils" "core/gcc" "core/zlib")
provides=("cmd:openssl" "lib:libssl" "lib:libcrypto")

# Política: manter simples e previsível
: "${OPENSSL_PREFIX:=${PREFIX:-/usr}}"
: "${OPENSSL_OPENSSLDIR:=/etc/ssl}"
: "${OPENSSL_LIBDIR:=lib}"
: "${OPENSSL_SHARED:=1}"          # 1=shared libs (.so), 0=static only
: "${OPENSSL_THREADS:=1}"         # manter threads habilitado (padrão)
: "${OPENSSL_ZLIB:=1}"            # 1=habilita zlib (requer core/zlib + headers)

# Hardening e compat
: "${OPENSSL_NO_LEGACY:=0}"       # 1=desabilita legacy provider (pode quebrar coisas antigas)

build() {
  # OpenSSL usa o próprio build system (Configure)
  command -v perl >/dev/null 2>&1 || die "perl é necessário para construir openssl"

  local target="linux-x86_64"
  local args=(
    "--prefix=${OPENSSL_PREFIX}"
    "--openssldir=${OPENSSL_OPENSSLDIR}"
    "--libdir=${OPENSSL_LIBDIR}"
    "no-ssl3"
    "no-ssl3-method"
    "no-docs"
  )

  if [[ "${OPENSSL_SHARED}" == "1" ]]; then
    args+=("shared")
  else
    args+=("no-shared")
  fi

  if [[ "${OPENSSL_ZLIB}" == "1" ]]; then
    # Use "zlib" (estático) ou "zlib-dynamic" (dinâmico). Aqui deixo dinâmico.
    args+=("zlib-dynamic")
  else
    args+=("no-zlib")
  fi

  if [[ "${OPENSSL_NO_LEGACY}" == "1" ]]; then
    args+=("no-legacy")
  fi

  # Respeita CFLAGS/LDFLAGS se seu ambiente definir
  # (OpenSSL usa esses envs diretamente)
  perl ./Configure "${target}" "${args[@]}"

  make -j"${JOBS}"
}

install_pkg() {
  # Instala apenas software (libs + bin) e cria dirs padrão.
  # "install_sw" evita instalar docs/man pesadas; "install_ssldirs" cria openssldir/certs/private.
  make DESTDIR="${DESTDIR}" install_sw
  make DESTDIR="${DESTDIR}" install_ssldirs

  # Garante um openssl.cnf básico (evita comportamento “moody” quando não existe).
  # O source tree possui template em apps/openssl.cnf.
  if [[ ! -e "${DESTDIR}${OPENSSL_OPENSSLDIR}/openssl.cnf" ]]; then
    install -D -m 0644 "apps/openssl.cnf" "${DESTDIR}${OPENSSL_OPENSSLDIR}/openssl.cnf"
  fi

  # Copia files/ se existir
  if [[ -d "${FILES_DIR}" ]]; then
    cp -a "${FILES_DIR}/." "${DESTDIR}/"
  fi
}
