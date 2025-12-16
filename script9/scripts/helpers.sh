#!/bin/sh
# /usr/share/adm/helpers.sh # usar chmod 0644
# Helpers para ports do adm (POSIX sh)
# Requer que o adm exporte: PORTDIR, WORKDIR, SRCDIR, DESTDIR, JOBS (e opcionalmente PATCHDIR/FILESDIR)

set -eu

# -------------------- Mensagens / Erros --------------------

adm_msg() { printf '%s\n' "port: $*" >&2; }
adm_warn() { printf '%s\n' "port: aviso: $*" >&2; }
adm_die() { printf '%s\n' "port: erro: $*" >&2; exit 1; }

# -------------------- Ambiente / Defaults --------------------

adm_defaults() {
  : "${JOBS:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"

  : "${WORKDIR:?WORKDIR não definido}"
  : "${SRCDIR:?SRCDIR não definido}"
  : "${DESTDIR:?DESTDIR não definido}"
  : "${PORTDIR:?PORTDIR não definido}"

  : "${PATCHDIR:=${PORTDIR}/patches}"
  : "${FILESDIR:=${PORTDIR}/files}"

  : "${CFLAGS:--O2 -pipe}"
  : "${CXXFLAGS:--O2 -pipe}"
  : "${LDFLAGS:-}"

  # pkg-config search path padrão (ajuste se seu sistema usar outro layout)
  : "${PKG_CONFIG_PATH:=/usr/lib/pkgconfig:/usr/share/pkgconfig:/usr/lib64/pkgconfig}"
  export JOBS WORKDIR SRCDIR DESTDIR PORTDIR PATCHDIR FILESDIR CFLAGS CXXFLAGS LDFLAGS PKG_CONFIG_PATH

  # Builds mais determinísticos
  : "${SOURCE_DATE_EPOCH:=$(date +%s)}"
  export SOURCE_DATE_EPOCH

  # Reduz ruído em builds:
  export LC_ALL="${LC_ALL:-C}"
}

# -------------------- Checagem de comandos --------------------

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_cmd() {
  for c in "$@"; do
    have_cmd "$c" || adm_die "comando ausente: $c"
  done
}

# -------------------- Navegação no source --------------------

# Entra no diretório principal do source.
# Se o port quiser controlar: use srcdir_name no build.sh e chame enter_srcdir "$srcdir_name".
enter_srcdir() {
  cd "$SRCDIR" || adm_die "SRCDIR inválido: $SRCDIR"

  if [ "${1:-}" ]; then
    [ -d "$SRCDIR/$1" ] || adm_die "srcdir_name inválido: $SRCDIR/$1"
    cd "$SRCDIR/$1" || adm_die "falha ao entrar em $SRCDIR/$1"
    return 0
  fi

  # heurística: se existir apenas um diretório, entra nele
  set -- "$SRCDIR"/*
  if [ "$#" -eq 1 ] && [ -d "$1" ]; then
    cd "$1" || adm_die "falha ao entrar no diretório extraído"
  else
    cd "$SRCDIR" || adm_die "falha ao entrar em SRCDIR"
  fi
}

# -------------------- Patches / Files --------------------

# Aplica automaticamente todos os patches em PATCHDIR (*.patch, *.diff) em ordem lexicográfica.
apply_default_patches() {
  [ -d "$PATCHDIR" ] || return 0

  ensure_cmd patch
  # find pode retornar vazio; tratamos
  patches="$(find "$PATCHDIR" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) 2>/dev/null | sort || true)"
  [ -n "$patches" ] || return 0

  for p in $patches; do
    adm_msg "aplicando patch: $(basename "$p")"
    patch -Np1 < "$p" || adm_die "falha ao aplicar patch: $p"
  done
}

# Aplica um patch específico
apply_patch() {
  p="$1"
  [ -f "$p" ] || adm_die "patch não encontrado: $p"
  ensure_cmd patch
  patch -Np1 < "$p" || adm_die "falha ao aplicar patch: $p"
}

# Copia um arquivo do FILESDIR para o DESTDIR preservando caminhos relativos.
# Uso: install_files_into_destdir "usr/share/applications/foo.desktop"
install_files_into_destdir() {
  rel="${1:?caminho relativo obrigatório}"
  src="${FILESDIR}/${rel}"
  dst="${DESTDIR}/${rel}"
  [ -e "$src" ] || adm_die "arquivo não encontrado em files/: $rel"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
}

# Instala um arquivo do FILESDIR para um destino absoluto dentro do DESTDIR.
# Uso: install_file "foo.conf" "/etc/foo.conf"
install_file() {
  src_rel="${1:?arquivo em files/ obrigatório}"
  dst_abs="${2:?destino absoluto obrigatório}"
  case "$dst_abs" in
    /*) : ;;
    *) adm_die "destino deve ser absoluto: $dst_abs" ;;
  esac
  src="${FILESDIR}/${src_rel}"
  dst="${DESTDIR}${dst_abs}"
  [ -e "$src" ] || adm_die "arquivo não encontrado em files/: $src_rel"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
}

# -------------------- Utilidades de build --------------------

# Ajusta flags para builds comuns (pode ser sobrescrito pelo port)
export_common_build_env() {
  export CFLAGS CXXFLAGS LDFLAGS
  # Para autotools e afins:
  export CPPFLAGS="${CPPFLAGS:-}"
  export MAKEFLAGS="${MAKEFLAGS:--j${JOBS}}"
}

# Remove RPATHs triviais (opcional; use com cautela).
# Requer patchelf. Só remove se encontrar RPATH/RUNPATH não vazio.
strip_rpath_in_destdir() {
  have_cmd patchelf || return 0
  find "$DESTDIR" -type f -perm -111 2>/dev/null | while IFS= read -r f; do
    # patchelf falha em não-ELF; ignorar
    r="$(patchelf --print-rpath "$f" 2>/dev/null || true)"
    [ -n "$r" ] || continue
    patchelf --remove-rpath "$f" 2>/dev/null || true
  done
}

# Strip opcional (não recomendado para pacotes debug)
strip_binaries_in_destdir() {
  have_cmd strip || return 0
  find "$DESTDIR" -type f -perm -111 2>/dev/null | while IFS= read -r f; do
    strip --strip-unneeded "$f" 2>/dev/null || true
  done
}

# -------------------- Autotools (configure/make) --------------------

do_autoreconf() {
  ensure_cmd autoreconf
  autoreconf -fiv
}

do_configure() {
  # uso: do_configure [args...]
  export_common_build_env
  ensure_cmd ./configure
  ./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    "$@"
}

do_make() {
  ensure_cmd make
  make -j"$JOBS" "$@"
}

do_make_install() {
  ensure_cmd make
  make DESTDIR="$DESTDIR" "$@" install
}

# -------------------- CMake --------------------

do_cmake_configure() {
  # uso: do_cmake_configure <srcdir> [args...]
  ensure_cmd cmake
  src="${1:?srcdir}"
  shift

  export_common_build_env

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

do_cmake_build() {
  ensure_cmd cmake
  cmake --build build -j "$JOBS"
}

do_cmake_install() {
  ensure_cmd cmake
  cmake --install build --prefix /usr --destdir "$DESTDIR"
}

# -------------------- Meson / Ninja --------------------

do_meson_setup() {
  # uso: do_meson_setup <srcdir> [args...]
  ensure_cmd meson ninja
  src="${1:?srcdir}"
  shift

  export_common_build_env

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
  ninja -C build -j "$JOBS"
}

do_ninja_install() {
  ensure_cmd ninja
  DESTDIR="$DESTDIR" ninja -C build install
}

# -------------------- Python --------------------

# Instala um projeto python no DESTDIR.
# Preferência: pip (sem internet) a partir do diretório local.
python_install_prefix_root() {
  ensure_cmd python3
  # pip pode não existir no bootstrap; trate isso no port.
  ensure_cmd python3
  python3 -m pip install --no-deps --no-build-isolation --no-index \
    --prefix /usr --root "$DESTDIR" .
}

# fallback setup.py clássico
python_setup_py_install() {
  ensure_cmd python3
  [ -f setup.py ] || adm_die "setup.py não encontrado"
  python3 setup.py build
  python3 setup.py install --root="$DESTDIR" --prefix=/usr --optimize=1
}

# -------------------- Rust / Cargo --------------------

cargo_build_release() {
  ensure_cmd cargo
  cargo build --release -j "$JOBS"
}

cargo_install_destdir() {
  # instala binários manualmente (mais previsível que cargo install em sysroot)
  # uso: cargo_install_destdir <binname> [dest=/usr/bin]
  bin="${1:?binname}"
  dest="${2:-/usr/bin}"
  [ -f "target/release/$bin" ] || adm_die "binário não encontrado: target/release/$bin"
  install -Dm755 "target/release/$bin" "$DESTDIR$dest/$bin"
}

# -------------------- Go --------------------

go_build() {
  ensure_cmd go
  # uso: go_build <output> [pkgspec]
  out="${1:?output}"
  pkgspec="${2:-.}"
  CGO_ENABLED="${CGO_ENABLED:-1}" go build -trimpath -ldflags="${GO_LDFLAGS:-}" -o "$out" "$pkgspec"
}

go_install_destdir() {
  # uso: go_install_destdir <built_binary> [dest=/usr/bin]
  bin="${1:?built binary}"
  dest="${2:-/usr/bin}"
  [ -f "$bin" ] || adm_die "binário não encontrado: $bin"
  install -Dm755 "$bin" "$DESTDIR$dest/$(basename "$bin")"
}

# -------------------- Pós-instalação desktop (comum) --------------------

postinstall_desktop_common() {
  # Use em post_install() de pacotes desktop para atualizar caches globais.
  have_cmd glib-compile-schemas && glib-compile-schemas /usr/share/glib-2.0/schemas || true
  have_cmd gtk-update-icon-cache && gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
  have_cmd update-desktop-database && update-desktop-database -q || true
  have_cmd update-mime-database && update-mime-database /usr/share/mime || true
  have_cmd fc-cache && fc-cache -r || true
}

# -------------------- Sanidade / validação de staging --------------------

# Garante que DESTDIR não está vazia e contém algo para empacotar
ensure_destdir_nonempty() {
  [ -d "$DESTDIR" ] || adm_die "DESTDIR não existe: $DESTDIR"
  # deve ter pelo menos um arquivo/dir além do topo
  if [ -z "$(find "$DESTDIR" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1 || true)" ]; then
    adm_die "DESTDIR está vazia (package() instalou algo?)"
  fi
}

# Cria symlink dentro do DESTDIR de forma segura
destdir_symlink() {
  target="${1:?target}"
  linkpath="${2:?linkpath absoluto}"
  case "$linkpath" in
    /*) : ;;
    *) adm_die "linkpath deve ser absoluto: $linkpath" ;;
  esac
  mkdir -p "$(dirname "$DESTDIR$linkpath")"
  ln -sf "$target" "$DESTDIR$linkpath"
}
