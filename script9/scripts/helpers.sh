#!/bin/sh
# helpers.sh - funções utilitárias para ports do adm
# Requer: POSIX sh, coreutils, tar, gzip/xz/zstd/unzip conforme fontes.
# Colocar em /usr/share/adm/helpers.sh

set -eu

# -------- Logging / erros --------
adm_msg() { echo "port: $*" >&2; }
adm_die() { echo "port: erro: $*" >&2; exit 1; }

# -------- Defaults e ambiente --------
adm_defaults() {
  : "${JOBS:=1}"
  : "${WORKDIR:?WORKDIR não definido}"
  : "${SRCDIR:?SRCDIR não definido}"
  : "${DESTDIR:?DESTDIR não definido}"
  : "${CFLAGS:--O2 -pipe}"
  : "${CXXFLAGS:--O2 -pipe}"
  : "${LDFLAGS:-}"
  : "${PKG_CONFIG_PATH:=/usr/lib/pkgconfig:/usr/share/pkgconfig:/usr/lib64/pkgconfig}"
  export JOBS WORKDIR SRCDIR DESTDIR CFLAGS CXXFLAGS LDFLAGS PKG_CONFIG_PATH

  # Para builds mais determinísticos:
  : "${SOURCE_DATE_EPOCH:=$(date +%s)}"
  export SOURCE_DATE_EPOCH
}

# -------- Utilidades --------
nproc_fallback() { getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1; }

ensure_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || adm_die "comando ausente: $c"
  done
}

# Entra no diretório de fonte principal (com heurística segura)
enter_srcdir() {
  cd "$SRCDIR" || adm_die "SRCDIR inválido: $SRCDIR"
  # Se o port definir srcdir_name, ele deve dar cd antes de chamar.
  set -- "$SRCDIR"/*
  if [ "$#" -eq 1 ] && [ -d "$1" ]; then
    cd "$1" || adm_die "falha ao entrar no src extraído"
  fi
}

# -------- Patches --------
apply_patch() {
  p="$1"
  [ -f "$p" ] || adm_die "patch não encontrado: $p"
  ensure_cmd patch
  patch -Np1 < "$p"
}

# -------- Autotools --------
do_autoreconf() {
  ensure_cmd autoreconf
  autoreconf -fiv
}

do_configure() {
  # uso: do_configure [args...]
  ensure_cmd ./configure
  ./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    "$@"
}

do_make() {
  ensure_cmd make
  make -j"${JOBS}" "$@"
}

do_make_install() {
  ensure_cmd make
  make DESTDIR="${DESTDIR}" "$@" install
}

# -------- CMake --------
do_cmake_configure() {
  # uso: do_cmake_configure <srcdir> [args...]
  ensure_cmd cmake
  src="${1:?srcdir}"
  shift
  cmake -S "$src" -B build \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_SYSCONFDIR=/etc \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$CFLAGS" \
    -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
    "$@"
}

do_cmake_build() {
  ensure_cmd cmake
  cmake --build build -j "${JOBS}"
}

do_cmake_install() {
  ensure_cmd cmake
  cmake --install build --prefix /usr --destdir "${DESTDIR}"
}

# -------- Meson / Ninja --------
do_meson_setup() {
  # uso: do_meson_setup <srcdir> [args...]
  ensure_cmd meson ninja
  src="${1:?srcdir}"
  shift
  meson setup build "$src" \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --buildtype=release \
    -Dc_args="$CFLAGS" \
    -Dcpp_args="$CXXFLAGS" \
    -Dc_link_args="$LDFLAGS" \
    -Dcpp_link_args="$LDFLAGS" \
    "$@"
}

do_ninja_build() {
  ensure_cmd ninja
  ninja -C build -j "${JOBS}"
}

do_ninja_install() {
  ensure_cmd ninja
  DESTDIR="${DESTDIR}" ninja -C build install
}

# -------- Python (PEP517 / setup.py) --------
do_python_build_install() {
  # Preferência: PEP517 (python -m build). Fallback: setup.py.
  ensure_cmd python3
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import build' >/dev/null 2>&1; then
    ensure_cmd python3
    python3 -m build --wheel --no-isolation
    # instala wheel no DESTDIR via pip (sem tocar no sistema)
    ensure_cmd python3
    python3 -m pip install --no-deps --no-index --find-links dist \
      --root "${DESTDIR}" --prefix /usr "$(ls -1 dist/*.whl | head -n1)"
  elif [ -f setup.py ]; then
    python3 setup.py build
    python3 setup.py install --root="${DESTDIR}" --prefix=/usr --optimize=1
  else
    adm_die "sem método python detectado (PEP517 ou setup.py)"
  fi
}

# -------- Pós-instalação desktop comum --------
postinstall_desktop_common() {
  # Use em ports de desktop (gtk, icons, mime, fonts)
  command -v glib-compile-schemas >/dev/null 2>&1 && glib-compile-schemas /usr/share/glib-2.0/schemas || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q || true
  command -v update-mime-database >/dev/null 2>&1 && update-mime-database /usr/share/mime || true
  command -v fc-cache >/dev/null 2>&1 && fc-cache -r || true
}

# -------- Strip opcional (cuidado em debug) --------
strip_binaries_in_destdir() {
  # use apenas se você souber que quer strip no pacote
  command -v strip >/dev/null 2>&1 || return 0
  find "${DESTDIR}" -type f -perm -111 2>/dev/null | while IFS= read -r f; do
    strip --strip-unneeded "$f" 2>/dev/null || true
  done
}
