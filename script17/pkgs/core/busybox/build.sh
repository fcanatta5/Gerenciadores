#!/bin/sh
set -eu

# BusyBox 1.36.1
# Fonte oficial: https://busybox.net/downloads/busybox-1.36.1.tar.bz2  3
# SHA256 (orig tar.bz2): b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314 4

BB_URL="https://busybox.net/downloads/busybox-${PKGVER}.tar.bz2"
BB_TARBALL="${WORKDIR}/busybox-${PKGVER}.tar.bz2"
BB_SHA256="b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314"

# Default: build estático (ótimo para musl/bootstrap). Você pode desligar:
#   BUSYBOX_STATIC=0 ./pm.sh install core/busybox
: "${BUSYBOX_STATIC:=1}"

have() { command -v "$1" >/dev/null 2>&1; }

fetch_file() {
  url=$1 out=$2
  if have wget; then
    wget -O "$out.tmp" "$url"
  elif have curl; then
    curl -L -o "$out.tmp" "$url"
  else
    echo "ERRO: precisa de wget ou curl para baixar fontes." >&2
    exit 1
  fi
  mv -f "$out.tmp" "$out"
}

sha256_check() {
  file=$1 expected=$2
  got=$(sha256sum "$file" | awk '{print $1}')
  if [ "$got" != "$expected" ]; then
    echo "ERRO: SHA256 inválido para $(basename "$file")" >&2
    echo "Esperado: $expected" >&2
    echo "Obtido:   $got" >&2
    exit 1
  fi
}

hook_pre_install() { :; }
hook_post_install() { :; }
hook_pre_remove() { :; }
hook_post_remove() { :; }

pkg_fetch() {
  mkdir -p "$WORKDIR"

  if [ -f "$BB_TARBALL" ]; then
    sha256_check "$BB_TARBALL" "$BB_SHA256"
    return 0
  fi

  fetch_file "$BB_URL" "$BB_TARBALL"
  sha256_check "$BB_TARBALL" "$BB_SHA256"
}

pkg_unpack() {
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"

  # BusyBox vem em tar.bz2 (precisa de suporte a -j ou bunzip2/bzcat)
  if tar -tf "$BB_TARBALL" >/dev/null 2>&1; then
    :
  else
    echo "ERRO: não consegui ler o tarball. Seu tar precisa suportar .bz2 (ou instale bzip2)." >&2
    exit 1
  fi

  # Extração
  if tar -C "$SRCDIR" --strip-components=1 -xjf "$BB_TARBALL" >/dev/null 2>&1; then
    :
  else
    # fallback: bunzip2/bzcat
    if have bzcat; then
      bzcat "$BB_TARBALL" | tar -C "$SRCDIR" --strip-components=1 -xf -
    elif have bunzip2; then
      bunzip2 -c "$BB_TARBALL" | tar -C "$SRCDIR" --strip-components=1 -xf -
    else
      echo "ERRO: não foi possível extrair .tar.bz2 (precisa tar -j, ou bzcat/bunzip2)." >&2
      exit 1
    fi
  fi
}

# Ajusta .config: set/unset de forma robusta
cfg_set() {
  k=$1 v=$2
  f=.config
  if grep -q "^${k}=" "$f" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$f"
  elif grep -q "^# ${k} is not set" "$f" 2>/dev/null; then
    sed -i "s|^# ${k} is not set|${k}=${v}|" "$f"
  else
    printf "%s=%s\n" "$k" "$v" >>"$f"
  fi
}

cfg_unset() {
  k=$1
  f=.config
  if grep -q "^${k}=" "$f" 2>/dev/null; then
    sed -i "s|^${k}=.*|# ${k} is not set|" "$f"
  elif ! grep -q "^# ${k} is not set" "$f" 2>/dev/null; then
    printf "# %s is not set\n" "$k" >>"$f"
  fi
}

pkg_build() {
  cd "$SRCDIR"

  # Garantir estado limpo
  make distclean >/dev/null 2>&1 || true

  # Base: defconfig upstream (conjunto amplo de applets)
  make defconfig

  # Prefixo final (o install usa CONFIG_PREFIX para raiz de instalação)
  # Não é uma opção de .config; é argumento do make install.
  #
  # Ajustes "sem bloat" e com bom comportamento:
  # - desliga NLS (não puxa gettext)
  # - instala symlinks para applets (comportamento normal)
  cfg_unset CONFIG_FEATURE_NLS

  # Static por padrão (melhor para musl/bootstrap). Pode desligar via BUSYBOX_STATIC=0.
  if [ "$BUSYBOX_STATIC" = "1" ]; then
    cfg_set CONFIG_STATIC y
  else
    cfg_unset CONFIG_STATIC
  fi

  # Use o ash do busybox como shell (normalmente já vem)
  cfg_set CONFIG_ASH y

  # Garante consistência do .config (aceita defaults para novas opções)
  yes "" | make oldconfig >/dev/null

  # Compila
  make -j"$PM_JOBS"
}

pkg_install() {
  cd "$SRCDIR"

  # Instala sob DESTDIR+PM_PREFIX
  # Ex.: DESTDIR=/.../dest e PM_PREFIX=/usr/local => instala em .../dest/usr/local/{bin,sbin,...}
  make CONFIG_PREFIX="${DESTDIR}${PM_PREFIX}" install

  # BusyBox instala o binário e symlinks/hardlinks.
  # Opcional: instalar também applet "sh" no prefix se não veio (normalmente vem).
  # (sem ações extras aqui)
}
