# /opt/adm/packages/base/ncurses-6.5.sh
#
# ncurses 6.5 (base) — instala em /usr no rootfs do profile atual
# Alinhado ao adm.sh:
# - build() instala em DESTDIR="$PKG_BUILD_ROOT"
# - adm.sh empacota e extrai no $PKG_ROOTFS do profile
# - sanity-check em post_install (binários + libs + terminfo)
#
# Observações:
# - Compila wide-char (ncursesw) e cria links de compatibilidade.
# - Instala terminfo em /usr/share/terminfo.
#
# Dependências mínimas:
# - glibc (ou musl, se estiver no profile musl com toolchain apropriado)
# - ferramenta de build funcional (make, gcc, etc.)

PKG_NAME="ncurses"
PKG_VERSION="6.5"
PKG_DESC="ncurses terminal handling library"
PKG_DEPENDS="glibc"
PKG_CATEGORY="base"
PKG_LIBC="glibc"

build() {
  local url="https://ftp.gnu.org/gnu/ncurses/ncurses-${PKG_VERSION}.tar.gz"
  local tar="ncurses-${PKG_VERSION}.tar.gz"
  local src

  src="$(fetch_source "$url" "$tar")"

  mkdir -p "$PKG_BUILD_WORK"
  cd "$PKG_BUILD_WORK"
  rm -rf "ncurses-${PKG_VERSION}" build
  tar xf "$src"

  cd "ncurses-${PKG_VERSION}"

  # Ajuste recomendado: evita hardcode de /usr/lib/terminfo em alguns cenários
  sed -i 's@^#define DEFAULT_TERMINFO_DIRS.*@#define DEFAULT_TERMINFO_DIRS "/usr/share/terminfo:/usr/share/terminfo"@' \
    include/ncurses_cfg.h.in 2>/dev/null || true

  mkdir -p "$PKG_BUILD_WORK/build"
  cd "$PKG_BUILD_WORK/build"

  # libdir por arquitetura (conservador)
  local libdir="/usr/lib"
  case "$(uname -m)" in
    x86_64|s390x|ppc64|ppc64le|aarch64) libdir="/usr/lib64" ;;
  esac

  # Build/install wide-char
  ../ncurses-${PKG_VERSION}/configure \
    --prefix=/usr \
    --libdir="$libdir" \
    --mandir=/usr/share/man \
    --with-shared \
    --without-debug \
    --without-ada \
    --enable-widec \
    --enable-pc-files \
    --with-pkg-config-libdir="${libdir}/pkgconfig" \
    --with-termlib \
    --enable-overwrite

  make

  make install DESTDIR="$PKG_BUILD_ROOT"

  # Symlinks de compatibilidade: libncurses.so -> libncursesw.so etc.
  # (Muitos pacotes esperam nomes sem 'w'.)
  local D="$PKG_BUILD_ROOT"
  local L="${D}${libdir}"
  if [ -d "$L" ]; then
    for lib in ncurses form panel menu tinfo; do
      if [ -e "${L}/lib${lib}w.so" ] && [ ! -e "${L}/lib${lib}.so" ]; then
        ln -s "lib${lib}w.so" "${L}/lib${lib}.so"
      fi
      # alguns casos já existem .so -> .so.6; não forçamos
    done
  fi

  # pkg-config compat para nomes sem w
  local pcdir="${D}${libdir}/pkgconfig"
  if [ -d "$pcdir" ]; then
    for pc in ncurses form panel menu tinfo; do
      if [ -f "${pcdir}/${pc}w.pc" ] && [ ! -f "${pcdir}/${pc}.pc" ]; then
        ln -s "${pc}w.pc" "${pcdir}/${pc}.pc"
      fi
    done
  fi
}

pre_install() {
  echo "==> [ncurses-${PKG_VERSION}] Instalando ncurses no rootfs do profile via adm"
}

post_install() {
  echo "==> [ncurses-${PKG_VERSION}] Sanity-check pós-instalação"

  local sysroot="${PKG_ROOTFS:-$ADM_CURRENT_ROOTFS}"

  # 1) Binários essenciais no rootfs
  local need_bins=(
    "${sysroot}/usr/bin/tic"
    "${sysroot}/usr/bin/infocmp"
    "${sysroot}/usr/bin/tput"
  )
  local b
  for b in "${need_bins[@]}"; do
    if [ ! -x "$b" ]; then
      echo "ERRO: binário ncurses ausente/não executável: $b"
      exit 1
    fi
  done

  # 2) Biblioteca wide
  local lib_found=""
  if [ -f "${sysroot}/usr/lib/libncursesw.so.6" ]; then
    lib_found="${sysroot}/usr/lib/libncursesw.so.6"
  elif [ -f "${sysroot}/usr/lib64/libncursesw.so.6" ]; then
    lib_found="${sysroot}/usr/lib64/libncursesw.so.6"
  else
    lib_found="$(find "${sysroot}/usr/lib" "${sysroot}/usr/lib64" -maxdepth 2 -type f -name 'libncursesw.so.*' 2>/dev/null | head -n1 || true)"
  fi
  if [ -z "$lib_found" ]; then
    echo "ERRO: libncursesw.so.* não encontrada em ${sysroot}/usr/lib*"
    exit 1
  fi

  # 3) terminfo deve existir
  if [ ! -d "${sysroot}/usr/share/terminfo" ]; then
    echo "ERRO: diretório terminfo ausente: ${sysroot}/usr/share/terminfo"
    exit 1
  fi

  # 4) Teste rápido: infocmp deve conseguir ler um entry comum (xterm)
  # (Sem executar um binário dentro do chroot; usa a base de terminfo do rootfs)
  # Infocmp usa TERMINFO/TERMINFO_DIRS; apontamos explicitamente para o sysroot.
  local out
  out="$("${sysroot}/usr/bin/infocmp" -A "${sysroot}/usr/share/terminfo" xterm 2>/dev/null | head -n1 || true)"
  if [ -z "$out" ]; then
    # fallback: tenta "linux"
    out="$("${sysroot}/usr/bin/infocmp" -A "${sysroot}/usr/share/terminfo" linux 2>/dev/null | head -n1 || true)"
  fi
  if [ -z "$out" ]; then
    echo "ERRO: infocmp não conseguiu ler terminfo (xterm/linux) a partir do rootfs."
    exit 1
  fi

  echo "Sanity-check ncurses ${PKG_VERSION}: OK (bins + libs + terminfo)."
}
