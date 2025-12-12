# /opt/adm/packages/toolchain/libstdcxx-15.2.0.sh
#
# libstdc++ (libstdc++-v3) a partir do GCC 15.2.0
# - Empacota via DESTDIR=$PKG_BUILD_ROOT (adm.sh extrai no rootfs do profile)
# - Alinhado a profiles: usa $PKG_ROOTFS como sysroot quando cross
# - Sanity-check: verifica headers + libstdc++.so.* e linkedição de teste C++ (sem executar)
#
# Observação importante:
# - Para build "cross" (bootstrap/LFS style), precisa existir $LFS_TGT-g++ no PATH do profile.
# - Para build "nativo" (profile glibc já com g++), usa g++ do host/profile.
#
# Dependências:
# - glibc (para headers/libc do sysroot)
# - gcc-bootstrap/binutils-bootstrap/linux-headers (para toolchain inicial; ou um gcc/g++ completo no profile)
#
# Se você ainda não tem um GCC com C++ no profile, instale/forneça um g++ (cross ou nativo).

PKG_NAME="libstdcxx"
PKG_VERSION="15.2.0"
PKG_DESC="libstdc++ from GCC (libstdc++-v3) 15.2.0"
PKG_DEPENDS="glibc linux-headers binutils-bootstrap gcc-bootstrap"
PKG_CATEGORY="toolchain"
PKG_LIBC="glibc"

build() {
  local url="https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  local tar="gcc-${PKG_VERSION}.tar.xz"
  local src

  src="$(fetch_source "$url" "$tar")"

  mkdir -p "$PKG_BUILD_WORK"
  cd "$PKG_BUILD_WORK"
  rm -rf "gcc-${PKG_VERSION}" build-libstdcxx
  tar xf "$src"

  mkdir -p build-libstdcxx
  cd build-libstdcxx

  local sysroot="$PKG_ROOTFS"

  # Decide modo:
  # - Cross preferido se existir LFS_TGT-g++
  # - Caso contrário, tenta modo nativo com g++
  local target="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"
  local build_triplet
  build_triplet="$("$PKG_BUILD_WORK/gcc-${PKG_VERSION}/config.guess")"

  # Garanta /tools/bin no PATH para pegar toolchain do profile (se existir)
  export PATH="${sysroot}/tools/bin:${PATH:-}"

  local cxx=""
  local cc=""

  if command -v "${target}-g++" >/dev/null 2>&1; then
    # Cross
    cc="${target}-gcc"
    cxx="${target}-g++"
  elif command -v g++ >/dev/null 2>&1; then
    # Nativo
    cc="gcc"
    cxx="g++"
  else
    echo "ERRO: Não encontrei ${target}-g++ nem g++ no PATH. libstdc++ requer um compilador C++."
    exit 1
  fi

  export CC="$cc"
  export CXX="$cxx"

  # Determina libdir por arquitetura (conservador)
  local libdir="/usr/lib"
  case "$(uname -m)" in
    x86_64|s390x|ppc64|ppc64le|aarch64) libdir="/usr/lib64" ;;
  esac

  # Caminho padrão dos headers do libstdc++
  # (GCC instala em /usr/include/c++/<ver> por default)
  local gxx_incdir="/usr/include/c++/${PKG_VERSION}"

  # Configure apenas o libstdc++-v3
  # Se estiver em modo cross, passamos --host/--build e usamos --with-sysroot para pegar glibc/headers no rootfs.
  if [ "$CXX" = "${target}-g++" ]; then
    "../gcc-${PKG_VERSION}/libstdc++-v3/configure" \
      --host="$target" \
      --build="$build_triplet" \
      --prefix=/usr \
      --disable-multilib \
      --disable-nls \
      --disable-libstdcxx-pch \
      --with-sysroot="$sysroot" \
      --with-gxx-include-dir="$gxx_incdir" \
      --libdir="$libdir"
  else
    # Nativo: sem --host/--build, mas ainda instalamos para o rootfs via DESTDIR
    "../gcc-${PKG_VERSION}/libstdc++-v3/configure" \
      --prefix=/usr \
      --disable-multilib \
      --disable-nls \
      --disable-libstdcxx-pch \
      --with-gxx-include-dir="$gxx_incdir" \
      --libdir="$libdir"
  fi

  make

  make install DESTDIR="$PKG_BUILD_ROOT"
}

pre_install() {
  echo "==> [libstdcxx-${PKG_VERSION}] Instalando libstdc++ no rootfs do profile via adm"
}

post_install() {
  echo "==> [libstdcxx-${PKG_VERSION}] Sanity-check pós-instalação (headers + libs + link C++)"

  local sysroot="${PKG_ROOTFS:-$ADM_CURRENT_ROOTFS}"
  local target="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"

  # 1) Headers do C++
  local hdr_dir="${sysroot}/usr/include/c++/${PKG_VERSION}"
  if [ ! -d "$hdr_dir" ]; then
    echo "ERRO: headers do libstdc++ não encontrados em: $hdr_dir"
    exit 1
  fi

  # 2) Biblioteca compartilhada
  local lib_found=""
  if [ -f "${sysroot}/usr/lib/libstdc++.so.6" ]; then
    lib_found="${sysroot}/usr/lib/libstdc++.so.6"
  elif [ -f "${sysroot}/usr/lib64/libstdc++.so.6" ]; then
    lib_found="${sysroot}/usr/lib64/libstdc++.so.6"
  else
    # fallback: busca tolerante
    lib_found="$(find "${sysroot}/usr/lib" "${sysroot}/usr/lib64" -maxdepth 2 -type f -name 'libstdc++.so.6' 2>/dev/null | head -n1 || true)"
  fi

  if [ -z "$lib_found" ]; then
    echo "ERRO: libstdc++.so.6 não encontrada em ${sysroot}/usr/lib*"
    exit 1
  fi

  # 3) Teste de linkedição (não executa)
  # Preferimos cross g++ se existir; senão g++.
  local cxx=""
  if command -v "${target}-g++" >/dev/null 2>&1; then
    cxx="${target}-g++"
  elif command -v g++ >/dev/null 2>&1; then
    cxx="g++"
  else
    echo "ERRO: Não encontrei ${target}-g++ nem g++ para sanity-check."
    exit 1
  fi

  local tdir
  tdir="$(mktemp -d)"
  local test_cpp="${tdir}/t.cpp"
  local test_bin="${tdir}/t"

  cat > "$test_cpp" <<'EOF'
#include <iostream>
#include <vector>
#include <string>
int main() {
  std::vector<std::string> v = {"libstdc++", "ok"};
  std::cout << v[0] << " " << v[1] << "\n";
  return 0;
}
EOF

  # Se for cross, força sysroot na linkedição.
  if [[ "$cxx" == *"${target}-g++" ]]; then
    if ! "$cxx" --sysroot="$sysroot" "$test_cpp" -o "$test_bin" >/dev/null 2>&1; then
      echo "ERRO: falha ao compilar/linkar teste C++ com sysroot=${sysroot}"
      rm -rf "$tdir"
      exit 1
    fi
  else
    # Nativo: ainda tentamos apontar sysroot para evitar linkar contra host por acidente
    if ! "$cxx" --sysroot="$sysroot" "$test_cpp" -o "$test_bin" >/dev/null 2>&1; then
      echo "ERRO: falha ao compilar/linkar teste C++ (nativo) com sysroot=${sysroot}"
      rm -rf "$tdir"
      exit 1
    fi
  fi

  # 4) Verifica interpreter (se readelf disponível) — não deve apontar para algo estranho fora de /lib*
  if command -v readelf >/dev/null 2>&1; then
    local interp
    interp="$(readelf -l "$test_bin" 2>/dev/null | awk '/Requesting program interpreter/ {print $NF}' | tr -d '[]')"
    if [ -z "$interp" ]; then
      echo "ERRO: não foi possível extrair interpreter do binário de teste (readelf)."
      rm -rf "$tdir"
      exit 1
    fi
    case "$interp" in
      /lib/*|/lib64/*) : ;;
      *)
        echo "ERRO: interpreter inesperado no binário de teste: $interp"
        rm -rf "$tdir"
        exit 1
        ;;
    esac
  fi

  rm -rf "$tdir"

  echo "Sanity-check libstdc++ ${PKG_VERSION}: OK (headers + lib + linkedição C++)."
}
