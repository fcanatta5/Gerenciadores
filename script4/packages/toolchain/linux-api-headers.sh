#!/usr/bin/env bash
# toolchain/linux-api-headers.sh
# Linux-6.17.9 API Headers para o gerenciador adm
# Instala os headers em ${ADM_DESTDIR}/usr/include dentro do rootfs do profile.

set -euo pipefail

###############################################################################
# Metadados
###############################################################################

PKG_NAME="linux-api-headers"
PKG_CATEGORY="toolchain"
PKG_VERSION="6.17.9"

# Tarball oficial do kernel (ajuste se preferir outro espelho)
PKG_SOURCES=(
  "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.17.9.tar.xz"
)

# Checksums (deixe em branco se quiser validar por conta própria)
PKG_SHA256S=(
  ""
)
PKG_MD5S=(
  ""
)

# Dependências lógicas no seu sistema de pacotes (se quiser forçar ordem)
PKG_DEPENDS=(
  # ex: "toolchain/binutils-pass1" "toolchain/gcc-pass1"
)

###############################################################################
# Helpers internos
###############################################################################

_log() {
  printf '[%s] %s\n' "${PKG_NAME}" "$*" >&2
}

# Descobre ARCH a partir do triplet ou do host
_detect_arch() {
  local triplet="${ADM_TRIPLET:-}"
  if [[ "${triplet}" == x86_64-* ]]; then
    echo "x86_64"
  elif [[ "${triplet}" == aarch64-* ]]; then
    echo "arm64"
  elif [[ "${triplet}" == i?86-* ]]; then
    echo "i386"
  else
    # fallback para a arch do host (não ideal, mas funciona na maioria dos casos)
    uname -m
  fi
}

###############################################################################
# Hooks de uninstall integrados
###############################################################################

pkg_pre_uninstall() {
  _log "pre-uninstall: removendo Linux API Headers de ${ADM_ROOTFS:-<desconhecido>}"
  _log "ATENÇÃO: outros pacotes podem depender de /usr/include/linux e /usr/include/asm."
}

pkg_post_uninstall() {
  _log "post-uninstall: Linux API Headers removidos (perfil: ${ADM_PROFILE:-?})"
}

###############################################################################
# Build
###############################################################################

pkg_build() {
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_BUILD_DIR:?ADM_BUILD_DIR não definido}"

  _log "Iniciando preparação dos Linux API Headers ${PKG_VERSION}"
  _log "Rootfs do perfil: ${ADM_ROOTFS}"
  _log "Diretório de build: ${ADM_BUILD_DIR}"

  # CWD aqui é ${ADM_BUILD_DIR}, que deve ser o diretório linux-6.17.9
  cd "${ADM_BUILD_DIR}"

  # Limpa árvore (como no LFS: make mrproper)
  _log "Executando 'make mrproper'"
  make mrproper

  # Descobre ARCH
  local arch
  arch="$(_detect_arch)"
  _log "Usando ARCH=${arch} para geração dos headers"

  # Gera apenas os headers exportáveis (make headers)
  _log "Executando 'make ARCH=${arch} headers'"
  make ARCH="${arch}" headers

  # Remove arquivos que não são .h dentro de usr/include
  # (evita scripts/artifacts estranhos)
  _log "Limpando arquivos não-header em usr/include"
  find usr/include -type f ! -name '*.h' -delete

  _log "Build dos Linux API Headers concluído (fase de geração)"
}

###############################################################################
# Instalação + sanity-check
###############################################################################

pkg_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

  local target_usr="${ADM_DESTDIR}/usr"
  local target_inc="${target_usr}/include"

  _log "Instalando Linux API Headers em ${target_inc}"

  cd "${ADM_BUILD_DIR}"

  # Se já existe /usr/include no rootfs, avisamos e sobrescrevemos
  if [[ -d "${target_inc}" ]]; then
    _log "AVISO: ${target_inc} já existe; será substituído pelos Linux API Headers."
    _log "Se precisar, faça backup antes de continuar."
  fi

  # Remove árvore antiga de includes do rootfs e recria
  rm -rf "${target_inc}"
  mkdir -p "${target_usr}"

  # Copia usr/include gerado pelo make headers para o rootfs
  cp -rv usr/include "${target_usr}"

  _log "Instalação dos Linux API Headers concluída em ${target_inc}"

  # Sanity-check simples integrado
  pkg_post_install
}

pkg_post_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

  local target_inc="${ADM_DESTDIR}/usr/include"
  local hdr1="${target_inc}/linux/limits.h"
  local hdr2="${target_inc}/asm/unistd.h"

  _log "Executando sanity-check dos Linux API Headers em ${target_inc}"

  local fail=0

  if [[ ! -r "${hdr1}" ]]; then
    _log "ERRO: header esperado não encontrado: ${hdr1}"
    fail=1
  fi

  if [[ ! -r "${hdr2}" ]]; then
    _log "AVISO: header esperado não encontrado: ${hdr2} (nem todas as archs usam exatamente esse nome)"
  fi

  if (( fail != 0 )); then
    _log "Sanity-check falhou: alguns headers essenciais não foram encontrados."
    return 1
  fi

  _log "Sanity-check básico OK: headers principais encontrados."

  # Grava um log dentro do rootfs
  local logdir="${ADM_DESTDIR}/var/log"
  local logfile="${logdir}/adm-linux-api-headers.log"

  mkdir -p "${logdir}"

  {
    printf 'Linux API Headers instalados\n'
    printf 'Kernel  : %s\n' "${PKG_VERSION}"
    printf 'Profile : %s\n' "${ADM_PROFILE:-unknown}"
    printf 'Rootfs  : %s\n' "${ADM_ROOTFS}"
    printf 'Data    : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Path    : %s\n' "${target_inc}"
  } > "${logfile}.tmp"

  mv -f "${logfile}.tmp" "${logfile}"

  # Marker para outros pacotes/tooling saberem que os headers já foram instalados
  local marker="${ADM_DESTDIR}/usr/include/.adm_linux_api_headers_${PKG_VERSION}"
  echo "ok" > "${marker}"

  _log "Sanity-check registrado em ${logfile}"
  _log "Marker criado em ${marker}"
}
