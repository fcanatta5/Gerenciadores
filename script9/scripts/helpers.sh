#!/bin/sh
# /usr/share/adm/helpers.sh
# Helpers POSIX sh para ports do adm.
# Variáveis fornecidas pelo adm:
#   PORTDIR, PATCHDIR, FILESDIR, WORKDIR, SRCDIR, DESTDIR, JOBS, SRCDIR_NAME

set -eu

adm_msg()  { printf '%s\n' "port: $*" >&2; }
adm_warn() { printf '%s\n' "port: aviso: $*" >&2; }
adm_die()  { printf '%s\n' "port: erro: $*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
ensure_cmd() { for c in "$@"; do have_cmd "$c" || adm_die "comando ausente: $c"; done; }

adm_defaults() {
  : "${JOBS:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
  : "${WORKDIR:?WORKDIR não definido}"
  : "${SRCDIR:?SRCDIR não definido}"
  : "${DESTDIR:?DESTDIR não definido}"
  : "${PORTDIR:?PORTDIR não definido}"

  : "${PATCHDIR:=${PORTDIR}/patches}"
  : "${FILESDIR:=${PORTDIR}/files}"
  : "${SRCDIR_NAME:=${SRCDIR_NAME:-}}"

  : "${CFLAGS:--O2 -pipe}"
  : "${CXXFLAGS:--O2 -pipe}"
  : "${LDFLAGS:-}"
  : "${CPPFLAGS:-}"

  : "${PKG_CONFIG_PATH:=/usr/lib/pkgconfig:/usr/share/pkgconfig:/usr/lib64/pkgconfig}"
  export JOBS WORKDIR SRCDIR DESTDIR PORTDIR PATCHDIR FILESDIR SRCDIR_NAME \
         CFLAGS CXXFLAGS LDFLAGS CPPFLAGS PKG_CONFIG_PATH

  # Não seta SOURCE_DATE_EPOCH automaticamente (evita não-reprodutibilidade por padrão)
  export LC_ALL="${LC_ALL:-C}"
  export MAKEFLAGS="${MAKEFLAGS:--j${JOBS}}"
}

# -------------------- Source dir --------------------

enter_srcdir_auto() {
  cd "$SRCDIR" || adm_die "SRCDIR inválido: $SRCDIR"

  if [ -n "${SRCDIR_NAME:-}" ]; then
    [ -d "$SRCDIR/$SRCDIR_NAME" ] || adm_die "SRCDIR_NAME inválido: $SRCDIR/$SRCDIR_NAME"
    cd "$SRCDIR/$SRCDIR_NAME" || adm_die "falha ao entrar em $SRCDIR/$SRCDIR_NAME"
    return 0
  fi

  set -- "$SRCDIR"/*
  if [ "$#" -eq 1 ] && [ -d "$1" ]; then
    cd "$1" || adm_die "falha ao entrar no diretório extraído"
  else
    cd "$SRCDIR" || adm_die "falha ao entrar em SRCDIR"
  fi
}

enter_srcdir() {
  sub="${1:?subdir obrigatório}"
  cd "$SRCDIR" || adm_die "SRCDIR inválido: $SRCDIR"
  [ -d "$SRCDIR/$sub" ] || adm_die "subdir inválido: $SRCDIR/$sub"
  cd "$SRCDIR/$sub" || adm_die "falha ao entrar em $SRCDIR/$sub"
}

# -------------------- Patches / files --------------------

apply_default_patches() {
  [ -d "$PATCHDIR" ] || return 0
  ensure_cmd patch
  patches="$(find "$PATCHDIR" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) 2>/dev/null | sort || true)"
  [ -n "$patches" ] || return 0
  for p in $patches; do
    adm_msg "aplicando patch: $(basename "$p")"
    patch -Np1 < "$p" || adm_die "falha ao aplicar patch: $p"
  done
}

apply_patch() {
  p="$1"
  [ -f "$p" ] || adm_die "patch não encontrado: $p"
  ensure_cmd patch
  patch -Np1 < "$p" || adm_die "falha ao aplicar patch: $p"
}

install_files_into_destdir() {
  rel="${1:?caminho relativo obrigatório}"
  src="${FILESDIR}/${rel}"
  dst="${DESTDIR}/${rel}"
  [ -e "$src" ] || adm_die "arquivo não encontrado em files/: $rel"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
}

install_file() {
  src_rel="${1:?arquivo em files/ obrigatório}"
  dst_abs="${2:?destino absoluto obrigatório}"
  case "$dst_abs" in /*) : ;; *) adm_die "destino deve ser absoluto: $dst_abs" ;; esac
  src="${FILESDIR}/${src_rel}"
  dst="${DESTDIR}${dst_abs}"
  [ -e "$src" ] || adm_die "arquivo não encontrado em files/: $src_rel"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
}

# simples “sed in-place” POSIX
sed_inplace() {
  expr="${1:?expressão sed obrigatória}"
  file="${2:?arquivo obrigatório}"
  [ -f "$file" ] || adm_die "arquivo não encontrado: $file"
  tmp="$(mktemp)"
  sed "$expr" "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# -------------------- Autotools / bootstrap --------------------

do_autogen() {
  if [ -x ./autogen.sh ]; then
    adm_msg "rodando autogen.sh"
    sh ./autogen.sh "$@"
    return 0
  fi
  adm_warn "autogen.sh não encontrado/executável"
}

do_bootstrap() {
  if [ -x ./bootstrap ]; then
    adm_msg "rodando bootstrap"
    ./bootstrap "$@"
    return 0
  fi
  adm_warn "bootstrap não encontrado/executável"
}

do_autoreconf() {
  ensure_cmd autoreconf
  adm_msg "rodando autoreconf -fiv"
  autoreconf -fiv
}

do_bootstrap_auto() {
  if [ -x ./bootstrap ]; then
    do_bootstrap "$@"
  elif [ -x ./autogen.sh ]; then
    do_autogen "$@"
  else
    do_autoreconf
  fi
}

do_configure() {
  # tolera configure sem +x
  export CFLAGS CXXFLAGS LDFLAGS CPPFLAGS PKG_CONFIG_PATH
  if [ -f ./configure ]; then
    if [ -x ./configure ]; then
      ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var "$@"
    else
      sh ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var "$@"
    fi
  else
    adm_die "configure não encontrado"
  fi
}

do_make() { ensure_cmd make; make -j"$JOBS" "$@"; }
do_make_install() { ensure_cmd make; make DESTDIR="$DESTDIR" "$@" install; }

do_autotools_build() {
  do_bootstrap_auto
  do_configure "$@"
  do_make
}

# -------------------- CMake --------------------

do_cmake_configure() {
  ensure_cmd cmake
  src="${1:?srcdir}"
  shift
  export CFLAGS CXXFLAGS LDFLAGS CPPFLAGS PKG_CONFIG_PATH
  cmake -S "$src" -B build \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_SYSCONFDIR=/etc \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$CFLAGS" \
    -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
    "$@"
}

do_cmake_build() { ensure_cmd cmake; cmake --build build -j "$JOBS"; }
do_cmake_install() { ensure_cmd cmake; cmake --install build --prefix /usr --destdir "$DESTDIR"; }

# -------------------- Meson / Ninja --------------------

do_meson_setup() {
  ensure_cmd meson ninja
  src="${1:?srcdir}"
  shift
  export CFLAGS CXXFLAGS LDFLAGS CPPFLAGS PKG_CONFIG_PATH
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

do_ninja_build() { ensure_cmd ninja; ninja -C build -j "$JOBS"; }
do_ninja_install() { ensure_cmd ninja; DESTDIR="$DESTDIR" ninja -C build install; }

# -------------------- Python --------------------

python_install_project() {
  ensure_cmd python3
  # requer pip disponível
  python3 -m pip install --no-deps --no-build-isolation --no-index \
    --prefix /usr --root "$DESTDIR" .
}

python_setup_py_install() {
  ensure_cmd python3
  [ -f setup.py ] || adm_die "setup.py não encontrado"
  python3 setup.py build
  python3 setup.py install --root="$DESTDIR" --prefix=/usr --optimize=1
}

# -------------------- Rust / Cargo --------------------

cargo_build_release() { ensure_cmd cargo; cargo build --release -j "$JOBS"; }

cargo_install_bin() {
  bin="${1:?binname}"
  dest="${2:-/usr/bin}"
  [ -f "target/release/$bin" ] || adm_die "binário não encontrado: target/release/$bin"
  install -Dm755 "target/release/$bin" "$DESTDIR$dest/$bin"
}

# -------------------- Go --------------------

go_build() {
  ensure_cmd go
  out="${1:?output}"
  pkgspec="${2:-.}"
  CGO_ENABLED="${CGO_ENABLED:-1}" go build -trimpath -o "$out" "$pkgspec"
}

go_install_bin() {
  bin="${1:?built binary}"
  dest="${2:-/usr/bin}"
  [ -f "$bin" ] || adm_die "binário não encontrado: $bin"
  install -Dm755 "$bin" "$DESTDIR$dest/$(basename "$bin")"
}

# -------------------- Instalações comuns --------------------

install_man() {
  # uso: install_man <manfile> <section>  (ex: foo.1 1)
  f="${1:?manfile}"
  sec="${2:?section}"
  [ -f "$f" ] || adm_die "manfile não encontrado: $f"
  install -Dm644 "$f" "$DESTDIR/usr/share/man/man${sec}/$(basename "$f")"
}

install_bash_completion() {
  # uso: install_bash_completion <file>
  f="${1:?completion file}"
  [ -f "$f" ] || adm_die "arquivo não encontrado: $f"
  install -Dm644 "$f" "$DESTDIR/usr/share/bash-completion/completions/$(basename "$f")"
}

# -------------------- Pós-instalação desktop --------------------

postinstall_desktop_common() {
  have_cmd glib-compile-schemas && glib-compile-schemas /usr/share/glib-2.0/schemas || true
  have_cmd gtk-update-icon-cache && gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
  have_cmd update-desktop-database && update-desktop-database -q || true
  have_cmd update-mime-database && update-mime-database /usr/share/mime || true
  have_cmd fc-cache && fc-cache -r || true
}

# -------------------- Sanidade DESTDIR --------------------

ensure_destdir_nonempty() {
  [ -d "$DESTDIR" ] || adm_die "DESTDIR não existe: $DESTDIR"
  if [ -z "$(find "$DESTDIR" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1 || true)" ]; then
    adm_die "DESTDIR está vazia (package() instalou algo?)"
  fi
}

destdir_symlink() {
  target="${1:?target}"
  linkpath="${2:?linkpath absoluto}"
  case "$linkpath" in /*) : ;; *) adm_die "linkpath deve ser absoluto: $linkpath" ;; esac
  mkdir -p "$(dirname "$DESTDIR$linkpath")"
  ln -sf "$target" "$DESTDIR$linkpath"
}
