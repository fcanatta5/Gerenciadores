#!/bin/sh
set -eu

# Linux kernel headers 6.18.1
# Fonte: https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.1.tar.xz  2
# SHA256 (linux-6.18.1.tar.xz): d0a78bf3f0d12aaa10af3b5adcaed5bc767b5b78705e5ef885d5e930b72e25d5 3

KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PKGVER}.tar.xz"
KERNEL_TARBALL="${WORKDIR}/linux-${PKGVER}.tar.xz"
KERNEL_SHA256="d0a78bf3f0d12aaa10af3b5adcaed5bc767b5b78705e5ef885d5e930b72e25d5"

# Esperado do pm-bootstrap.sh:
: "${TARGET:=x86_64-linux-musl}"
: "${TC_SYSROOT:=}"
: "${BOOTSTRAP:=0}"

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

karch_from_target() {
  # Kernel usa ARCH "x86" para x86_64/i386. Mantemos o resto simples.
  t=${TARGET%%-*}
  case "$t" in
    x86_64|i386|i486|i586|i686) echo x86 ;;
    aarch64) echo arm64 ;;
    arm*) echo arm ;;
    riscv64) echo riscv ;;
    mips*) echo mips ;;
    powerpc64le|ppc64le) echo powerpc ;;
    powerpc*|ppc*) echo powerpc ;;
    s390x) echo s390 ;;
    *) echo "$t" ;;
  esac
}

pkg_fetch() {
  mkdir -p "$WORKDIR"
  if [ -f "$KERNEL_TARBALL" ]; then
    sha256_check "$KERNEL_TARBALL" "$KERNEL_SHA256"
    return 0
  fi
  fetch_file "$KERNEL_URL" "$KERNEL_TARBALL"
  sha256_check "$KERNEL_TARBALL" "$KERNEL_SHA256"
}

pkg_unpack() {
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"
  tar -C "$SRCDIR" --strip-components=1 -xJf "$KERNEL_TARBALL"
}

pkg_build() {
  # Para headers_install, não precisamos compilar kernel.
  # Ainda assim, garantimos limpeza mínima de artefatos.
  cd "$SRCDIR"
  make mrproper >/dev/null 2>&1 || true
}

pkg_install() {
  # Headers devem ir para o SYSROOT temporário.
  # O pm instala extraindo em '/', então colocamos os paths absolutos do sysroot
  # *dentro do DESTDIR* para o tarball produzir /<TC_SYSROOT>/usr/include.
  [ -n "${TC_SYSROOT:-}" ] || { echo "ERRO: TC_SYSROOT vazio (bootstrap)"; exit 1; }

  case "$TC_SYSROOT" in
    /*) : ;;
    *) echo "ERRO: TC_SYSROOT deve ser path absoluto: '$TC_SYSROOT'" >&2; exit 1 ;;
  esac

  karch=$(karch_from_target)

  cd "$SRCDIR"

  # Instala em: <TC_SYSROOT>/usr/include
  # O alvo é: DESTDIR/<TC_SYSROOT>/usr/include (para o tarball criar /<TC_SYSROOT>/usr/include)
  hdr_root="${DESTDIR}${TC_SYSROOT}/usr"
  mkdir -p "$hdr_root"

  make ARCH="$karch" \
    INSTALL_HDR_PATH="$hdr_root" \
    headers_install

  # Limpeza padrão de headers_install (remove arquivos de build markers)
  find "$hdr_root/include" -name '.install' -o -name '..install.cmd' 2>/dev/null | xargs -r rm -f 2>/dev/null || true
}
