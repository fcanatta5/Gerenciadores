# /opt/adm/packages/base/readline-8.3.sh
#
# readline 8.3 (base) — instala em /usr no rootfs do profile atual
# Alinhado ao adm.sh:
# - build() instala em DESTDIR="$PKG_BUILD_ROOT"
# - adm.sh empacota e extrai no $PKG_ROOTFS do profile
# - hook de sanity-check em post_install
#
# Dependências:
# - base/ncurses (terminfo/tinfo)
# - glibc (no profile glibc)
#
# Observações:
# - Build com shared libs e suporte a termcap/terminfo via ncurses.
# - Evita instalar docs/info em excesso (opcional).

PKG_NAME="readline"
PKG_VERSION="8.3"
PKG_DESC="GNU Readline library"
PKG_DEPENDS="glibc base/ncurses"
PKG_CATEGORY="base"
PKG_LIBC="glibc"

build() {
  local url="https://ftp.gnu.org/gnu/readline/readline-${PKG_VERSION}.tar.gz"
  local tar="readline-${PKG_VERSION}.tar.gz"
  local src

  src="$(fetch_source "$url" "$tar")"

  mkdir -p "$PKG_BUILD_WORK"
  cd "$PKG_BUILD_WORK"
  rm -rf "readline-${PKG_VERSION}" build
  tar xf "$src"

  cd "readline-${PKG_VERSION}"

  # readline costuma instalar manpages e docs; tudo bem.
  # Ajuste comum para não sobrescrever em /usr/share/info, se desejar:
  # (não é necessário; mantemos padrão upstream)

  mkdir -p "$PKG_BUILD_WORK/build"
  cd "$PKG_BUILD_WORK/build"

  # libdir por arquitetura (conservador)
  local libdir="/usr/lib"
  case "$(uname -m)" in
    x86_64|s390x|ppc64|ppc64le|aarch64) libdir="/usr/lib64" ;;
  esac

  # Configure
  # --with-curses => usa ncurses
  # --enable-shared => shared libs
  # --disable-static (opcional) para reduzir footprint
  ../readline-${PKG_VERSION}/configure \
    --prefix=/usr \
    --libdir="$libdir" \
    --disable-static \
    --with-curses

  make

  make install DESTDIR="$PKG_BUILD_ROOT"

  # Opcional: pkg-config (readline upstream nem sempre instala .pc)
  # Não inventamos .pc aqui para não divergir do upstream.
}

pre_install() {
  echo "==> [readline-${PKG_VERSION}] Instalando readline no rootfs do profile via adm"
}

post_install() {
  echo "==> [readline-${PKG_VERSION}] Sanity-check pós-instalação"

  local sysroot="${PKG_ROOTFS:-$ADM_CURRENT_ROOTFS}"

  # 1) Headers
  if [ ! -f "${sysroot}/usr/include/readline/readline.h" ]; then
    echo "ERRO: header ausente: ${sysroot}/usr/include/readline/readline.h"
    exit 1
  fi

  # 2) Bibliotecas
  local rl=""
  local hist=""

  if [ -f "${sysroot}/usr/lib/libreadline.so.8" ]; then
    rl="${sysroot}/usr/lib/libreadline.so.8"
  elif [ -f "${sysroot}/usr/lib64/libreadline.so.8" ]; then
    rl="${sysroot}/usr/lib64/libreadline.so.8"
  else
    rl="$(find "${sysroot}/usr/lib" "${sysroot}/usr/lib64" -maxdepth 2 -type f -name 'libreadline.so.*' 2>/dev/null | head -n1 || true)"
  fi

  if [ -f "${sysroot}/usr/lib/libhistory.so.8" ]; then
    hist="${sysroot}/usr/lib/libhistory.so.8"
  elif [ -f "${sysroot}/usr/lib64/libhistory.so.8" ]; then
    hist="${sysroot}/usr/lib64/libhistory.so.8"
  else
    hist="$(find "${sysroot}/usr/lib" "${sysroot}/usr/lib64" -maxdepth 2 -type f -name 'libhistory.so.*' 2>/dev/null | head -n1 || true)"
  fi

  if [ -z "$rl" ] || [ -z "$hist" ]; then
    echo "ERRO: libs readline/history não encontradas em ${sysroot}/usr/lib*"
    exit 1
  fi

  # 3) Linkedição de teste (não executa)
  local cc="${CC:-gcc}"
  if ! command -v "$cc" >/dev/null 2>&1; then
    echo "ERRO: compilador não encontrado para sanity-check (CC/gcc)."
    exit 1
  fi

  local tdir
  tdir="$(mktemp -d)"
  local test_c="${tdir}/t.c"
  local test_bin="${tdir}/t"

  cat > "$test_c" <<'EOF'
#include <readline/readline.h>
#include <readline/history.h>
int main(void) {
  using_history();
  return 0;
}
EOF

  # Preferência por ncurses wide se existir, fallback para -lncurses/-ltinfo.
  # Em muitos sistemas, readline linka com -lncursesw ou -ltinfo.
  local libs="-lreadline -lhistory -lncursesw"
  if ! "$cc" --sysroot="$sysroot" "$test_c" -o "$test_bin" $libs >/dev/null 2>&1; then
    libs="-lreadline -lhistory -lncurses"
    if ! "$cc" --sysroot="$sysroot" "$test_c" -o "$test_bin" $libs >/dev/null 2>&1; then
      libs="-lreadline -lhistory -ltinfo"
      if ! "$cc" --sysroot="$sysroot" "$test_c" -o "$test_bin" $libs >/dev/null 2>&1; then
        echo "ERRO: falha ao linkar programa de teste com readline."
        rm -rf "$tdir"
        exit 1
      fi
    fi
  fi

  # 4) Confere que o binário tem interpreter coerente (se disponível)
  if command -v readelf >/dev/null 2>&1; then
    local interp
    interp="$(readelf -l "$test_bin" 2>/dev/null | awk '/Requesting program interpreter/ {print $NF}' | tr -d '[]')"
    if [ -z "$interp" ]; then
      echo "ERRO: não foi possível extrair interpreter do teste (readelf)."
      rm -rf "$tdir"
      exit 1
    fi
    case "$interp" in
      /lib/*|/lib64/*) : ;;
      *)
        echo "ERRO: interpreter inesperado no teste: $interp"
        rm -rf "$tdir"
        exit 1
        ;;
    esac
  fi

  rm -rf "$tdir"

  echo "Sanity-check readline ${PKG_VERSION}: OK (headers + libs + linkedição)."
}
