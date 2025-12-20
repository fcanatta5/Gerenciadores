#!/bin/sh
set -eu

# Linux headers 6.18.1 (tarball oficial do kernel.org)
K_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PKGVER}.tar.xz"
K_TARBALL="${WORKDIR}/linux-${PKGVER}.tar.xz"

# SHA256 do linux-6.18.1.tar.xz
K_SHA256="d0a78bf3f0d12aaa10af3b5adcaed5bc767b5b78705e5ef885d5e930b72e25d5"

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
  if [ -f "$K_TARBALL" ]; then
    sha256_check "$K_TARBALL" "$K_SHA256"
    return 0
  fi
  fetch_file "$K_URL" "$K_TARBALL"
  sha256_check "$K_TARBALL" "$K_SHA256"
}

pkg_unpack() {
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"

  # Extração robusta de .tar.xz:
  # 1) tenta tar -xJf
  # 2) fallback: xz -dc | tar -xf -
  if tar -C "$SRCDIR" --strip-components=1 -xJf "$K_TARBALL" >/dev/null 2>&1; then
    :
  else
    if have xz; then
      xz -dc "$K_TARBALL" | tar -C "$SRCDIR" --strip-components=1 -xf -
    else
      echo "ERRO: não foi possível extrair .tar.xz (precisa tar com -J ou xz)." >&2
      exit 1
    fi
  fi
}

pkg_build() {
  # linux-headers não precisa “compilar” o kernel.
  # Apenas garantimos uma tree limpa o suficiente para headers_install.
  cd "$SRCDIR"
  make mrproper >/dev/null 2>&1 || true
}

pkg_install() {
  cd "$SRCDIR"

  # Este pacote é para o pm-bootstrap.sh:
  # - TC_SYSROOT aponta para o sysroot temporário.
  # - Precisamos instalar headers em: $TC_SYSROOT/usr/include
  #
  # IMPORTANTE: não use PM_PREFIX aqui. Headers vão para /usr/include do SYSROOT.
  if [ -z "${TC_SYSROOT:-}" ]; then
    echo "ERRO: TC_SYSROOT não definido. Esta receita é para uso com pm-bootstrap.sh." >&2
    exit 1
  fi

  # INSTALAÇÃO NO SYSROOT:
  # DESTDIR é staging do pm; adicionamos TC_SYSROOT por fora.
  mkdir -p "$DESTDIR$TC_SYSROOT/usr"

  # headers_install cria /usr/include/linux etc.
  make -j"$PM_JOBS" headers_install INSTALL_HDR_PATH="$DESTDIR$TC_SYSROOT/usr"

  # Algumas árvores deixam lixo de build; removemos o que não deve ir para headers.
  # (melhor esforço; não falhar se não existir)
  rm -rf "$DESTDIR$TC_SYSROOT/usr/include/.install" 2>/dev/null || true
  find "$DESTDIR$TC_SYSROOT/usr/include" -name '.*' -type f -delete 2>/dev/null || true
}
