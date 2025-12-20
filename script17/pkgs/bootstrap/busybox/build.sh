#!/bin/sh
set -eu

# BusyBox 1.36.1
# Fonte: https://busybox.net/downloads/busybox-1.36.1.tar.bz2 2
# SHA256: b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314 3

BB_URL="https://busybox.net/downloads/busybox-${PKGVER}.tar.bz2"
BB_TARBALL="${WORKDIR}/busybox-${PKGVER}.tar.bz2"
BB_SHA256="b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314"

# Variáveis vindas do pm-bootstrap.sh
: "${TARGET:=x86_64-linux-musl}"
: "${TC_SYSROOT:=}"
: "${BOOTSTRAP:=0}"

# Default: static (melhor para sysroot bootstrap/chroot)
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

  # BusyBox vem em .tar.bz2; tentamos tar -xjf e caímos para bzcat/bunzip2 se necessário.
  if tar -C "$SRCDIR" --strip-components=1 -xjf "$BB_TARBALL" >/dev/null 2>&1; then
    :
  else
    if have bzcat; then
      bzcat "$BB_TARBALL" | tar -C "$SRCDIR" --strip-components=1 -xf -
    elif have bunzip2; then
      bunzip2 -c "$BB_TARBALL" | tar -C "$SRCDIR" --strip-components=1 -xf -
    else
      echo "ERRO: não foi possível extrair .tar.bz2 (precisa tar -j ou bzcat/bunzip2)." >&2
      exit 1
    fi
  fi
}

cfg_set() {
  k=$1 v=$2 f=.config
  if grep -q "^${k}=" "$f" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$f"
  elif grep -q "^# ${k} is not set" "$f" 2>/dev/null; then
    sed -i "s|^# ${k} is not set|${k}=${v}|" "$f"
  else
    printf "%s=%s\n" "$k" "$v" >>"$f"
  fi
}

cfg_unset() {
  k=$1 f=.config
  if grep -q "^${k}=" "$f" 2>/dev/null; then
    sed -i "s|^${k}=.*|# ${k} is not set|" "$f"
  elif ! grep -q "^# ${k} is not set" "$f" 2>/dev/null; then
    printf "# %s is not set\n" "$k" >>"$f"
  fi
}

pkg_build() {
  [ -n "${TC_SYSROOT:-}" ] || { echo "ERRO: TC_SYSROOT vazio (bootstrap)"; exit 1; }
  case "$TC_SYSROOT" in
    /*) : ;;
    *) echo "ERRO: TC_SYSROOT deve ser path absoluto: '$TC_SYSROOT'" >&2; exit 1 ;;
  esac

  cd "$SRCDIR"

  # Forçar uso do cross-gcc final do toolchain temporário
  export PATH="$PM_PREFIX/bin:$PATH"
  if [ -x "$PM_PREFIX/bin/${TARGET}-gcc" ]; then
    export CROSS_COMPILE="${TARGET}-"
    export CC="${TARGET}-gcc"
  fi

  make distclean >/dev/null 2>&1 || true
  make defconfig

  # Queremos um sysroot "executável":
  # - /bin/sh (ash)
  # - applets instalados como symlinks
  cfg_set CONFIG_ASH y
  cfg_set CONFIG_SH_IS_ASH y
  cfg_set CONFIG_FEATURE_SH_STANDALONE y
  cfg_set CONFIG_INSTALL_APPLET_SYMLINKS y

  # Sem NLS (evita dependências)
  cfg_unset CONFIG_FEATURE_NLS

  # Ferramentas úteis para bootstrap de pacotes e extrações
  cfg_set CONFIG_TAR y
  cfg_set CONFIG_GZIP y
  cfg_set CONFIG_GUNZIP y
  cfg_set CONFIG_BUNZIP2 y
  cfg_set CONFIG_BZCAT y
  cfg_set CONFIG_UNXZ y
  cfg_set CONFIG_XZ y
  cfg_set CONFIG_SHA256SUM y
  cfg_set CONFIG_SHA1SUM y
  cfg_set CONFIG_MD5SUM y

  # Static por padrão
  if [ "$BUSYBOX_STATIC" = "1" ]; then
    cfg_set CONFIG_STATIC y
  else
    cfg_unset CONFIG_STATIC
  fi

  # Aceitar defaults para opções novas
  yes "" | make oldconfig >/dev/null

  make -j"$PM_JOBS"
}

pkg_install() {
  [ -n "${TC_SYSROOT:-}" ] || { echo "ERRO: TC_SYSROOT vazio (bootstrap)"; exit 1; }
  case "$TC_SYSROOT" in
    /*) : ;;
    *) echo "ERRO: TC_SYSROOT deve ser path absoluto: '$TC_SYSROOT'" >&2; exit 1 ;;
  esac

  cd "$SRCDIR"

  # Instala dentro do sysroot temporário:
  # DESTDIR + TC_SYSROOT vira raiz do install do busybox.
  # Isso gera paths no tarball como /<TC_SYSROOT>/bin/...
  make CONFIG_PREFIX="${DESTDIR}${TC_SYSROOT}" install

  # Garantir /bin/sh no sysroot (normalmente já sai do install via symlink)
  if [ ! -e "${DESTDIR}${TC_SYSROOT}/bin/sh" ]; then
    ln -s busybox "${DESTDIR}${TC_SYSROOT}/bin/sh" 2>/dev/null || true
  fi
}
