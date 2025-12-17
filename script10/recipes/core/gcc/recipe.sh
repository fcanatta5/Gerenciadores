# core/gcc/recipe.sh
pkgname="gcc"
pkgver="14.2.0"
srcext="tar.xz"
srcurl="https://gcc.gnu.org/pub/gcc/releases/gcc-${pkgver}/gcc-${pkgver}.tar.xz"

# O GCC upstream fornece sha512.sum no diretório de release; sha256 não é publicado ali.
# Hash oficial (sha512) para gcc-14.2.0.tar.xz (vide sha512.sum):
#   932bdef0cda94bacedf452ab17f103c0cb511ff2cec55e9112fc0328cbf1d803
#   b42595728ea7b200e0a057c03e85626f937012e49a7515bc5dd256b2bf4bc396  gcc-14.2.0.tar.xz
# Fonte: https://gcc.gnu.org/pub/gcc/releases/gcc-14.2.0/sha512.sum
# (O adm valida sha256/md5; validaremos sha512 manualmente em build().)
sha256=""
md5=""

description="GNU Compiler Collection (C/C++) para x86_64-linux-musl (com GMP/MPFR/MPC/ISL vendorizados)"
category="core"

# Dependências de sistema (assumindo que você está montando o toolchain musl):
deps=(
  "core/binutils"
  "core/linux-headers"
  "core/musl"
)

# --- versões das libs necessárias ao GCC (vendorizadas no source tree) ---
# GMP 6.3.0 sha256 (computado/publicado por terceiros confiáveis)
_GMP_VER="6.3.0"
_GMP_URL="https://gmplib.org/download/gmp/gmp-${_GMP_VER}.tar.xz"
_GMP_SHA256="a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"

# MPFR 4.2.1 sha256
_MPFR_VER="4.2.1"
_MPFR_URL="https://ftp.gnu.org/gnu/mpfr/mpfr-${_MPFR_VER}.tar.xz"
_MPFR_SHA256="277807353a6726978996945af13e52829e3abd7a9a5b7fb2793894e18f1fcbb2"

# MPC 1.3.1 sha256
_MPC_VER="1.3.1"
_MPC_URL="https://ftp.gnu.org/gnu/mpc/mpc-${_MPC_VER}.tar.gz"
_MPC_SHA256="ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8"

# ISL 0.26 sha256 (mesmo hash usado em receitas de distros/buildsystems)
_ISL_VER="0.26"
_ISL_URL="https://libisl.sourceforge.io/isl-${_ISL_VER}.tar.xz"
_ISL_SHA256="a0b5cb06d24f9fa9e77b55fabbe9a3c94a336190345c2555f9915bb38e976504"

# Helpers
_need_host_tool() {
  command -v "$1" >/dev/null 2>&1 || die "falta ferramenta para build do gcc: $1"
}

_vendor_one() {
  # $1=name (gmp/mpfr/mpc/isl) $2=url $3=sha256 $4=ext(tar.xz|tar.gz)
  local name="$1" url="$2" sha="$3" ext="$4"
  local arc="${ADM_STATE}/distfiles/${name}-${pkgver}.${ext}"
  local tmpdir=".adm-vendor-${name}"

  # Baixa (cache do adm) e valida sha256
  fetch "$url" "$arc"
  verify_hashes "$arc" "$sha" ""

  # Extrai para tmp e move para dentro do source tree do GCC como diretório "name"
  rm -rf "$tmpdir" "$name"
  mkdir -p "$tmpdir"
  extract "$arc" "$tmpdir"
  mv -f "$tmpdir" "$name"
  rmdir "$tmpdir" 2>/dev/null || true
}

build() {
  set -Eeuo pipefail

  _need_host_tool make
  _need_host_tool awk
  _need_host_tool sed
  _need_host_tool sha512sum

  # 1) Valida o tarball do GCC por SHA-512 (upstream oficial)
  # O adm baixou o tarball para: $ADM_STATE/distfiles/${id}.${srcext}
  # Aqui descobrimos o nome do arquivo pelo pkgname/pkgver.
  local gcc_arc="${ADM_STATE}/distfiles/${pkgname}-${pkgver}.${srcext}"
  if [[ -f "$gcc_arc" ]]; then
    local want_sha512="932bdef0cda94bacedf452ab17f103c0cb511ff2cec55e9112fc0328cbf1d803b42595728ea7b200e0a057c03e85626f937012e49a7515bc5dd256b2bf4bc396"
    echo "${want_sha512}  ${gcc_arc}" | sha512sum -c - >/dev/null
  fi

  # 2) Vendoriza GMP/MPFR/MPC/ISL dentro do source tree do GCC (para build “self-contained”)
  # Isso evita depender de libs já instaladas no root.
  [[ -d gmp  ]] || _vendor_one "gmp"  "${_GMP_URL}"  "${_GMP_SHA256}"  "tar.xz"
  [[ -d mpfr ]] || _vendor_one "mpfr" "${_MPFR_URL}" "${_MPFR_SHA256}" "tar.xz"
  [[ -d mpc  ]] || _vendor_one "mpc"  "${_MPC_URL}"  "${_MPC_SHA256}"  "tar.gz"
  [[ -d isl  ]] || _vendor_one "isl"  "${_ISL_URL}"  "${_ISL_SHA256}"  "tar.xz"

  # 3) Configuração do target musl
  local target="${TARGET:-x86_64-linux-musl}"
  local prefix="${PREFIX:-/usr}"

  # Se você usa wrappers do toolchain, respeite CC/CXX/AR/RANLIB do ambiente.
  : "${CC:=cc}"
  : "${CXX:=c++}"
  : "${AR:=ar}"
  : "${RANLIB:=ranlib}"
  : "${LD:=ld}"

  # 4) Out-of-tree build
  rm -rf build
  mkdir -p build
  cd build

  # Notas:
  # - --disable-multilib é desejável em x86_64 minimalista.
  # - Desabilitamos componentes que frequentemente dão atrito em musl/minimal:
  #   libsanitizer, libquadmath (opcional), nls.
  # - Ajuste --enable-languages conforme seu escopo (aqui C/C++).
  ../configure \
    --prefix="$prefix" \
    --build="$(../config.guess)" \
    --host="$target" \
    --target="$target" \
    --enable-languages=c,c++ \
    --disable-multilib \
    --disable-nls \
    --disable-libsanitizer \
    --disable-bootstrap \
    --with-system-zlib=no \
    --enable-default-pie \
    --enable-default-ssp

  make -j"${JOBS:-4}"
}

install_pkg() {
  set -Eeuo pipefail

  local dest="${DESTDIR:?DESTDIR não definido pelo adm}"
  cd build

  make DESTDIR="$dest" install

  # Opcional: removendo info/man se você quiser ultra-minimal
  # rm -rf "$dest/usr/share/info" "$dest/usr/share/man" 2>/dev/null || true
}
