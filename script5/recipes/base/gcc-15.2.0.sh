# /opt/adm/packages/base/gcc-15.2.0.sh
#
# GCC 15.2.0 (base/final) — instala em /usr no rootfs do profile atual
# - DESTDIR=$PKG_BUILD_ROOT (adm empacota e extrai no rootfs do profile)
# - habilita linguagens: C, C++
# - instala libgcc, libstdc++
# - sanity-check pós-instalação: valida gcc/g++ instalados no rootfs, compila e linka teste C/C++
#
# Dependências mínimas esperadas no profile (para um sistema base):
# - glibc (headers + loader + libs)
# - base/binutils (ld/as/ar etc. em /usr/bin)
# - linux-headers (para sysroot headers)
#
# Observação:
# - Esta receita embute GMP/MPFR/MPC (para reduzir dependências externas).

PKG_NAME="gcc"
PKG_VERSION="15.2.0"
PKG_DESC="GNU Compiler Collection (final, C/C++)"
PKG_DEPENDS="glibc base/binutils linux-headers"
PKG_CATEGORY="base"
PKG_LIBC="glibc"

build() {
  local gcc_url="https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  local gcc_tar="gcc-${PKG_VERSION}.tar.xz"

  local mpfr_url="https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz"
  local mpfr_tar="mpfr-4.2.1.tar.xz"
  local gmp_url="https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
  local gmp_tar="gmp-6.3.0.tar.xz"
  local mpc_url="https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"
  local mpc_tar="mpc-1.3.1.tar.gz"

  local gcc_src mpfr_src gmp_src mpc_src
  gcc_src="$(fetch_source "$gcc_url" "$gcc_tar")"
  mpfr_src="$(fetch_source "$mpfr_url" "$mpfr_tar")"
  gmp_src="$(fetch_source "$gmp_url" "$gmp_tar")"
  mpc_src="$(fetch_source "$mpc_url" "$mpc_tar")"

  mkdir -p "$PKG_BUILD_WORK"
  cd "$PKG_BUILD_WORK"
  rm -rf "gcc-${PKG_VERSION}" build-gcc-final
  tar xf "$gcc_src"
  cd "gcc-${PKG_VERSION}"

  # Embed deps
  tar xf "$mpfr_src"; mv -v mpfr-* mpfr
  tar xf "$gmp_src";  mv -v gmp-*  gmp
  tar xf "$mpc_src";  mv -v mpc-*  mpc

  cd "$PKG_BUILD_WORK"
  mkdir -p build-gcc-final
  cd build-gcc-final

  local sysroot="$PKG_ROOTFS"

  # Garanta que as ferramentas do profile vêm primeiro
  export PATH="${sysroot}/usr/bin:${sysroot}/tools/bin:${PATH:-}"

  # libdir por arquitetura (conservador)
  local libdir="/usr/lib"
  case "$(uname -m)" in
    x86_64|s390x|ppc64|ppc64le|aarch64) libdir="/usr/lib64" ;;
  esac

  ../gcc-${PKG_VERSION}/configure \
    --prefix=/usr \
    --libdir="$libdir" \
    --disable-multilib \
    --disable-nls \
    --disable-werror \
    --enable-languages=c,c++ \
    --with-system-zlib \
    --with-build-sysroot="$sysroot"

  make

  make install DESTDIR="$PKG_BUILD_ROOT"

  # Ajuste comum: libgcc_s e libs críticas em /lib* às vezes são desejáveis,
  # mas para evitar decisões destrutivas, não movemos nada automaticamente aqui.
}

pre_install() {
  echo "==> [gcc-${PKG_VERSION}] Instalando GCC final em /usr no rootfs do profile via adm"
}

post_install() {
  echo "==> [gcc-${PKG_VERSION}] Sanity-check pós-instalação (gcc/g++ + link C/C++)"

  local sysroot="${PKG_ROOTFS:-$ADM_CURRENT_ROOTFS}"
  local ubin="${sysroot}/usr/bin"

  # 1) Binários no rootfs
  for b in gcc g++ cpp; do
    if [ ! -x "${ubin}/${b}" ]; then
      echo "ERRO: ausente/não executável: ${ubin}/${b}"
      exit 1
    fi
  done

  # 2) Verifica versão
  if ! "${ubin}/gcc" --version 2>/dev/null | head -n1 | grep -q "15\.2\.0"; then
    echo "ERRO: gcc --version não indica ${PKG_VERSION}."
    "${ubin}/gcc" --version 2>/dev/null | head -n2 || true
    exit 1
  fi

  # 3) Compila e linka C e C++ usando sysroot do profile (não executa)
  local tdir
  tdir="$(mktemp -d)"

  cat > "${tdir}/t.c" <<'EOF'
#include <stdio.h>
int main(void){ puts("c-ok"); return 0; }
EOF

  cat > "${tdir}/t.cpp" <<'EOF'
#include <iostream>
#include <vector>
int main(){ std::vector<int> v={1,2,3}; std::cout<<"cpp-ok\n"; return v.size()==3?0:1; }
EOF

  if ! "${ubin}/gcc" --sysroot="$sysroot" "${tdir}/t.c" -o "${tdir}/tc" >/dev/null 2>&1; then
    echo "ERRO: falha ao compilar/linkar C com sysroot=${sysroot}"
    rm -rf "$tdir"
    exit 1
  fi

  if ! "${ubin}/g++" --sysroot="$sysroot" "${tdir}/t.cpp" -o "${tdir}/tcpp" >/dev/null 2>&1; then
    echo "ERRO: falha ao compilar/linkar C++ com sysroot=${sysroot}"
    rm -rf "$tdir"
    exit 1
  fi

  # 4) Confere interpreter (evita link com host “por acidente”)
  if command -v readelf >/dev/null 2>&1; then
    local interp
    interp="$(readelf -l "${tdir}/tc" 2>/dev/null | awk '/Requesting program interpreter/ {print $NF}' | tr -d '[]')"
    if [ -z "$interp" ]; then
      echo "ERRO: não foi possível extrair interpreter do binário C (readelf)."
      rm -rf "$tdir"
      exit 1
    fi
    case "$interp" in
      /lib/*|/lib64/*) : ;;
      *)
        echo "ERRO: interpreter inesperado no binário C: $interp"
        rm -rf "$tdir"
        exit 1
        ;;
    esac
  fi

  rm -rf "$tdir"

  echo "Sanity-check GCC final ${PKG_VERSION}: OK."
}
