#!/bin/sh
set -eu

# musl 1.2.5 (Feb 29, 2024) 4
# Fonte: http://musl.libc.org/releases/musl-1.2.5.tar.gz 5
# SHA256: a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4 6
#
# Segurança: aplicar patches relacionados ao CVE-2025-26519 (iconv EUC-KR -> UTF-8) 7
#   - e5adcd97b519... 8
#   - c47ad25ea3b4... 9

MUSL_URL="http://musl.libc.org/releases/musl-${PKGVER}.tar.gz"
MUSL_TARBALL="${WORKDIR}/musl-${PKGVER}.tar.gz"
MUSL_SHA256="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

# Variáveis vindas do pm-bootstrap.sh
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

# musl usa "ARCH" próprio; mapeamos pelo TARGET
musl_arch_from_target() {
  t=${TARGET%%-*}
  case "$t" in
    x86_64) echo x86_64 ;;
    i386|i486|i586|i686) echo i386 ;;
    aarch64) echo aarch64 ;;
    arm*) echo arm ;;
    riscv64) echo riscv64 ;;
    riscv32) echo riscv32 ;;
    mips64*) echo mips64 ;;
    mips*) echo mips ;;
    powerpc64le|ppc64le) echo powerpc64le ;;
    powerpc64|ppc64) echo powerpc64 ;;
    powerpc|ppc) echo powerpc ;;
    s390x) echo s390x ;;
    *) echo "$t" ;;
  esac
}

pkg_fetch() {
  mkdir -p "$WORKDIR"
  if [ -f "$MUSL_TARBALL" ]; then
    sha256_check "$MUSL_TARBALL" "$MUSL_SHA256"
    return 0
  fi
  fetch_file "$MUSL_URL" "$MUSL_TARBALL"
  sha256_check "$MUSL_TARBALL" "$MUSL_SHA256"
}

pkg_unpack() {
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"
  tar -C "$SRCDIR" --strip-components=1 -xzf "$MUSL_TARBALL"
  # Patches são aplicados automaticamente pelo seu pm (pasta patch/).
}

pkg_build() {
  [ -n "${TC_SYSROOT:-}" ] || { echo "ERRO: TC_SYSROOT vazio (bootstrap)"; exit 1; }
  case "$TC_SYSROOT" in
    /*) : ;;
    *) echo "ERRO: TC_SYSROOT deve ser path absoluto: '$TC_SYSROOT'" >&2; exit 1 ;;
  esac

  # Garante que a toolchain stage1 esteja no PATH
  export PATH="$PM_PREFIX/bin:$PATH"

  # Preferir o cross-gcc do stage1, se existir
  if [ -x "$PM_PREFIX/bin/${TARGET}-gcc" ]; then
    CC_BIN="$PM_PREFIX/bin/${TARGET}-gcc"
  else
    # fallback (não ideal no bootstrap)
    CC_BIN="${CC:-cc}"
  fi

  cd "$SRCDIR"

  # Limpeza forte (musl build fica em-tree em ./obj e gera config.mak)
  rm -rf obj
  rm -f config.mak

  # musl deve ser instalado no SYSROOT temporário, mas com prefix "normal" (/usr, /lib)
  # Para isso: configure com prefix=/usr e syslibdir=/lib.
  #
  # A instalação real será feita com DESTDIR="$DESTDIR$TC_SYSROOT" no pkg_install.
  #
  arch=$(musl_arch_from_target)

  # Flags prudentes para bootstrap
  # -fno-plt e afins podem quebrar em toolchain mínima; mantemos enxuto.
  # O sysroot será usado na fase gcc-final; aqui queremos somente compilar musl.
  #
  CC="$CC_BIN" \
  ./configure \
    --prefix=/usr \
    --syslibdir=/lib \
    --target="$TARGET" \
    --enable-wrapper=no \
    --disable-gcc-wrapper \
    --disable-static \
    --enable-shared

  # musl build: definir ARCH ajuda em alguns casos (depende do configure detectar)
  # Não falha se ignorado.
  make -j"$PM_JOBS" ARCH="$arch"
}

pkg_install() {
  [ -n "${TC_SYSROOT:-}" ] || { echo "ERRO: TC_SYSROOT vazio (bootstrap)"; exit 1; }
  case "$TC_SYSROOT" in
    /*) : ;;
    *) echo "ERRO: TC_SYSROOT deve ser path absoluto: '$TC_SYSROOT'" >&2; exit 1 ;;
  esac

  cd "$SRCDIR"

  # Instalar no sysroot temporário:
  #   DESTDIR/<TC_SYSROOT>/{usr/include,lib,...}
  #
  # Isso garante que o tar do pm crie caminhos absolutos /<TC_SYSROOT>/... quando instalado.
  make DESTDIR="${DESTDIR}${TC_SYSROOT}" install

  # Sanidade mínima: garantir que o loader e libc existem no sysroot
  # (nome do loader depende do arch, ex.: ld-musl-x86_64.so.1)
  if ! find "${DESTDIR}${TC_SYSROOT}/lib" -maxdepth 1 -type f -name 'ld-musl-*.so.1' >/dev/null 2>&1; then
    echo "WARN: não encontrei ld-musl-*.so.1 em ${DESTDIR}${TC_SYSROOT}/lib" >&2
  fi

  if [ ! -e "${DESTDIR}${TC_SYSROOT}/lib/libc.so" ] && [ ! -e "${DESTDIR}${TC_SYSROOT}/lib/libc.so.1" ]; then
    echo "WARN: não encontrei libc.so/libc.so.1 em ${DESTDIR}${TC_SYSROOT}/lib" >&2
  fi

  # Remove qualquer .la (musl normalmente não cria, mas mantemos limpo)
  find "${DESTDIR}${TC_SYSROOT}" -type f -name "*.la" -delete 2>/dev/null || true
}
