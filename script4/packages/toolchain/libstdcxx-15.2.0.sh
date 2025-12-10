#!/usr/bin/env bash
# toolchain/libstdcxx-15.2.0.sh
# libstdc++ (C++) a partir do GCC-15.2.0, para o sistema alvo.
# Constrói somente libstdc++-v3 a partir dos fontes do GCC.
# Instala em ${ADM_DESTDIR}/usr.
# Compatível com o adm.sh corrigido.

set -euo pipefail

###############################################################################
# Metadados
###############################################################################

PKG_NAME="libstdcxx-15.2.0"
PKG_CATEGORY="toolchain"
PKG_VERSION="15.2.0"

# Usamos o mesmo tarball do GCC-15.2.0 (aproveita o cache do adm)
PKG_SOURCES=(
  "https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz"
)

PKG_SHA256S=(
  ""
)

PKG_MD5S=(
  ""
)

# Dependências lógicas dentro do adm:
# - libc já instalada no rootfs (glibc/musl, aqui assumo glibc)
# - toolchain/gcc-pass1 (toolchain /tools) ou seu GCC final, se você criar outro pacote.
PKG_DEPENDS=(
  "toolchain/glibc-2.42"
  "toolchain/gcc-pass1"
)

###############################################################################
# Helpers internos
###############################################################################

_log() {
  printf '[%s] %s\n' "${PKG_NAME}" "$*" >&2
}

_detect_arch() {
  local triplet="${ADM_TRIPLET:-}"
  if [[ "${triplet}" == x86_64-* ]]; then
    echo "x86_64"
  elif [[ "${triplet}" == aarch64-* ]]; then
    echo "aarch64"
  elif [[ "${triplet}" == i?86-* ]]; then
    echo "i386"
  else
    uname -m
  fi
}

###############################################################################
# Hooks de uninstall integrados
###############################################################################

pkg_pre_uninstall() {
  _log "pre-uninstall: você está removendo a libstdc++ do profile ${ADM_PROFILE:-?}."
  _log "ATENÇÃO: programas C++ desse rootfs podem parar de funcionar."
}

pkg_post_uninstall() {
  _log "post-uninstall: libstdc++ removida do profile ${ADM_PROFILE:-?}."
}

###############################################################################
# Build
###############################################################################

pkg_build() {
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_BUILD_DIR:?ADM_BUILD_DIR não definido}"

  _log "Iniciando build do libstdc++ a partir do GCC ${PKG_VERSION}"
  _log "Rootfs do perfil : ${ADM_ROOTFS}"
  _log "Triplet de alvo  : ${ADM_TRIPLET}"
  _log "Diretório de src : ${ADM_BUILD_DIR}"

  # CWD: diretório gcc-15.2.0 (o adm já extraiu)
  cd "${ADM_BUILD_DIR}"

  # Diretório de build específico só para libstdc++-v3
  rm -rf build-libstdcxx
  mkdir -pv build-libstdcxx
  cd build-libstdcxx

  local build
  build="$(../config.guess)"
  local host="${ADM_TRIPLET}"

  _log "Configurando libstdc++-v3:"
  _log "  --build=${build}"
  _log "  --host=${host}"
  _log "  --prefix=/usr"

  # Configuração inspirada no LFS para libstdc++ a partir do GCC,
  # adaptada para GCC-15.2.0.
  ../libstdc++-v3/configure \
    --build="${build}"       \
    --host="${host}"         \
    --prefix=/usr            \
    --disable-multilib       \
    --disable-nls            \
    --disable-libstdcxx-pch

  _log "Compilando libstdc++"
  make -j"$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)"

  _log "Build de libstdc++ concluído"
}

###############################################################################
# Instalação
###############################################################################

pkg_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_BUILD_DIR:?ADM_BUILD_DIR não definido}"

  _log "Instalando libstdc++ em ${ADM_DESTDIR}/usr"

  cd "${ADM_BUILD_DIR}/build-libstdcxx"

  # Instala libstdc++ para o rootfs do profile
  make DESTDIR="${ADM_DESTDIR}" install

  _log "Instalação de libstdc++ concluída"
  # O adm chamará pkg_post_install automaticamente após pkg_install.
}

###############################################################################
# Sanity-check integrado (chamado pelo adm após pkg_install)
###############################################################################

pkg_post_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

  _log "Executando sanity-check da libstdc++ instalada"

  local libdir
  local arch
  arch="$(_detect_arch)"

  # Checa alguns caminhos prováveis
  if [[ -d "${ADM_DESTDIR}/usr/lib/${ADM_TRIPLET}" ]]; then
    libdir="${ADM_DESTDIR}/usr/lib/${ADM_TRIPLET}"
  elif [[ "${arch}" == "x86_64" && -d "${ADM_DESTDIR}/usr/lib64" ]]; then
    libdir="${ADM_DESTDIR}/usr/lib64"
  else
    libdir="${ADM_DESTDIR}/usr/lib"
  fi

  local stdlib_so
  stdlib_so="$(ls "${libdir}"/libstdc++.so.* 2>/dev/null | head -n1 || true)"

  if [[ -z "${stdlib_so}" ]]; then
    _log "ERRO: não encontrei libstdc++.so.* em ${libdir}"
    return 1
  fi

  _log "Encontrado libstdc++: ${stdlib_so}"

  # Verifica diretório de includes C++
  local inc_base="${ADM_DESTDIR}/usr/include/c++"
  local inc_ver=""

  if [[ -d "${inc_base}" ]]; then
    inc_ver="$(find "${inc_base}" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
  fi

  if [[ -z "${inc_ver}" ]]; then
    _log "ERRO: não encontrei diretório de includes C++ em ${inc_base}"
    return 1
  fi

  _log "Includes C++ encontrados em: ${inc_ver}"

  # Opcional: se tiver readelf, checar se a libstdc++ é ELF válido
  if command -v readelf >/dev/null 2>&1; then
    _log "Validando ELF de ${stdlib_so} com readelf"
    if ! readelf -h "${stdlib_so}" >/dev/null 2>&1; then
      _log "ERRO: readelf falhou ao analisar ${stdlib_so}"
      return 1
    fi
  else
    _log "AVISO: 'readelf' não encontrado; sanidade ELF não verificada."
  fi

  _log "Sanity-check de libstdc++ concluído com sucesso"

  # Log dentro do rootfs
  local logdir="${ADM_DESTDIR}/var/log"
  local logfile="${logdir}/adm-libstdcxx-15.2.0.log"

  mkdir -p "${logdir}"

  {
    printf 'libstdc++ (GCC %s) sanity-check\n' "${PKG_VERSION}"
    printf 'Profile : %s\n' "${ADM_PROFILE:-unknown}"
    printf 'Triplet : %s\n' "${ADM_TRIPLET}"
    printf 'Rootfs  : %s\n' "${ADM_ROOTFS}"
    printf 'Data    : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Libdir  : %s\n' "${libdir}"
    printf 'Lib     : %s\n' "${stdlib_so}"
    printf 'Includes: %s\n' "${inc_ver}"
  } > "${logfile}.tmp"

  mv -f "${logfile}.tmp" "${logfile}"

  # Marker para indicar que a libstdc++ está instalada e verificada
  local marker="${ADM_DESTDIR}/.adm_libstdcxx_${PKG_VERSION}_sane"
  echo "ok" > "${marker}"

  _log "Sanity-check de libstdc++ registrado em ${logfile}"
  _log "Marker criado em ${marker}"
}
