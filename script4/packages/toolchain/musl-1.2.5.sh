#!/usr/bin/env bash
# toolchain/musl-1.2.5.sh
# musl-1.2.5 para o sistema alvo (profile "musl"), com patches de segurança
# CVE-2025-26519 aplicados automaticamente via ${ADM_PATCH_DIR}/musl-1.2.5/*.patch.
# Instala em ${ADM_DESTDIR} (rootfs do profile), NÃO em /tools.
# Compatível com adm.sh corrigido.

set -euo pipefail

###############################################################################
# Metadados
###############################################################################

PKG_NAME="musl-1.2.5"
PKG_CATEGORY="toolchain"
PKG_VERSION="1.2.5"

# Fonte oficial do musl
PKG_SOURCES=(
  "https://musl.libc.org/releases/musl-1.2.5.tar.gz"
)

# Preencha se quiser validação rígida
PKG_SHA256S=(
  ""
)
PKG_MD5S=(
  ""
)

# Dependências lógicas dentro do adm:
# - headers de kernel já instalados no rootfs (linux-api-headers)
# - toolchain cross binutils/gcc já funcional
PKG_DEPENDS=(
  "toolchain/linux-api-headers"
  "toolchain/binutils-pass1"
  "toolchain/gcc-pass1"
)

###############################################################################
# Helpers internos
###############################################################################

_log() {
  printf '[%s] %s\n' "${PKG_NAME}" "$*" >&2
}

_detect_musl_arch() {
  # Traduz ADM_TRIPLET para ARCH usado no nome do loader ld-musl-ARCH.so.1
  local triplet="${ADM_TRIPLET:-}"
  case "${triplet}" in
    x86_64-*)  echo "x86_64" ;;
    aarch64-*) echo "aarch64" ;;
    arm*-*)    echo "arm" ;;
    i?86-*)    echo "i386" ;;
    riscv64-*) echo "riscv64" ;;
    loongarch64-*) echo "loongarch64" ;;
    ppc64le-*) echo "powerpc64le" ;;
    ppc64-*)   echo "powerpc64" ;;
    ppc-*)     echo "powerpc" ;;
    s390x-*)   echo "s390x" ;;
    *)         uname -m ;;
  esac
}

_apply_security_patches() {
  # Aplica patches de segurança (CVE-2025-26519) se existirem em:
  #   ${ADM_PATCH_DIR}/musl-1.2.5/*.patch
  local base="${ADM_PATCH_DIR:-}"
  local pdir="${base}/musl-1.2.5"

  if [[ ! -d "${pdir}" ]]; then
    _log "Nenhum diretório de patches específico encontrado em ${pdir}; seguindo sem aplicar patches."
    return 0
  fi

  shopt -s nullglob
  local patches=("${pdir}"/*.patch)
  shopt -u nullglob

  if ((${#patches[@]} == 0)); then
    _log "Nenhum arquivo *.patch encontrado em ${pdir}; seguindo sem aplicar patches."
    return 0
  fi

  _log "Aplicando patches de segurança da musl (CVE-2025-26519) a partir de ${pdir}:"
  local p
  for p in "${patches[@]}"; do
    _log "  patch: $(basename "${p}")"
    patch -Np1 -i "${p}"
  done
}

###############################################################################
# Hooks de uninstall integrados
###############################################################################

pkg_pre_uninstall() {
  _log "pre-uninstall: você está removendo a musl do profile ${ADM_PROFILE:-?}."
  _log "ATENÇÃO: isso pode quebrar todos os binários desse rootfs que dependem de musl."
}

pkg_post_uninstall() {
  _log "post-uninstall: musl-1.2.5 removida do profile ${ADM_PROFILE:-?}."
}

###############################################################################
# Build
###############################################################################

pkg_build() {
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_BUILD_DIR:?ADM_BUILD_DIR não definido}"
  : "${ADM_PROFILE:?ADM_PROFILE não definido}"

  if [[ "${ADM_PROFILE}" != "musl" ]]; then
    _log "ERRO: este pacote é apenas para profile 'musl' (ADM_PROFILE=${ADM_PROFILE})."
    return 1
  fi

  _log "Iniciando build da musl ${PKG_VERSION} para o rootfs ${ADM_ROOTFS}"
  _log "Triplet de alvo : ${ADM_TRIPLET}"
  _log "Diretório de src: ${ADM_BUILD_DIR}"

  # CWD: diretório musl-1.2.5 (o adm já extraiu)
  cd "${ADM_BUILD_DIR}"

  # Aplica patches de segurança (se presentes)
  _apply_security_patches

  # Diretório de build separado (não é obrigatório, mas ajuda a manter limpo)
  rm -rf build
  mkdir -pv build
  cd build

  local target="${ADM_TRIPLET}"
  local sysroot="${ADM_DESTDIR}"

  _log "Configurando musl-1.2.5:"
  _log "  target    = ${target}"
  _log "  prefix    = /usr"
  _log "  syslibdir = /lib"
  _log "  sysroot   = ${sysroot} (via DESTDIR na instalação)"

  # Usamos CROSS_COMPILE e CC explícitos para garantir o uso do cross-toolchain.
  # A opção --target controla o nome do loader ld-musl-ARCH.so.1 e paths.
  CC="${target}-gcc" \
  CROSS_COMPILE="${target}-" \
  ../configure \
    --prefix=/usr \
    --target="${target}" \
    --syslibdir=/lib

  _log "Compilando musl-1.2.5"
  make -j"$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)"

  _log "Build da musl-1.2.5 concluído"
}

###############################################################################
# Instalação
###############################################################################

pkg_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_BUILD_DIR:?ADM_BUILD_DIR não definido}"

  _log "Instalando musl-1.2.5 em ${ADM_DESTDIR}"

  cd "${ADM_BUILD_DIR}/build"

  # Instala no rootfs do profile via DESTDIR
  make DESTDIR="${ADM_DESTDIR}" install

  _log "Instalação da musl-1.2.5 concluída (arquivos gravados em ${ADM_DESTDIR})"
  # O adm chamará pkg_post_install automaticamente após pkg_install.
}

###############################################################################
# Sanity-check integrado (chamado pelo adm após pkg_install)
###############################################################################

pkg_post_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

  _log "Executando sanity-check da musl-1.2.5 no rootfs"

  local arch
  arch="$(_detect_musl_arch)"

  local loader="${ADM_DESTDIR}/lib/ld-musl-${arch}.so.1"
  local libc_so="${ADM_DESTDIR}/lib/libc.so"

  local fail=0

  if [[ ! -r "${loader}" ]]; then
    _log "ERRO: não encontrei o loader dinâmico da musl: ${loader}"
    fail=1
  else
    _log "Loader musl encontrado: ${loader}"
  fi

  if [[ ! -r "${libc_so}" ]]; then
    _log "AVISO: libc.so não encontrado em ${ADM_DESTDIR}/lib (pode ser layout diferente, verifique se necessário)."
  else
    _log "libc.so encontrado: ${libc_so}"
  fi

  # Opcional: se for executável, podemos consultar a versão, mas sem depender disso.
  if [[ -x "${loader}" ]]; then
    _log "Tentando consultar versão do loader musl (opcional)"
    if "${loader}" 2>&1 | head -n 1 | grep -qi "musl libc"; then
      _log "Loader musl parece funcional (versão reportada)."
    else
      _log "AVISO: loader musl não reportou versão como esperado; verifique manualmente se necessário."
    fi
  fi

  if (( fail != 0 )); then
    _log "Sanity-check da musl-1.2.5 falhou (arquivos essenciais ausentes)."
    return 1
  fi

  _log "Sanity-check básico da musl-1.2.5 concluído com sucesso"

  # Log dentro do rootfs
  local logdir="${ADM_DESTDIR}/var/log"
  local logfile="${logdir}/adm-musl-1.2.5.log"

  mkdir -p "${logdir}"

  {
    printf 'musl-1.2.5 sanity-check\n'
    printf 'Profile : %s\n' "${ADM_PROFILE:-unknown}"
    printf 'Triplet : %s\n' "${ADM_TRIPLET}"
    printf 'Rootfs  : %s\n' "${ADM_ROOTFS}"
    printf 'Data    : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Loader  : %s\n' "${loader}"
    printf 'libc.so : %s\n' "${libc_so}"
  } > "${logfile}.tmp"

  mv -f "${logfile}.tmp" "${logfile}"

  # Marker para indicar que a musl-1.2.5 está instalada e verificada
  local marker="${ADM_DESTDIR}/.adm_musl_1_2_5_sane"
  echo "ok" > "${marker}"

  _log "Sanity-check da musl-1.2.5 registrado em ${logfile}"
  _log "Marker criado em ${marker}"
}
