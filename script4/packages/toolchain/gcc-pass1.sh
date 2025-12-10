#!/usr/bin/env bash
# toolchain/gcc-pass1.sh
# GCC-15.2.0 - Pass 1
# Cross-GCC temporário instalado em /tools dentro do rootfs do profile.
# Compatível com o gerenciador "adm" (pkg_build/pkg_install + hooks).

set -euo pipefail

###############################################################################
# Metadados
###############################################################################

PKG_NAME="gcc-pass1"
PKG_CATEGORY="toolchain"
PKG_VERSION="15.2.0"

# Fontes (GCC + GMP + MPFR + MPC)
# GCC URL + MD5 a partir do BLFS (15.2.0). 
# GMP/MPFR/MPC versões e MD5 conforme LFS/BLFS/Debian orig. 
PKG_SOURCES=(
  "https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz"
  "https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz"
  "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
  "https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"
)

PKG_MD5S=(
  "b861b092bf1af683c46a8aa2e689a6fd" # gcc-15.2.0.tar.xz
  "7c32c39b8b6e3ae85f25156228156061" # mpfr-4.2.2.tar.xz (orig.tar.xz)
  "956dc04e864001a9c22429f761f2c283" # gmp-6.3.0.tar.xz
  "5c9bc658c9fd0f940e8e3e0f09530c62" # mpc-1.3.1.tar.gz
)

PKG_SHA256S=(
  "" "" "" ""
)

# Dependências lógicas dentro do teu sistema de pacotes (toolchain host / binutils pass1 etc.)
PKG_DEPENDS=(
  "toolchain/binutils-pass1"
  # aqui poderiam entrar coisas como "host/m4", "host/flex", "host/bison" etc.
)

###############################################################################
# Helpers internos
###############################################################################

_log() {
  printf '[%s] %s\n' "${PKG_NAME}" "$*" >&2
}

# Localiza um arquivo de source, primeiro em .. (caso seu adm jogue lá),
# depois em ${ADM_SRC_CACHE}, se definido.
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

# Aplica patches automaticamente (se ADM_PATCH_DIR estiver definido)
_apply_patches_if_any() {
  local pkgdir="gcc-15.2.0"
  local base="${ADM_PATCH_DIR:-}"

  [[ -z "${base}" ]] && return 0

  local dir="${base}"
  if [[ -d "${base}/${pkgdir}" ]]; then
    dir="${base}/${pkgdir}"
  fi

  if compgen -G "${dir}/*.patch" > /dev/null 2>&1; then
    _log "Aplicando patches em $(pwd)"
    for p in "${dir}"/*.patch; do
      [[ -f "${p}" ]] || continue
      _log "  patch $(basename "${p}")"
      patch -p1 < "${p}"
    done
  fi
}

###############################################################################
# Hooks de uninstall integrados
###############################################################################

pkg_pre_uninstall() {
  _log "pre-uninstall: preparando remoção do GCC Pass 1 de /tools (perfil: ${ADM_PROFILE:-?})"
}

pkg_post_uninstall() {
  _log "post-uninstall: GCC Pass 1 removido (perfil: ${ADM_PROFILE:-?})"
}

###############################################################################
# pkg_build
###############################################################################

pkg_build() {
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"

  _log "Iniciando build de GCC ${PKG_VERSION} (Pass 1) para alvo ${ADM_TRIPLET}"
  _log "Rootfs do perfil: ${ADM_ROOTFS}"

  # CWD aqui deve ser o diretório da árvore do GCC (gcc-15.2.0)
  local srcdir
  srcdir="$(pwd)"

  # Aplica patches, se houver
  _apply_patches_if_any

  # Integra GMP/MPFR/MPC dentro da árvore do GCC,
  # como manda o LFS 12.4 (tar -xf ../mpfr-4.2.2.tar.xz; mv ... mpfr; etc.). 
  _log "Preparando subpacotes GMP/MPFR/MPC dentro da árvore do GCC"

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

  # Ajuste x86_64: sed no t-linux64, como no LFS. 
  case "$(uname -m)" in
    x86_64)
      _log "Arquitetura x86_64: ajustando t-linux64 (lib -> lib64)"
      sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
      ;;
  esac

  # Diretório de build separado (recomendado pela documentação do GCC). 
  rm -rf build
  mkdir -pv build
  cd build

  local sysroot="${ADM_ROOTFS}"
  local target="${ADM_TRIPLET}"

  _log "Configurando GCC (Pass 1):"
  _log "  target  = ${target}"
  _log "  prefix  = /tools (via DESTDIR=${ADM_DESTDIR:-<não definido ainda>})"
  _log "  sysroot = ${sysroot}"

  # Configuração baseada em LFS 12.4 GCC-15.2.0 Pass 1, adaptando:
  #   $LFS_TGT    -> ${ADM_TRIPLET}
  #   $LFS/tools  -> /tools (DESTDIR=${ADM_DESTDIR})
  #   $LFS        -> ${ADM_ROOTFS} 
  ../configure                  \
    --target="${target}"        \
    --prefix=/tools             \
    --with-glibc-version=2.42   \
    --with-sysroot="${sysroot}" \
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
# pkg_install + sanity-check integrado
###############################################################################

pkg_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

  _log "Instalando GCC ${PKG_VERSION} (Pass 1) em ${ADM_DESTDIR}/tools"

  # Voltamos ao diretório de build
  cd build

  make DESTDIR="${ADM_DESTDIR}" install

  _log "Instalação de GCC (Pass 1) concluída; rodando pkg_post_install (sanity)"
  pkg_post_install
}

pkg_post_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

  local tools_root="${ADM_DESTDIR}/tools"
  local tools_bin="${tools_root}/bin"
  local gcc_cross="${tools_bin}/${ADM_TRIPLET}-gcc"

  if [[ ! -x "${gcc_cross}" ]]; then
    _log "ERRO: não encontrei o cross-GCC instalado em ${gcc_cross}"
    return 1
  fi

  _log "Sanity-check simples: ${gcc_cross} -v"

  local out
  if ! out="$("${gcc_cross}" -v 2>&1)"; then
    _log "ERRO: ${gcc_cross} -v falhou"
    return 1
  fi

  _log "Cross-GCC (Pass 1) responde corretamente"

  # Log dentro do rootfs
  local logdir="${ADM_DESTDIR}/var/log"
  local logfile="${logdir}/adm-gcc-pass1.log"

  mkdir -p "${logdir}"

  {
    printf 'GCC Pass 1 sanity-check\n'
    printf 'Profile : %s\n' "${ADM_PROFILE:-unknown}"
    printf 'Triplet : %s\n' "${ADM_TRIPLET}"
    printf 'Rootfs  : %s\n' "${ADM_ROOTFS}"
    printf 'Data    : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '\n%s\n' "===== ${gcc_cross} -v ====="
    printf '%s\n' "${out}"
  } > "${logfile}.tmp"

  mv -f "${logfile}.tmp" "${logfile}"

  # Marker para outros scripts/tooling saberem que o GCC Pass1 está OK
  local marker="${tools_root}/.adm_gcc_pass1_sane"
  echo "ok" > "${marker}"

  _log "Sanity-check de GCC Pass 1 registrado em ${logfile}"
  _log "Marker criado em ${marker}"
}
