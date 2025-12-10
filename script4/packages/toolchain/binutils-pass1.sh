#!/usr/bin/env bash
# toolchain/binutils-pass1.sh
# Binutils-2.45.1 - Pass 1
# Cross-binutils temporário instalado em /tools dentro do rootfs do profile
# Compatível com o gerenciador "adm" que chama pkg_build/pkg_install/pkg_*_uninstall.

set -euo pipefail

###############################################################################
# Metadados
###############################################################################

PKG_NAME="binutils-pass1"
PKG_CATEGORY="toolchain"
PKG_VERSION="2.45.1"

# Fonte oficial do LFS (development 12.4) 
PKG_SOURCES=(
  "https://sourceware.org/pub/binutils/releases/binutils-2.45.1.tar.xz"
)

# MD5 conforme LFS 12.4 (desenvolvimento) 
PKG_SHA256S=(
  ""
)
PKG_MD5S=(
  "ff59f8dc1431edfa54a257851bea74e7"
)

# Dependências lógicas dentro do teu sistema de pacotes (ajuste se quiser)
PKG_DEPENDS=(
  # aqui poderiam entrar coisas como "host/m4", "host/gcc" etc,
  # mas como são dependências de HOST, muita gente não modela isso como pacote.
)

###############################################################################
# Helpers internos
###############################################################################

_log() {
  printf '[%s] %s\n' "${PKG_NAME}" "$*" >&2
}

# O adm garante que quando pkg_build/pkg_install são chamados:
#   - CWD = diretório de fontes (srcdir)
#   - ADM_PROFILE, ADM_ROOTFS, ADM_TRIPLET, ADM_DESTDIR já estão exportadas.

###############################################################################
# Hooks de uninstall integrados no script
###############################################################################

pkg_pre_uninstall() {
  _log "pre-uninstall: preparando remoção do Binutils Pass 1 de /tools (perfil: ${ADM_PROFILE:-?})"
  # Aqui você pode adicionar logicazinha extra se quiser (backup de algo, etc).
}

pkg_post_uninstall() {
  _log "post-uninstall: Binutils Pass 1 removido (perfil: ${ADM_PROFILE:-?})"
  # Remoção extra de órfãos específicos poderia ser tratada aqui se necessário.
}

###############################################################################
# Build
###############################################################################

pkg_build() {
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"

  _log "Iniciando build de Binutils ${PKG_VERSION} (Pass 1) para alvo ${ADM_TRIPLET}"
  _log "Rootfs do perfil: ${ADM_ROOTFS}"

  # CWD aqui já é o diretório de fontes (por ex. .../binutils-2.45.1)
  local srcdir
  srcdir="$(pwd)"

  # Diretório de build separado, como recomendado pela própria Binutils e pelo LFS 
  rm -rf build
  mkdir -pv build
  cd build

  local sysroot="${ADM_ROOTFS}"
  local target="${ADM_TRIPLET}"

  _log "Configurando Binutils (Pass 1):"
  _log "  prefix  = /tools (via DESTDIR=${ADM_DESTDIR})"
  _log "  sysroot = ${sysroot}"
  _log "  target  = ${target}"

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

  _log "Build de Binutils (Pass 1) concluído"
}

###############################################################################
# Instalação + sanity-check integrado
###############################################################################

pkg_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

  _log "Instalando Binutils ${PKG_VERSION} (Pass 1) em ${ADM_DESTDIR}/tools"

  # CWD aqui volta a ser o srcdir; precisamos ir para build
  cd build

  # Instalação do cross-binutils em /tools dentro do rootfs do profile
  make DESTDIR="${ADM_DESTDIR}" install

  _log "Instalação base concluída; executando sanity-check integrado"

  pkg_post_install
}

# sanity-check integrado; chamado explicitamente no final de pkg_install
pkg_post_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

  local tools_root="${ADM_DESTDIR}/tools"
  local tools_bin="${tools_root}/bin"
  local ld_cross="${tools_bin}/${ADM_TRIPLET}-ld"
  local as_cross="${tools_bin}/${ADM_TRIPLET}-as"
  local gcc_cross="${tools_bin}/${ADM_TRIPLET}-gcc"   # pode ou não existir nesse momento

  # 1) Teste mínimo: o ld/as cruzados existem e executam
  if [[ ! -x "${ld_cross}" ]]; then
    _log "ERRO: não encontrei o linker cruzado: ${ld_cross}"
    return 1
  fi
  if [[ ! -x "${as_cross}" ]]; then
    _log "ERRO: não encontrei o assembler cruzado: ${as_cross}"
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

  _log "Sanity mínimo de Binutils Pass 1 OK (ld/as em /tools)"

  # 2) Sanity-check “estendido” estilo LFS usando gcc+readelf, SE já houver gcc cross
  if [[ -x "${gcc_cross}" ]]; then
    if ! command -v readelf >/dev/null 2>&1; then
      _log "Aviso: 'readelf' do host não encontrado; pulando sanity-check ELF estendido."
    else
      _log "Encontrado ${gcc_cross}; rodando sanity-check de ELF com dummy.c"

      local old_path="${PATH}"
      PATH="${tools_bin}:${PATH}"

      local tmpdir
      tmpdir="$(mktemp -d)"
      trap 'rm -rf "${tmpdir}"' RETURN

      pushd "${tmpdir}" >/dev/null

      cat > dummy.c <<'EOF'
int main(void) { return 0; }
EOF

      "${gcc_cross}" dummy.c -o dummy

      local ro
      if ! ro="$(readelf -l dummy 2>/dev/null)"; then
        _log "ERRO: readelf falhou ao analisar o executável 'dummy'"
        PATH="${old_path}"
        return 1
      fi

      if ! grep -q ': /tools' <<< "${ro}"; then
        _log "ERRO: o interpreter/loader do ELF não aponta para /tools."
        _log "Saída de readelf (trecho):"
        printf '%s\n' "${ro}" | sed -n '1,80p' >&2
        PATH="${old_path}"
        return 1
      fi

      _log "Sanity-check estendido OK: interpreter do ELF aponta para /tools"

      # registra log simples dentro do rootfs
      local logdir="${ADM_DESTDIR}/var/log"
      local logfile="${logdir}/adm-binutils-pass1-sanity.log"
      mkdir -p "${logdir}"
      {
        printf 'Binutils Pass 1 sanity-check\n'
        printf 'Profile : %s\n' "${ADM_PROFILE:-unknown}"
        printf 'Triplet : %s\n' "${ADM_TRIPLET}"
        printf 'Rootfs  : %s\n' "${ADM_ROOTFS}"
        printf 'Data    : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '\nreadelf -l dummy:\n\n'
        printf '%s\n' "${ro}"
      } > "${logfile}.tmp"
      mv -f "${logfile}.tmp" "${logfile}"

      local marker="${tools_root}/.adm_binutils_pass1_sane"
      echo "ok" > "${marker}"

      _log "Sanity-check de Binutils Pass 1 registrado em ${logfile}"
      _log "Marker criado em ${marker}"

      PATH="${old_path}"
      popd >/dev/null
    fi
  else
    _log "gcc cross (${gcc_cross}) ainda não existe; sanity-check restrito a ld/as."
  fi

  _log "Sanity-check integrado do Binutils Pass 1 finalizado com sucesso"
}
