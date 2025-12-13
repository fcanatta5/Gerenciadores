###############################################################################
# tzdata 2025c (BASE) - time zone database
# Cross-safe: compila tzcode (zic nativo do HOST) e usa para gerar zoneinfo
#
# Saída:
#  - /usr/share/zoneinfo (com posix/ e right/)
#  - /etc/localtime (symlink para ZONEINFO/<TZ>)
#  - /etc/timezone (opcional, se ADM_TZ_WRITE_ETC_TIMEZONE=1)
#
# Referências:
# - IANA tzdata/tzcode/tzdb releases. 1
###############################################################################

PKG_CATEGORY="base"
PKG_NAME="tzdata"
PKG_VERSION="2025c"
PKG_RELEASE="1"
PKG_DESC="IANA Time Zone Database ${PKG_VERSION} (zoneinfo compilado via zic nativo)"
PKG_LICENSE="Public-Domain"
PKG_SITE="https://www.iana.org/time-zones"

# tzdata não depende de libc no build (porque usamos zic do host),
# mas no runtime glibc/musl usa os arquivos em /usr/share/zoneinfo.
PKG_DEPENDS=()

# Fontes (data+code) para permitir gerar zoneinfo em cross
PKG_URLS=(
  "https://www.iana.org/time-zones/repository/releases/tzdata${PKG_VERSION}.tar.gz"
  "https://www.iana.org/time-zones/repository/releases/tzcode${PKG_VERSION}.tar.gz"
)

# Checksums:
# O IANA publica .asc (assinaturas) junto dos tarballs, mas nem sempre publica sha256/md5 na página.
# Este script suporta:
#   - verificação por SHA256/MD5 (se você preencher as variáveis abaixo), OU
#   - verificação por GPG (se você fornecer chave e habilitar ADM_TZ_VERIFY_GPG=1).
PKG_SHA256_TZDATA="${PKG_SHA256_TZDATA:-}"
PKG_SHA256_TZCODE="${PKG_SHA256_TZCODE:-}"
PKG_MD5_TZDATA="${PKG_MD5_TZDATA:-}"
PKG_MD5_TZCODE="${PKG_MD5_TZCODE:-}"

# Configuráveis (expansíveis)
ADM_TZ_ZONEINFO_DIR="${ADM_TZ_ZONEINFO_DIR:-/usr/share/zoneinfo}"
ADM_TZ_DEFAULT="${ADM_TZ_DEFAULT:-Etc/UTC}"   # ex: America/Sao_Paulo
ADM_TZ_WRITE_ETC_TIMEZONE="${ADM_TZ_WRITE_ETC_TIMEZONE:-1}"

# Verificação GPG (opcional; exige gpg + chave)
ADM_TZ_VERIFY_GPG="${ADM_TZ_VERIFY_GPG:-0}"
ADM_TZ_GPG_KEY_FILE="${ADM_TZ_GPG_KEY_FILE:-}"   # caminho para .asc/.gpg com chave pública
###############################################################################
# Helpers
###############################################################################

_die() { echo "ERRO: $*" >&2; return 1; }

_need() { command -v "$1" >/dev/null 2>&1 || _die "requer '$1'"; }

_sha256_check() {
  # $1=arquivo $2=sha256
  [[ -n "$2" ]] || return 0
  _need sha256sum
  echo "$2  $1" | sha256sum -c - >/dev/null 2>&1 || _die "SHA256 não confere: $1"
}

_md5_check() {
  # $1=arquivo $2=md5
  [[ -n "$2" ]] || return 0
  _need md5sum
  echo "$2  $1" | md5sum -c - >/dev/null 2>&1 || _die "MD5 não confere: $1"
}

_gpg_verify_optional() {
  # $1=tarball_url $2=tarball_path
  [[ "$ADM_TZ_VERIFY_GPG" -eq 1 ]] || return 0
  _need gpg
  [[ -n "$ADM_TZ_GPG_KEY_FILE" && -f "$ADM_TZ_GPG_KEY_FILE" ]] || _die "ADM_TZ_GPG_KEY_FILE não definido/inesxistente"

  local sig="${2}.asc"
  curl -L --fail --retry 3 --retry-delay 2 -o "$sig" "${1}.asc" || _die "falha ao baixar assinatura: ${1}.asc"

  # keyring isolado para não poluir o ambiente do host
  local gpg_home="$PKG_BUILDDIR/.gpg"
  mkdir -p "$gpg_home"
  chmod 700 "$gpg_home"

  gpg --homedir "$gpg_home" --import "$ADM_TZ_GPG_KEY_FILE" >/dev/null 2>&1 || _die "falha ao importar chave GPG"
  gpg --homedir "$gpg_home" --verify "$sig" "$2" >/dev/null 2>&1 || _die "assinatura GPG inválida: $2"
}

###############################################################################
# Hooks adm
###############################################################################

pkg_prepare() {
  _need tar
  _need make
  _need gcc
  _need curl

  SRC_TZDATA="$PKG_WORKDIR/tzdata${PKG_VERSION}.tar.gz"
  SRC_TZCODE="$PKG_WORKDIR/tzcode${PKG_VERSION}.tar.gz"
  export SRC_TZDATA SRC_TZCODE

  # (Assumindo que seu fetch do adm já baixou os tarballs para $PKG_WORKDIR.
  #  Se não, você pode mover este trecho para o seu fetcher central.)
  [[ -f "$SRC_TZDATA" ]] || _die "tarball não encontrado: $SRC_TZDATA"
  [[ -f "$SRC_TZCODE" ]] || _die "tarball não encontrado: $SRC_TZCODE"

  # Verificação por checksum se fornecido
  _sha256_check "$SRC_TZDATA" "$PKG_SHA256_TZDATA"
  _sha256_check "$SRC_TZCODE" "$PKG_SHA256_TZCODE"
  _md5_check    "$SRC_TZDATA" "$PKG_MD5_TZDATA"
  _md5_check    "$SRC_TZCODE" "$PKG_MD5_TZCODE"

  # Verificação por assinatura (opcional; exige chave)
  _gpg_verify_optional "https://www.iana.org/time-zones/repository/releases/tzdata${PKG_VERSION}.tar.gz" "$SRC_TZDATA"
  _gpg_verify_optional "https://www.iana.org/time-zones/repository/releases/tzcode${PKG_VERSION}.tar.gz" "$SRC_TZCODE"

  BUILD_DIR="$PKG_BUILDDIR"
  mkdir -p "$BUILD_DIR"/{src,tzcode,tzdata,out}

  # Extrai
  tar -xf "$SRC_TZCODE" -C "$BUILD_DIR/tzcode"
  tar -xf "$SRC_TZDATA" -C "$BUILD_DIR/tzdata"

  # Alguns releases trazem yearistype.sh dentro de tzdata; garantimos path
  [[ -f "$BUILD_DIR/tzdata/yearistype.sh" ]] || _die "yearistype.sh não encontrado em tzdata (layout inesperado)"
  chmod +x "$BUILD_DIR/tzdata/yearistype.sh" || true
}

pkg_configure() {
  # tzcode não usa autoconf tradicional; compila via Makefile
  : # nada
}

pkg_build() {
  cd "$PKG_BUILDDIR/tzcode" || return 1

  # Compila zic/zdump nativos do host
  # (OBJDIR separado para não misturar com fontes)
  make $MAKEFLAGS CC="${BUILD_CC:-gcc}" \
    TOPDIR="$PKG_BUILDDIR/tzcode" \
    >/dev/null

  # Verifica binários essenciais
  [[ -x "$PKG_BUILDDIR/tzcode/zic" ]]   || _die "zic não foi gerado"
  [[ -x "$PKG_BUILDDIR/tzcode/zdump" ]] || echo "WARN: zdump não foi gerado (não crítico para instalar zoneinfo)" >&2
}

pkg_install() {
  local zic_bin="$PKG_BUILDDIR/tzcode/zic"
  local yearistype="$PKG_BUILDDIR/tzdata/yearistype.sh"
  local ZONEINFO="${ADM_TZ_ZONEINFO_DIR}"

  mkdir -p "$PKG_STAGEDIR$ZONEINFO"/{posix,right}
  mkdir -p "$PKG_STAGEDIR/etc"
  mkdir -p "$PKG_STAGEDIR/usr/share"

  cd "$PKG_BUILDDIR/tzdata" || return 1

  # LFS-style: gera conjuntos principais (sem leap), posix, e right (com leapseconds)
  # Mantemos a lista tradicional; "backward" ainda é útil para compat.
  local tzfiles=(
    etcetera southamerica northamerica europe africa antarctica
    asia australasia backward pacificnew systemv
  )

  local f
  for f in "${tzfiles[@]}"; do
    [[ -f "$f" ]] || continue

    "$zic_bin" -L /dev/null -d "$PKG_STAGEDIR$ZONEINFO" \
      -y "sh $yearistype" "$f" || _die "zic falhou: $f (main)"

    "$zic_bin" -L /dev/null -d "$PKG_STAGEDIR$ZONEINFO/posix" \
      -y "sh $yearistype" "$f" || _die "zic falhou: $f (posix)"

    # leapseconds (se existir)
    if [[ -f "leapseconds" ]]; then
      "$zic_bin" -L leapseconds -d "$PKG_STAGEDIR$ZONEINFO/right" \
        -y "sh $yearistype" "$f" || _die "zic falhou: $f (right)"
    fi
  done

  # Tabelas e metadados (LFS-style)
  for t in zone.tab zone1970.tab iso3166.tab; do
    [[ -f "$t" ]] && install -m 0644 -v "$t" "$PKG_STAGEDIR$ZONEINFO/"
  done

  # Define timezone padrão (configurável)
  if [[ -f "$PKG_STAGEDIR$ZONEINFO/$ADM_TZ_DEFAULT" ]]; then
    ln -snf "$ZONEINFO/$ADM_TZ_DEFAULT" "$PKG_STAGEDIR/etc/localtime"
    if [[ "$ADM_TZ_WRITE_ETC_TIMEZONE" -eq 1 ]]; then
      printf '%s\n' "$ADM_TZ_DEFAULT" >"$PKG_STAGEDIR/etc/timezone"
      chmod 0644 "$PKG_STAGEDIR/etc/timezone"
    fi
  else
    echo "WARN: timezone padrão não encontrado: $ADM_TZ_DEFAULT" >&2
    echo "      Ajuste ADM_TZ_DEFAULT (ex: America/Sao_Paulo) ou configure após instalar." >&2
  fi
}

pkg_check() {
  local ZONEINFO="${ADM_TZ_ZONEINFO_DIR}"
  local fail=0

  [[ -d "$PKG_STAGEDIR$ZONEINFO" ]] || { echo "FALTA: $ZONEINFO" >&2; fail=1; }

  # Um mínimo razoável
  [[ -f "$PKG_STAGEDIR$ZONEINFO/Etc/UTC" ]] || { echo "FALTA: Etc/UTC em zoneinfo" >&2; fail=1; }

  # posix e right (right depende de leapseconds, mas diretórios devem existir)
  [[ -d "$PKG_STAGEDIR$ZONEINFO/posix" ]] || { echo "FALTA: $ZONEINFO/posix" >&2; fail=1; }
  [[ -d "$PKG_STAGEDIR$ZONEINFO/right" ]] || { echo "FALTA: $ZONEINFO/right" >&2; fail=1; }

  # /etc/localtime symlink (se o TZ default existia)
  if [[ -L "$PKG_STAGEDIR/etc/localtime" ]]; then
    : # ok
  else
    echo "WARN: /etc/localtime não foi criado (provavelmente ADM_TZ_DEFAULT não existe)" >&2
  fi

  return "$fail"
}
