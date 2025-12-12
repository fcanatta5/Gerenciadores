# /opt/adm/packages/base/binutils-2.45.1.sh
#
# Binutils 2.45.1 (base/final) — instala em /usr no rootfs do profile atual
# 100% alinhado ao adm.sh:
# - build() instala em DESTDIR="$PKG_BUILD_ROOT"
# - adm.sh empacota e extrai no $PKG_ROOTFS do profile
# - hooks e sanity-check usam caminhos absolutos no rootfs para evitar pegar tools do host
#
# Observações:
# - Esta é a "versão base" (não bootstrap). Portanto usa prefixo /usr.
# - Requer um compilador funcional para sanity-check (gcc/CC) no ambiente do profile.

PKG_NAME="binutils"
PKG_VERSION="2.45.1"
PKG_DESC="GNU Binutils (base system, /usr)"
PKG_DEPENDS="glibc"
PKG_CATEGORY="base"
PKG_LIBC=""

build() {
  local url="https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
  local tar="binutils-${PKG_VERSION}.tar.xz"
  local src

  src="$(fetch_source "$url" "$tar")"

  mkdir -p "$PKG_BUILD_WORK"
  cd "$PKG_BUILD_WORK"
  rm -rf "binutils-${PKG_VERSION}" build
  tar xf "$src"
  mkdir -p build
  cd build

  # sysroot do profile atual
  local sysroot="$PKG_ROOTFS"

  # Configure para /usr
  # flags escolhidas para um sistema base (sem werror, plugins, gold, etc.)
  ../binutils-${PKG_VERSION}/configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --enable-ld=default \
    --enable-gold \
    --enable-plugins \
    --disable-multilib \
    --disable-werror \
    --disable-nls

  make

  # Instala no DESTDIR do pacote (adm empacota e depois instala no rootfs real)
  make install DESTDIR="$PKG_BUILD_ROOT"

  # Remoções/ajustes opcionais e seguros:
  # - Info pages normalmente vão para /usr/share/info (ok)
  # - Nada agressivo aqui para não quebrar integração.
}

pre_install() {
  echo "==> [binutils-${PKG_VERSION}] Instalando Binutils base (/usr) no rootfs do profile via adm"
}

post_install() {
  echo "==> [binutils-${PKG_VERSION}] Sanity-check pós-instalação (binutils base)"

  local sysroot="${PKG_ROOTFS:-$ADM_CURRENT_ROOTFS}"
  local ubin="${sysroot}/usr/bin"

  # 1) Verifica binários principais instalados NO rootfs do profile
  local need=(
    "ld"
    "as"
    "ar"
    "ranlib"
    "objdump"
    "readelf"
    "strip"
    "nm"
  )

  local b
  for b in "${need[@]}"; do
    if [ ! -x "${ubin}/${b}" ]; then
      echo "ERRO: binário ausente/não executável no rootfs: ${ubin}/${b}"
      exit 1
    fi
  done

  # 2) Verifica versão reportada (não precisa ser string idêntica, mas deve conter 2.45.1)
  if ! "${ubin}/ld" --version 2>/dev/null | head -n1 | grep -q "2\.45\.1"; then
    echo "ERRO: ld --version não indica ${PKG_VERSION} (pode ter instalado versão errada)."
    "${ubin}/ld" --version 2>/dev/null | head -n2 || true
    exit 1
  fi

  # 3) Teste de fluxo mínimo: compilar objeto e fazer link-relocatable com ld
  #    (Não executa binário, apenas valida toolchain básico)
  local cc="${CC:-gcc}"
  if ! command -v "$cc" >/dev/null 2>&1; then
    echo "ERRO: compilador não encontrado para sanity-check (CC/gcc)."
    echo "Sugestão: instale um gcc funcional no profile antes de instalar binutils base."
    exit 1
  fi

  local tdir
  tdir="$(mktemp -d)"
  local cfile="${tdir}/t.c"
  local ofile="${tdir}/t.o"
  local rfile="${tdir}/t.r.o"

  cat > "$cfile" <<'EOF'
int foo(void) { return 42; }
int main(void) { return foo(); }
EOF

  # Compila para objeto (não depende de libc para executar; só headers básicos do compilador)
  if ! "$cc" --sysroot="$sysroot" -c "$cfile" -o "$ofile" >/dev/null 2>&1; then
    echo "ERRO: falha ao compilar objeto com sysroot=${sysroot} (gcc/headers/sysroot)."
    rm -rf "$tdir"
    exit 1
  fi

  # ld -r cria objeto relocável (não depende de libc/link final)
  if ! "${ubin}/ld" -r "$ofile" -o "$rfile" >/dev/null 2>&1; then
    echo "ERRO: falha ao rodar ld -r usando ${ubin}/ld"
    rm -rf "$tdir"
    exit 1
  fi

  # 4) Checagem rápida: readelf/objdump conseguem ler o objeto gerado
  "${ubin}/readelf" -h "$rfile" >/dev/null 2>&1 || {
    echo "ERRO: readelf falhou ao inspecionar objeto relocável."
    rm -rf "$tdir"
    exit 1
  }

  "${ubin}/objdump" -f "$rfile" >/dev/null 2>&1 || {
    echo "ERRO: objdump falhou ao inspecionar objeto relocável."
    rm -rf "$tdir"
    exit 1
  }

  rm -rf "$tdir"

  echo "Sanity-check binutils base ${PKG_VERSION}: OK (/usr/bin/* presentes e toolchain mínimo funcional)."
}
