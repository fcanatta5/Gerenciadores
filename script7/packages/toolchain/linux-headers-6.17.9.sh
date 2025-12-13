###############################################################################
# Linux headers 6.17.9 (toolchain) - instala somente headers no SYSROOT
# Compatível com adm (PKG_WORKDIR/PKG_BUILDDIR/PKG_STAGEDIR, CTARGET, SYSROOT)
###############################################################################

PKG_CATEGORY="toolchain"
PKG_NAME="linux-headers"
PKG_VERSION="6.17.9"
PKG_RELEASE="1"
PKG_DESC="Linux kernel headers ${PKG_VERSION} para sysroot do target"
PKG_LICENSE="GPL-2.0"
PKG_SITE="https://www.kernel.org/"

PKG_DEPENDS=()

PKG_URLS=(
  "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
  "https://www.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
)

# SHA256 do linux-6.17.9.tar.xz
PKG_SHA256="6d08803b953c509df48d44d3281ed392524321d8bb353eb21c0555790c8f8e06"

###############################################################################
# Helpers locais do pacote (permitidos)
###############################################################################
_karch_from_target() {
  # Mapeia CTARGET -> ARCH do kernel
  # Cobertura prática (pode expandir)
  case "${CTARGET}" in
    x86_64-*)   echo "x86" ;;
    i?86-*)     echo "x86" ;;
    aarch64-*)  echo "arm64" ;;
    armv7*-*|armv6*-*|arm-*) echo "arm" ;;
    riscv64-*)  echo "riscv" ;;
    powerpc64le-*|ppc64le-*) echo "powerpc" ;;
    powerpc64-*|ppc64-*)     echo "powerpc" ;;
    powerpc-*|ppc-*)         echo "powerpc" ;;
    mips64el-*|mips64-*)     echo "mips" ;;
    mipsel-*|mips-*)         echo "mips" ;;
    s390x-*)    echo "s390" ;;
    loongarch64-*) echo "loongarch" ;;
    *) echo "" ;;
  esac
}

###############################################################################
# Hooks
###############################################################################

pkg_prepare() {
  # Diretório fonte
  SRC_DIR="$PKG_WORKDIR/linux-${PKG_VERSION}"
  [[ -d "$SRC_DIR" ]] || {
    SRC_DIR="$(find "$PKG_WORKDIR" -maxdepth 1 -type d | tail -n +2 | head -n1)"
  }
  export SRC_DIR

  # Determina ARCH do kernel a partir do CTARGET
  KARCH="$(_karch_from_target)"
  [[ -n "$KARCH" ]] || {
    echo "ERRO: não consegui mapear CTARGET='${CTARGET}' para ARCH do kernel" >&2
    return 1
  }
  export KARCH

  # Não precisamos de build dir separado para headers_install, mas mantemos consistente
  mkdir -p "$PKG_BUILDDIR"
}

pkg_build() {
  cd "$SRC_DIR"

  # Requisitos típicos do build system de headers
  command -v make >/dev/null 2>&1 || return 1
  command -v rsync >/dev/null 2>&1 || return 1

  # Limpa para evitar “vazamento” de config anterior
  # (mrproper é o recomendado para preparo limpo dos headers)
  make mrproper

  # Headers "sanitizados" (algumas árvores exigem este passo)
  # O ARCH/HOSTCC garantem que não tenta usar cross para ferramentas do host
  make ARCH="$KARCH" HOSTCC=gcc headers
}

pkg_install() {
  cd "$SRC_DIR"

  # Instala para STAGE em /usr/include (o kernel vai criar include/)
  # headers_install copia e sanitiza (UAPI)
  make \
    ARCH="$KARCH" \
    HOSTCC=gcc \
    INSTALL_HDR_PATH="$PKG_STAGEDIR/usr" \
    headers_install

  # Higiene: remove arquivos não desejados que às vezes aparecem
  # (mantém apenas headers reais)
  find "$PKG_STAGEDIR/usr/include" \
    \( -name '.install' -o -name '..install.cmd' -o -name '*.cmd' \) \
    -type f -delete 2>/dev/null || true
}

pkg_check() {
  # Checagens mínimas e objetivas
  local fail=0

  # Pasta esperada
  if [[ ! -d "$PKG_STAGEDIR/usr/include" ]]; then
    echo "FALTA: $PKG_STAGEDIR/usr/include" >&2
    fail=1
  fi

  # Arquivos representativos
  if [[ ! -f "$PKG_STAGEDIR/usr/include/linux/types.h" ]]; then
    echo "FALTA: linux/types.h (headers não instalados corretamente)" >&2
    fail=1
  fi

  # UAPI: deve existir
  if [[ ! -f "$PKG_STAGEDIR/usr/include/asm-generic/int-ll64.h" ]]; then
    echo "FALTA: asm-generic/int-ll64.h" >&2
    fail=1
  fi

  return "$fail"
}
