#!/bin/sh
set -eu

# Este pacote não baixa nem compila nada.
# Ele cria symlinks no pós-instalação (hook) porque precisa do FS real.

: "${TARGET:=x86_64-linux-musl}"
: "${TC_PREFIX:=/state/toolchain/prefix}"
: "${PM_PREFIX:=/usr/local}"

hook_pre_install() { :; }

hook_post_install() {
  # Cria symlinks no FS real.
  # Requisitos: ln, test
  bindir="${PM_PREFIX}/bin"
  mkdir -p "$bindir"

  # Ferramentas alvo
  tcbin="${TC_PREFIX}/bin"

  # Lista (link, alvo)
  # Nota: só cria se o alvo existir.
  link_one() {
    link=$1
    tgt=$2
    if [ -x "${tcbin}/${tgt}" ] || [ -f "${tcbin}/${tgt}" ]; then
      # substitui se já existir (comportamento previsível)
      rm -f "${bindir}/${link}" 2>/dev/null || true
      ln -s "${tcbin}/${tgt}" "${bindir}/${link}"
    fi
  }

  # Compiladores
  link_one cc   "${TARGET}-gcc"
  link_one c++  "${TARGET}-g++"

  # Binutils comuns
  link_one as       "${TARGET}-as"
  link_one ld       "${TARGET}-ld"
  link_one ar       "${TARGET}-ar"
  link_one ranlib   "${TARGET}-ranlib"
  link_one strip    "${TARGET}-strip"
  link_one nm       "${TARGET}-nm"
  link_one objcopy  "${TARGET}-objcopy"
  link_one objdump  "${TARGET}-objdump"
  link_one readelf  "${TARGET}-readelf"

  # Opcional: outros utilitários se presentes
  link_one addr2line "${TARGET}-addr2line"
  link_one c++filt   "${TARGET}-c++filt"
  link_one size      "${TARGET}-size"
  link_one strings   "${TARGET}-strings"

  :
}

hook_pre_remove() {
  # Remove links que apontam para TC_PREFIX/bin/<TARGET>-...
  bindir="${PM_PREFIX}/bin"
  tcbin="${TC_PREFIX}/bin"

  remove_if_points_to_tc() {
    link=$1
    p="${bindir}/${link}"
    if [ -L "$p" ]; then
      tgt=$(readlink "$p" 2>/dev/null || echo "")
      case "$tgt" in
        "${tcbin}/"*) rm -f "$p" 2>/dev/null || true ;;
      esac
    fi
  }

  for l in cc c++ as ld ar ranlib strip nm objcopy objdump readelf addr2line c++filt size strings; do
    remove_if_points_to_tc "$l"
  done
}

hook_post_remove() { :; }

pkg_fetch()  { :; }
pkg_unpack() { :; }
pkg_build()  { :; }

pkg_install() {
  # Nenhum arquivo precisa ser instalado em DESTDIR.
  # (Hooks fazem o trabalho no FS real.)
  :
}
