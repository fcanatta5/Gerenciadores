#!/usr/bin/env bash
# adm-build-helpers.sh
# Biblioteca de helpers para builds (autotools, cmake, meson/ninja, cargo/rust, python/pep517, go, node, llvm)
# Objetivo: reduzir “dor” para Wayland/Mesa/GTK/Firefox e pacotes modernos em sistemas musl/busybox.
#
# Como usar (dentro do build script do seu pacote):
#   source /var/lib/adm/lib/adm-build-helpers.sh
#   adm_env_init
#   adm_src_enter   # entra no SRCTOP e prepara BUILD_DIR
#   adm_meson_configure -Dfoo=enabled
#   adm_meson_build
#   adm_meson_install
#
# Pré-requisitos recomendados no host/build-env:
#   bash, coreutils, findutils, tar, xz, zstd, gzip, bzip2, patch, sed, awk, grep, file
#   make, pkg-config, python3, pip (ou pipx), git, curl
#   meson, ninja, cmake, autoconf/automake/libtool, rust/cargo, go, node/npm (se necessário)
#
# Variáveis esperadas (defina no seu gerenciador ou no build script):
#   SRCTOP   : diretório topo do source já extraído (obrigatório)
#   WORKDIR  : diretório de trabalho do pacote (obrigatório)
#   DESTDIR  : staging root para instalação (obrigatório)
#   ROOT     : root final para instalação (opcional; normalmente /)
#   JOBS     : paralelismo (opcional)
#   CC/CXX/AR/RANLIB/LD/STRIP (opcionais, mas recomendados)
#
# Cross/sysroot (opcional):
#   TARGET               : triplet (ex.: x86_64-linux-musl)
#   SYSROOT              : sysroot (ex.: /mnt/adm/tools/x86_64-linux-musl)
#   PKG_CONFIG_SYSROOT_DIR
#   PKG_CONFIG_LIBDIR
#
# Observação: este arquivo é “helper library” (não executa sozinho).

set -Eeuo pipefail

########################################
# UI / Logging
########################################
: "${ADM_COLOR:=1}"
: "${ADM_LOG_PREFIX:=[adm]}"
: "${JOBS:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

adm_ts(){ date +"%Y-%m-%d %H:%M:%S"; }

adm__c_reset="" adm__c_dim="" adm__c_red="" adm__c_grn="" adm__c_yel="" adm__c_blu=""
if [[ "${ADM_COLOR}" == "1" ]] && [[ -t 1 ]]; then
  adm__c_reset=$'\033[0m'
  adm__c_dim=$'\033[2m'
  adm__c_red=$'\033[31m'
  adm__c_grn=$'\033[32m'
  adm__c_yel=$'\033[33m'
  adm__c_blu=$'\033[34m'
fi

adm_log(){  echo "${adm__c_dim}[$(adm_ts)]${adm__c_reset} ${ADM_LOG_PREFIX} $*"; }
adm_ok(){   echo "${adm__c_grn}[$(adm_ts)] OK${adm__c_reset}  ${ADM_LOG_PREFIX} $*"; }
adm_warn(){ echo "${adm__c_yel}[$(adm_ts)] WARN${adm__c_reset} ${ADM_LOG_PREFIX} $*" >&2; }
adm_die(){  echo "${adm__c_red}[$(adm_ts)] ERRO${adm__c_reset} ${ADM_LOG_PREFIX} $*" >&2; exit 1; }

adm_need(){ command -v "$1" >/dev/null 2>&1 || adm_die "Comando ausente: $1"; }

adm_run(){
  # Uso: adm_run <cmd...>
  adm_log "+ $*"
  "$@"
}

########################################
# Paths / Environment normalization
########################################
adm_env_init(){
  # valida variáveis mínimas
  [[ -n "${SRCTOP:-}" ]]  || adm_die "SRCTOP não definido"
  [[ -n "${WORKDIR:-}" ]] || adm_die "WORKDIR não definido"
  [[ -n "${DESTDIR:-}" ]] || adm_die "DESTDIR não definido"
  mkdir -p "${WORKDIR}" "${DESTDIR}"

  export LC_ALL="${LC_ALL:-C}"
  export MAKEFLAGS="${MAKEFLAGS:--j${JOBS}}"
  export NINJAFLAGS="${NINJAFLAGS:--j ${JOBS}}"

  # Flags base (ajuste por pacote conforme necessário)
  export CFLAGS="${CFLAGS:--O2 -pipe}"
  export CXXFLAGS="${CXXFLAGS:--O2 -pipe}"
  export LDFLAGS="${LDFLAGS:-}"
  export CPPFLAGS="${CPPFLAGS:-}"

  # toolchain defaults (se não setado, tenta gcc/clang do PATH)
  export CC="${CC:-gcc}"
  export CXX="${CXX:-g++}"
  export AR="${AR:-ar}"
  export RANLIB="${RANLIB:-ranlib}"
  export LD="${LD:-ld}"
  export STRIP="${STRIP:-strip}"

  # sane PATH: permite overlay de toolchain (ex.: /mnt/adm/tools/bin) antes se usuário exportou
  export PATH="${PATH}"

  # pkg-config (muito importante em sysroot/cross)
  if [[ -n "${SYSROOT:-}" ]]; then
    export PKG_CONFIG_SYSROOT_DIR="${PKG_CONFIG_SYSROOT_DIR:-${SYSROOT}}"
    # Para musl/sysroot: preferir sysroot usr/lib/pkgconfig e usr/share/pkgconfig
    export PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR:-${SYSROOT}/usr/lib/pkgconfig:${SYSROOT}/usr/share/pkgconfig:${SYSROOT}/usr/lib64/pkgconfig}"
    export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
  fi

  # compilações determinísticas (quando suportado)
  export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1}"
}

adm_build_dir(){
  # Diretório padrão out-of-tree por pacote
  echo "${WORKDIR}/build"
}

adm_src_enter(){
  adm_env_init
  export BUILD_DIR="${BUILD_DIR:-$(adm_build_dir)}"
  mkdir -p "${BUILD_DIR}"
  cd "${SRCTOP}"
  adm_ok "SRCTOP=${SRCTOP}"
  adm_ok "BUILD_DIR=${BUILD_DIR}"
  adm_ok "DESTDIR=${DESTDIR}"
}

########################################
# Helpers gerais
########################################
adm_clean_builddir(){
  [[ -n "${BUILD_DIR:-}" ]] || export BUILD_DIR="$(adm_build_dir)"
  rm -rf "${BUILD_DIR}"
  mkdir -p "${BUILD_DIR}"
}

adm_apply_patches_dir(){
  # aplica patches em ordem lexical (use no seu build script se quiser além do manager)
  local pdir="$1"
  [[ -d "$pdir" ]] || return 0
  adm_need patch
  local p
  while IFS= read -r p; do
    adm_log "Patch: $(basename "$p")"
    adm_run patch -p1 < "$p"
  done < <(find "$pdir" -maxdepth 1 -type f \( -name "*.patch" -o -name "*.diff" \) | sort)
}

adm_install_overlay_files(){
  # copia árvore "files/" para DESTDIR preservando perms/links
  local filesdir="$1"
  [[ -d "$filesdir" ]] || return 0
  adm_need tar
  adm_log "Overlay files/: $filesdir -> $DESTDIR"
  ( cd "$filesdir" && tar -cpf - . ) | ( cd "$DESTDIR" && tar -xpf - )
}

adm_strip_binaries(){
  # strip best-effort; útil para binpkgs menores (cuidado com debug packages)
  local root="${1:-$DESTDIR}"
  command -v file >/dev/null 2>&1 || return 0
  command -v "${STRIP}" >/dev/null 2>&1 || return 0
  adm_log "Stripping (best-effort) em: $root"
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if file -b "$f" | grep -qE 'ELF (64|32)-bit'; then
      "${STRIP}" --strip-unneeded "$f" 2>/dev/null || true
    fi
  done < <(find "$root" -type f)
}

########################################
# Autotools (configure/make)
########################################
adm_autotools_bootstrap(){
  # Para projetos que exigem autoreconf (git checkout)
  adm_need autoreconf
  adm_src_enter
  adm_run autoreconf -vfi
}

adm_autotools_configure(){
  adm_src_enter
  local prefix="${1:-/usr}"
  shift || true
  # out-of-tree possível: configure no BUILD_DIR
  if [[ -x "${SRCTOP}/configure" ]]; then
    :
  else
    adm_die "configure não encontrado em ${SRCTOP}. Use adm_autotools_bootstrap ou ajuste."
  fi
  ( cd "${BUILD_DIR}" && adm_run "${SRCTOP}/configure" \
      --prefix="${prefix}" \
      ${SYSROOT:+--host="${TARGET:-}"} \
      "$@" )
}

adm_make_build(){
  adm_need make
  ( cd "${BUILD_DIR}" && adm_run make ${MAKEFLAGS} )
}

adm_make_install(){
  adm_need make
  ( cd "${BUILD_DIR}" && adm_run make DESTDIR="${DESTDIR}" install )
}

########################################
# CMake
########################################
adm_cmake_configure(){
  adm_need cmake
  adm_src_enter
  local prefix="${1:-/usr}"
  shift || true

  local toolchain_args=()
  if [[ -n "${SYSROOT:-}" ]]; then
    toolchain_args+=(
      "-DCMAKE_SYSROOT=${SYSROOT}"
      "-DCMAKE_FIND_ROOT_PATH=${SYSROOT}"
      "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER"
      "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY"
      "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY"
      "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY"
    )
  fi
  toolchain_args+=(
    "-DCMAKE_INSTALL_PREFIX=${prefix}"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_C_COMPILER=${CC}"
    "-DCMAKE_CXX_COMPILER=${CXX}"
    "-DCMAKE_AR=${AR}"
    "-DCMAKE_RANLIB=${RANLIB}"
    "-DCMAKE_STRIP=${STRIP}"
  )

  adm_run cmake -S "${SRCTOP}" -B "${BUILD_DIR}" \
    -G Ninja \
    "${toolchain_args[@]}" \
    "$@"
}

adm_cmake_build(){
  adm_need cmake
  adm_run cmake --build "${BUILD_DIR}" -- -j "${JOBS}"
}

adm_cmake_install(){
  adm_need cmake
  adm_run cmake --install "${BUILD_DIR}" --prefix "/usr" --component "" --strip 2>/dev/null || true
  # cmake --install não aceita DESTDIR em todas versões; preferimos env DESTDIR
  DESTDIR="${DESTDIR}" adm_run cmake --install "${BUILD_DIR}"
}

########################################
# Meson/Ninja (Wayland stack)
########################################
adm_meson_configure(){
  adm_need meson
  adm_need ninja
  adm_src_enter
  local prefix="${1:-/usr}"
  shift || true

  local cross_file=""
  # Se for cross/sysroot, Meson funciona melhor com cross-file.
  if [[ -n "${TARGET:-}" && -n "${SYSROOT:-}" ]]; then
    cross_file="${WORKDIR}/meson.cross"
    cat > "${cross_file}" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
pkgconfig = 'pkg-config'

[properties]
sys_root = '${SYSROOT}'
needs_exe_wrapper = true

[built-in options]
c_args = ${CFLAGS@Q}
cpp_args = ${CXXFLAGS@Q}
c_link_args = ${LDFLAGS@Q}
cpp_link_args = ${LDFLAGS@Q}

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
  fi

  local args=(
    "setup" "${BUILD_DIR}" "${SRCTOP}"
    "--prefix=${prefix}"
    "--libdir=lib"
    "--buildtype=release"
    "--wrap-mode=nodownload"
    "--unity=off"
  )

  if [[ -n "${cross_file}" ]]; then
    args+=("--cross-file=${cross_file}")
  fi

  adm_run meson "${args[@]}" "$@"
}

adm_meson_build(){
  adm_need ninja
  adm_run ninja -C "${BUILD_DIR}" -j "${JOBS}"
}

adm_meson_test(){
  adm_need meson
  adm_run meson test -C "${BUILD_DIR}" --print-errorlogs || true
}

adm_meson_install(){
  adm_need meson
  DESTDIR="${DESTDIR}" adm_run meson install -C "${BUILD_DIR}"
}

########################################
# Rust / Cargo (Firefox e deps)
########################################
adm_rust_env(){
  adm_need cargo
  adm_need rustc
  # Evita downloads aleatórios se você controla vendor
  export CARGO_HOME="${CARGO_HOME:-${WORKDIR}/.cargo-home}"
  export RUSTUP_HOME="${RUSTUP_HOME:-${WORKDIR}/.rustup-home}"
  mkdir -p "${CARGO_HOME}" "${RUSTUP_HOME}"

  # Para builds em musl: normalmente TARGET é necessário
  if [[ -n "${TARGET:-}" ]]; then
    export CARGO_BUILD_TARGET="${CARGO_BUILD_TARGET:-${TARGET}}"
  fi

  # Reprodutibilidade
  export CARGO_TERM_COLOR=never
  export RUSTFLAGS="${RUSTFLAGS:-} ${SYSROOT:+--sysroot=${SYSROOT}}"
}

adm_cargo_fetch(){
  adm_rust_env
  adm_src_enter
  adm_run cargo fetch --locked
}

adm_cargo_build(){
  adm_rust_env
  adm_src_enter
  local mode="${1:-release}" ; shift || true
  local args=()
  [[ "$mode" == "release" ]] && args+=(--release)
  adm_run cargo build "${args[@]}" --locked "$@"
}

adm_cargo_install_bins(){
  # instala binários/artefatos de crates simples (não para Firefox direto)
  adm_rust_env
  adm_src_enter
  local bindir="${1:-/usr/bin}"
  mkdir -p "${DESTDIR}${bindir}"
  # tenta localizar binários gerados
  local tgt="${CARGO_BUILD_TARGET:-}"
  local outdir="${SRCTOP}/target"
  [[ -n "$tgt" ]] && outdir="${outdir}/${tgt}"
  outdir="${outdir}/release"
  if [[ -d "$outdir" ]]; then
    find "$outdir" -maxdepth 1 -type f -executable -print0 | while IFS= read -r -d '' f; do
      # filtra binários reais (evita .d, .rlib)
      case "$(basename "$f")" in
        *.d|*.rlib|*.a|*.so|*.so.*) continue ;;
      esac
      adm_run install -m 0755 "$f" "${DESTDIR}${bindir}/"
    done
  else
    adm_die "Diretório de saída cargo não encontrado: $outdir"
  fi
}

########################################
# Python (setuptools/pep517)
########################################
adm_python_env(){
  adm_need python3
  export PYTHON="${PYTHON:-python3}"
  export PYTHONNOUSERSITE=1
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_CACHE_DIR=0
  export PIP_CACHE_DIR="${PIP_CACHE_DIR:-${CACHEDIR:-/var/lib/adm/cache}/pip}"
  mkdir -p "${PIP_CACHE_DIR}"
}

adm_pyproject_build_wheel(){
  # constrói wheel via PEP517 (build)
  adm_python_env
  adm_need python3
  adm_src_enter
  "${PYTHON}" -m build --wheel --no-isolation
}

adm_python_install_pep517(){
  # instala wheel em DESTDIR usando pip --root (sem venv)
  adm_python_env
  adm_need pip
  adm_src_enter
  local wheel
  wheel="$(ls -1 dist/*.whl 2>/dev/null | head -n1 || true)"
  [[ -n "$wheel" ]] || adm_die "Wheel não encontrado em dist/. Rode adm_pyproject_build_wheel antes."
  adm_run pip install --no-deps --no-index --root "${DESTDIR}" "$wheel"
}

adm_python_setup_install(){
  # legacy setuptools
  adm_python_env
  adm_src_enter
  adm_run "${PYTHON}" setup.py install --root="${DESTDIR}" --prefix="/usr"
}

########################################
# Go
########################################
adm_go_env(){
  adm_need go
  export GOPATH="${GOPATH:-${WORKDIR}/.gopath}"
  export GOMODCACHE="${GOMODCACHE:-${WORKDIR}/.gomodcache}"
  mkdir -p "${GOPATH}" "${GOMODCACHE}"
  export CGO_ENABLED="${CGO_ENABLED:-1}"
  # musl: muitas vezes CGO exige toolchain correta
}

adm_go_build(){
  adm_go_env
  adm_src_enter
  local out="${1:-${PKG_NAME:-app}}"
  shift || true
  adm_run go build -trimpath -ldflags="-s -w" -o "${BUILD_DIR}/${out}" "$@"
}

adm_go_install_bin(){
  local out="${1:-${PKG_NAME:-app}}"
  local bindir="${2:-/usr/bin}"
  mkdir -p "${DESTDIR}${bindir}"
  adm_run install -m 0755 "${BUILD_DIR}/${out}" "${DESTDIR}${bindir}/${out}"
}

########################################
# Node (npm) - use com cautela (reprodutibilidade)
########################################
adm_node_env(){
  adm_need node
  adm_need npm
  export npm_config_cache="${npm_config_cache:-${WORKDIR}/.npm-cache}"
  mkdir -p "${npm_config_cache}"
  export npm_config_fund=false
  export npm_config_audit=false
  export npm_config_update_notifier=false
}

adm_npm_ci(){
  adm_node_env
  adm_src_enter
  adm_run npm ci --ignore-scripts
}

adm_npm_build(){
  adm_node_env
  adm_src_enter
  adm_run npm run build
}

########################################
# Linker / toolchain sanity + hardening
########################################
adm_toolchain_report(){
  adm_log "Toolchain:"
  adm_log "  CC=${CC}"
  adm_log "  CXX=${CXX}"
  adm_log "  AR=${AR}"
  adm_log "  RANLIB=${RANLIB}"
  adm_log "  LD=${LD}"
  adm_log "  STRIP=${STRIP}"
  adm_log "  CFLAGS=${CFLAGS}"
  adm_log "  LDFLAGS=${LDFLAGS}"
  adm_log "  SYSROOT=${SYSROOT:-<none>}"
  adm_log "  TARGET=${TARGET:-<none>}"
  adm_log "  PKG_CONFIG_SYSROOT_DIR=${PKG_CONFIG_SYSROOT_DIR:-<none>}"
  adm_log "  PKG_CONFIG_LIBDIR=${PKG_CONFIG_LIBDIR:-<none>}"
}

adm_smoketest_cc(){
  adm_env_init
  local t="${WORKDIR}/.adm-smoke"
  mkdir -p "$t"
  cat > "$t/hello.c" <<'EOF'
#include <stdio.h>
int main(){ puts("adm-smoketest"); return 0; }
EOF
  adm_run "${CC}" ${SYSROOT:+--sysroot="${SYSROOT}"} ${CFLAGS} ${LDFLAGS} -o "$t/hello" "$t/hello.c"
  command -v file >/dev/null 2>&1 && file "$t/hello" || true
}

########################################
# Conveniências para projetos “comuns”
########################################
adm_standard_prefix(){
  # use /usr como padrão
  echo "${1:-/usr}"
}

adm_pkgconfig_sanity(){
  command -v pkg-config >/dev/null 2>&1 || adm_die "pkg-config ausente (necessário para Wayland/GTK/Firefox deps)"
  adm_log "pkg-config version: $(pkg-config --version 2>/dev/null || echo '?')"
}

adm_maybe_disable_tests(){
  # Wayland/Mesa/Firefox deps: testes às vezes quebram em cross/sysroot.
  export ADMDB_DISABLE_TESTS="${ADMDB_DISABLE_TESTS:-1}"
}

adm_jobs(){
  echo "${JOBS}"
}

########################################
# “Recipes” rápidos (templates)
########################################
adm_recipe_meson(){
  # meson+ninja comum
  adm_meson_configure "/usr" "$@"
  adm_meson_build
  adm_meson_install
}

adm_recipe_cmake(){
  adm_cmake_configure "/usr" "$@"
  adm_cmake_build
  adm_cmake_install
}

adm_recipe_autotools(){
  adm_autotools_configure "/usr" "$@"
  adm_make_build
  adm_make_install
}

# Fim da biblioteca
