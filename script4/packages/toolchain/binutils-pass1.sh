#!/usr/bin/env bash
# toolchain/binutils-pass1.sh
# Binutils-2.45.1 - Pass 1
# Cross-binutils temporário instalado em /tools dentro do rootfs do perfil.
# Compatível com o gerenciador "adm" (adm.sh corrigido).

set -euo pipefail

###############################################################################
# Metadados
###############################################################################

PKG_NAME="binutils-pass1"
PKG_CATEGORY="toolchain"
PKG_VERSION="2.45.1"

# Fonte (ajuste se usar mirror próprio)
PKG_SOURCES=(
  "https://sourceware.org/pub/binutils/releases/binutils-2.45.1.tar.xz"
)

# Esses valores podem ser ajustados para o tarball real se quiser validar.
PKG_SHA256S=(
  ""
)
PKG_MD5S=(
  "ff59f8dc1431edfa54a257851bea74e7"
)

# Dependências lógicas (dentro do adm). Não obrigatórias, mas ajudam na ordem.
PKG_DEPENDS=(
  # ex: "host/m4" "host/flex"
)

###############################################################################
# Helpers internos
###############################################################################

_log() {
  printf '[%s] %s\n' "${PKG_NAME}" "$*" >&2
}

###############################################################################
# Hooks de uninstall integrados
###############################################################################

pkg_pre_uninstall() {
  _log "pre-uninstall: preparando remoção do Binutils Pass 1 de /tools (perfil: ${ADM_PROFILE:-?})"
  _log "ATENÇÃO: outros componentes do toolchain podem depender desse cross-binutils."
}

pkg_post_uninstall() {
  _log "post-uninstall: Binutils Pass 1 removido (perfil: ${ADM_PROFILE:-?})"
}

###############################################################################
# Build
###############################################################################

pkg_build() {
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_BUILD_DIR:?ADM_BUILD_DIR não definido}"

  _log "Iniciando build de Binutils ${PKG_VERSION} (Pass 1)"
  _log "Rootfs do perfil : ${ADM_ROOTFS}"
  _log "Triplet de alvo  : ${ADM_TRIPLET}"
  _log "Diretório de src : ${ADM_BUILD_DIR}"

  # CWD inicial aqui é ${ADM_BUILD_DIR}, que deve ser o diretório binutils-2.45.1
  cd "${ADM_BUILD_DIR}"

  # Diretório de build separado é recomendado pela documentação do Binutils/LFS
  rm -rf build
  mkdir -pv build
  cd build

  local sysroot="${ADM_ROOTFS}"
  local target="${ADM_TRIPLET}"

  _log "Configurando Binutils (Pass 1):"
  _log "  --prefix=/tools       (instala em ${ADM_DESTDIR}/tools via DESTDIR)"
  _log "  --with-sysroot=${sysroot}"
  _log "  --target=${target}"

  ../configure \
    --prefix=/tools \
    --with-sysroot="${sysroot}" \
    --target="${target}" \
    --disable-nls \
    --enable-gprofng=no \
    --disable-werror \
    --enable-new-dtags \
    --enable-default-hash-style=gnu

  _log "Compilando Binutils (Pass 1)"
  make -j"$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)"

  _log "Build de Binutils (Pass 1) concluído com sucesso"
}

###############################################################################
# Instalação
###############################################################################

pkg_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
  : "${ADM_BUILD_DIR:?ADM_BUILD_DIR não definido}"

  _log "Instalando Binutils ${PKG_VERSION} (Pass 1) em ${ADM_DESTDIR}/tools"

  cd "${ADM_BUILD_DIR}/build"

  # Instala em /tools dentro do rootfs (ADM_DESTDIR) — não toca no / do host
  make DESTDIR="${ADM_DESTDIR}" install

  _log "Instalação base de Binutils (Pass 1) concluída"
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
  local ld_cross="${tools_bin}/${ADM_TRIPLET}-ld"
  local as_cross="${tools_bin}/${ADM_TRIPLET}-as"

  _log "Executando sanity-check do Binutils Pass 1 em ${tools_bin}"

  local fail=0

  if [[ ! -x "${ld_cross}" ]]; then
    _log "ERRO: não encontrei o linker cruzado: ${ld_cross}"
    fail=1
  fi

  if [[ ! -x "${as_cross}" ]]; then
    _log "ERRO: não encontrei o assembler cruzado: ${as_cross}"
    fail=1
  fi

  if (( fail != 0 )); then
    _log "Sanity-check falhou: ld/as cruzados não estão disponíveis em /tools."
    return 1
  fi

  _log "Verificando ${ld_cross} --version"
  "${ld_cross}" --version >/dev/null 2>&1 || {
    _log "ERRO: ${ld_cross} não executa corretamente"
    return 1
  }

  _log "Verificando ${as_cross} --version"
  "${as_cross}" --version >/dev/null 2>&1 || {
    _log "ERRO: ${as_cross} não executa corretamente"
    return 1
  }

  _log "Sanity mínimo OK: ld/as cross em /tools estão funcionais."

  # Log em var/log dentro do rootfs
  local logdir="${ADM_DESTDIR}/var/log"
  local logfile="${logdir}/adm-binutils-pass1.log"

  mkdir -p "${logdir}"

  {
    printf 'Binutils Pass 1 sanity-check\n'
    printf 'Versão  : %s\n' "${PKG_VERSION}"
    printf 'Profile : %s\n' "${ADM_PROFILE:-unknown}"
    printf 'Triplet : %s\n' "${ADM_TRIPLET}"
    printf 'Rootfs  : %s\n' "${ADM_ROOTFS}"
    printf 'Data    : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${logfile}.tmp"

  mv -f "${logfile}.tmp" "${logfile}"

  # Marker para outros componentes saberem que o Binutils Pass 1 está ok
  local marker="${tools_root}/.adm_binutils_pass1_sane"
  echo "ok" > "${marker}"

  _log "Sanity-check registrado em ${logfile}"
  _log "Marker criado em ${marker}"
}
