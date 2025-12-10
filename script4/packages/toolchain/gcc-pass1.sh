#!/usr/bin/env bash
# toolchain/gcc-pass1.sh
# GCC-15.2.0 - Pass 1
# Cross-GCC temporário instalado em /tools dentro do rootfs do perfil.
# Compatível com o gerenciador "adm" (adm.sh corrigido).

set -euo pipefail

###############################################################################
# Metadados
###############################################################################

PKG_NAME="gcc-pass1"
PKG_CATEGORY="toolchain"
PKG_VERSION="15.2.0"

# Fontes principais (GCC + MPFR + GMP + MPC)
# Preencha SHA/MD5 exatos se quiser validação rígida.
PKG_SOURCES=(
  "https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz"
  "https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz"
  "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
  "https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"
)

PKG_SHA256S=(
  ""  # gcc-15.2.0.tar.xz
  ""  # mpfr-4.2.2.tar.xz
  ""  # gmp-6.3.0.tar.xz
  ""  # mpc-1.3.1.tar.gz
)

PKG_MD5S=(
  ""  # gcc-15.2.0.tar.xz
  ""  # mpfr-4.2.2.tar.xz
  ""  # gmp-6.3.0.tar.xz
  ""  # mpc-1.3.1.tar.gz
)

# Dependências lógicas (ajuste conforme seu grafo de deps)
PKG_DEPENDS=(
  "toolchain/binutils-pass1"
  "toolchain/linux-api-headers"
)

###############################################################################
# Helpers internos
###############################################################################

_log() {
  printf '[%s] %s\n' "${PKG_NAME}" "$*" >&2
}

# Acha um source (tarball) primeiro em .. e depois em ${ADM_SRC_CACHE}
_find_source() {
  local fname="$1"
  if [[ -f "../${fname}" ]]; then
    printf '%s\n' "../${fname}"
    return 0
  fi
  if [[ -n "${ADM_SRC_CACHE:-}" && -f "${ADM_SRC_CACHE}/${fname}" ]]; then
    printf '%s\n' "${ADM_SRC_CACHE}/${fname}"
    return 0
  fi
  return 1
}

###############################################################################
# Hooks de uninstall integrados
###############################################################################

pkg_pre_uninstall() {
  _log "pre-uninstall: preparando remoção do GCC Pass 1 de /tools (perfil: ${ADM_PROFILE:-?})"
  _log "ATENÇÃO: libc e toolchain podem depender desse cross-GCC."
}

pkg_post_uninstall() {
  _log "post-uninstall: GCC Pass 1 removido (perfil: ${ADM_PROFILE:-?})"
}

###############################################################################
# Build
###############################################################################

pkg_build() {
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_BUILD_DIR:?ADM_BUILD_DIR não definido}"

  _log "Iniciando build de GCC ${PKG_VERSION} (Pass 1)"
  _log "Rootfs do perfil : ${ADM_ROOTFS}"
  _log "Triplet de alvo  : ${ADM_TRIPLET}"
  _log "Diretório de src : ${ADM_BUILD_DIR}"

  # CWD aqui deve ser o diretório gcc-15.2.0 (o adm já extraiu)
  cd "${ADM_BUILD_DIR}"

  # Integra MPFR/GMP/MPC na árvore do GCC, como recomenda o LFS.
  _log "Preparando subpacotes MPFR/GMP/MPC dentro da árvore do GCC"

  rm -rf mpfr gmp mpc

  local mpfr_tar gmp_tar mpc_tar

  mpfr_tar="$(_find_source 'mpfr-4.2.2.tar.xz')" || {
    _log "ERRO: não encontrei mpfr-4.2.2.tar.xz nem em .. nem em ${ADM_SRC_CACHE:-?}"
    return 1
  }
  gmp_tar="$(_find_source 'gmp-6.3.0.tar.xz')" || {
    _log "ERRO: não encontrei gmp-6.3.0.tar.xz nem em .. nem em ${ADM_SRC_CACHE:-?}"
    return 1
  }
  mpc_tar="$(_find_source 'mpc-1.3.1.tar.gz')" || {
    _log "ERRO: não encontrei mpc-1.3.1.tar.gz nem em .. nem em ${ADM_SRC_CACHE:-?}"
    return 1
  }

  _log "Extraindo MPFR de ${mpfr_tar}"
  tar -xf "${mpfr_tar}"
  mv -v mpfr-4.2.2 mpfr

  _log "Extraindo GMP de ${gmp_tar}"
  tar -xf "${gmp_tar}"
  mv -v gmp-6.3.0 gmp

  _log "Extraindo MPC de ${mpc_tar}"
  tar -xf "${mpc_tar}"
  mv -v mpc-1.3.1 mpc

  # Ajuste em t-linux64 para x86_64 (lib vs lib64), como no LFS.
  case "$(uname -m)" in
    x86_64)
      _log "Arquitetura x86_64: ajustando t-linux64 (lib64 -> lib)"
      sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
      ;;
  esac

  # Diretório de build separado
  rm -rf build
  mkdir -pv build
  cd build

  local sysroot="${ADM_ROOTFS}"
  local target="${ADM_TRIPLET}"

  _log "Configurando GCC (Pass 1):"
  _log "  target  = ${target}"
  _log "  prefix  = /tools (via DESTDIR=${ADM_DESTDIR:-<definido pelo adm>})"
  _log "  sysroot = ${sysroot}"

  # Configuração baseada em GCC Pass 1 do LFS, adaptada para 15.2.0
  ../configure                  \
    --target="${target}"        \
    --prefix=/tools             \
    --with-sysroot="${sysroot}" \
    --with-glibc-version=2.42   \
    --with-newlib               \
    --without-headers           \
    --enable-default-pie        \
    --enable-default-ssp        \
    --disable-nls               \
    --disable-shared            \
    --disable-multilib          \
    --disable-threads           \
    --disable-libatomic         \
    --disable-libgomp           \
    --disable-libquadmath       \
    --disable-libssp            \
    --disable-libvtv            \
    --disable-libstdcxx         \
    --enable-languages=c,c++

  _log "Compilando GCC (Pass 1)"
  make -j"$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)"

  _log "Build de GCC (Pass 1) concluído"
}

###############################################################################
# Instalação
###############################################################################

pkg_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
  : "${ADM_BUILD_DIR:?ADM_BUILD_DIR não definido}"

  _log "Instalando GCC ${PKG_VERSION} (Pass 1) em ${ADM_DESTDIR}/tools"

  cd "${ADM_BUILD_DIR}/build"

  # Instala cross-GCC em /tools dentro do rootfs (ADM_DESTDIR)
  make DESTDIR="${ADM_DESTDIR}" install

  _log "Instalação base de GCC (Pass 1) concluída"
  # O adm chamará pkg_post_install automaticamente após pkg_install.
}

###############################################################################
# Sanity-check integrado (chamado pelo adm após pkg_install)
###############################################################################

pkg_post_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

  local tools_root="${ADM_DESTDIR}/tools"
  local tools_bin="${tools_root}/bin"
  local gcc_cross="${tools_bin}/${ADM_TRIPLET}-gcc"

  _log "Executando sanity-check do GCC Pass 1 em ${tools_bin}"

  if [[ ! -x "${gcc_cross}" ]]; then
    _log "ERRO: cross-GCC não encontrado: ${gcc_cross}"
    return 1
  fi

  local out
  if ! out="$("${gcc_cross}" -v 2>&1)"; then
    _log "ERRO: ${gcc_cross} -v falhou"
    return 1
  fi

  _log "Cross-GCC responde corretamente (teste -v OK)"

  # Log dentro do rootfs
  local logdir="${ADM_DESTDIR}/var/log"
  local logfile="${logdir}/adm-gcc-pass1.log"

  mkdir -p "${logdir}"

  {
    printf 'GCC Pass 1 sanity-check\n'
    printf 'Versão  : %s\n' "${PKG_VERSION}"
    printf 'Profile : %s\n' "${ADM_PROFILE:-unknown}"
    printf 'Triplet : %s\n' "${ADM_TRIPLET}"
    printf 'Rootfs  : %s\n' "${ADM_ROOTFS}"
    printf 'Data    : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '\n===== %s -v =====\n' "${gcc_cross}"
    printf '%s\n' "${out}"
  } > "${logfile}.tmp"

  mv -f "${logfile}.tmp" "${logfile}"

  # Marker para outros pacotes/tooling saberem que o GCC Pass 1 está OK
  local marker="${tools_root}/.adm_gcc_pass1_sane"
  echo "ok" > "${marker}"

  _log "Sanity-check de GCC Pass 1 registrado em ${logfile}"
  _log "Marker criado em ${marker}"
}
