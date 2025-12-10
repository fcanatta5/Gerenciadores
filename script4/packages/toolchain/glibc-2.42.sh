#!/usr/bin/env bash
# toolchain/glibc-2.42.sh
# Glibc-2.42 "final" para o sistema alvo, usando o toolchain /tools.
# Instala em ${ADM_DESTDIR} (rootfs do profile), NÃO em /tools.
# Compatível com o adm.sh corrigido.

set -euo pipefail

###############################################################################
# Metadados
###############################################################################

PKG_NAME="glibc-2.42"
PKG_CATEGORY="toolchain"
PKG_VERSION="2.42"

PKG_SOURCES=(
  "https://ftp.gnu.org/gnu/libc/glibc-2.42.tar.xz"
)

# Preencha se quiser validação rígida
PKG_SHA256S=(
  ""
)
PKG_MD5S=(
  ""
)

# Dependências lógicas dentro do adm
PKG_DEPENDS=(
  "toolchain/linux-api-headers"
  "toolchain/gcc-pass1"
  "toolchain/binutils-pass1"
)

###############################################################################
# Helpers internos
###############################################################################

_log() {
  printf '[%s] %s\n' "${PKG_NAME}" "$*" >&2
}

# Descobre a arquitetura para cuidar de lib/lib64 quando necessário
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
  _log "pre-uninstall: você está removendo a libc do profile ${ADM_PROFILE:-?}."
  _log "ATENÇÃO: isso pode quebrar praticamente todos os binários desse rootfs."
}

pkg_post_uninstall() {
  _log "post-uninstall: Glibc-2.42 removida do profile ${ADM_PROFILE:-?}."
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

  if [[ "${ADM_PROFILE}" != "glibc" ]]; then
    _log "ERRO: este pacote é apenas para perfil glibc (ADM_PROFILE=${ADM_PROFILE})."
    return 1
  fi

  _log "Iniciando build da Glibc ${PKG_VERSION} para o rootfs ${ADM_ROOTFS}"
  _log "Triplet de alvo : ${ADM_TRIPLET}"
  _log "Diretório de src: ${ADM_BUILD_DIR}"

  # CWD deve ser o diretório glibc-2.42
  cd "${ADM_BUILD_DIR}"

  # Se você tiver patches (FHS, etc.), o adm já os aplicou via apply_patches_for_pkg.
  # Aqui só garantimos que a árvore esteja "limpa".
  rm -rf build
  mkdir -pv build
  cd build

  local build
  build="$(../scripts/config.guess)"

  local sysroot="${ADM_DESTDIR}"
  local target="${ADM_TRIPLET}"

  _log "Configurando Glibc (host=${target}, build=${build}, sysroot=${sysroot})"

  # Configuração no estilo "cross para o rootfs", usando headers em /usr/include
  # de dentro do rootfs (toolchain/linux-api-headers).
  ../configure \
    --prefix=/usr \
    --host="${target}" \
    --build="${build}" \
    --with-headers="${sysroot}/usr/include" \
    --enable-kernel=4.19 \
    --enable-stack-protector=strong \
    --disable-werror

  _log "Compilando Glibc-2.42"
  make -j"$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)"

  _log "Build da Glibc-2.42 concluído"
}

###############################################################################
# Instalação
###############################################################################

pkg_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_BUILD_DIR:?ADM_BUILD_DIR não definido}"

  _log "Instalando Glibc-2.42 em ${ADM_DESTDIR}"

  cd "${ADM_BUILD_DIR}/build"

  # Instalação real no rootfs do profile via DESTDIR
  make DESTDIR="${ADM_DESTDIR}" install

  # Tratamento de lib/lib64 em x86_64, se necessário
  local arch
  arch="$(_detect_arch)"

  if [[ "${arch}" == "x86_64" ]]; then
    # Muitos setups querem /lib64 -> /lib no target. Ajuste conforme sua política.
    if [[ -d "${ADM_DESTDIR}/lib64" && ! -L "${ADM_DESTDIR}/lib64" ]]; then
      _log "AVISO: ${ADM_DESTDIR}/lib64 existe como diretório; não transformarei em symlink."
    elif [[ ! -e "${ADM_DESTDIR}/lib64" ]]; then
      _log "Criando symlink ${ADM_DESTDIR}/lib64 -> lib"
      ln -svf lib "${ADM_DESTDIR}/lib64"
    fi
  fi

  _log "Instalação da Glibc-2.42 concluída (arquivos gravados em ${ADM_DESTDIR})"
  # O adm chamará pkg_post_install automaticamente após pkg_install.
}

###############################################################################
# Sanity-check integrado (chamado pelo adm após pkg_install)
###############################################################################

pkg_post_install() {
  : "${ADM_DESTDIR:?ADM_DESTDIR não definido}"
  : "${ADM_TRIPLET:?ADM_TRIPLET não definido}"
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

  _log "Executando sanity-check não invasivo da Glibc-2.42"

  local tools_bin="${ADM_DESTDIR}/tools/bin"
  local gcc_cross="${tools_bin}/${ADM_TRIPLET}-gcc"

  if [[ ! -x "${gcc_cross}" ]]; then
    _log "AVISO: cross-GCC (${gcc_cross}) não encontrado; sanity-check será limitado."
  fi

  if ! command -v readelf >/dev/null 2>&1; then
    _log "AVISO: 'readelf' não encontrado no host; não será possível inspecionar o ELF."
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN

  local readelf_output=""
  local ok=0

  if [[ -x "${gcc_cross}" && "$(command -v readelf >/dev/null 2>&1; echo $?)" -eq 0 ]]; then
    _log "Sanity-check: compilando dummy.c com ${gcc_cross} para inspecionar o loader"

    pushd "${tmpdir}" >/dev/null

    cat > dummy.c <<'EOF'
int main(void) { return 0; }
EOF

    # Usa o sysroot do destino para garantir que pegue a glibc recém-instalada
    "${gcc_cross}" --sysroot="${ADM_DESTDIR}" dummy.c -o dummy

    if readelf_output="$(readelf -l dummy 2>/dev/null)"; then
      # Não checamos o path exato, só verificamos se há um PT_INTERP coerente.
      if grep -q 'Requesting program interpreter' <<< "${readelf_output}"; then
        ok=1
      fi
    fi

    popd >/dev/null
  fi

  if (( ok == 1 )); then
    _log "Sanity-check básico OK: o ELF gerado tem program interpreter definido (via glibc)."
  else
    _log "AVISO: não foi possível confirmar totalmente via readelf/gcc; confira manualmente se necessário."
  fi

  # Log dentro do rootfs
  local logdir="${ADM_DESTDIR}/var/log"
  local logfile="${logdir}/adm-glibc-2.42.log"

  mkdir -p "${logdir}"

  {
    printf 'Glibc-2.42 sanity-check\n'
    printf 'Profile : %s\n' "${ADM_PROFILE:-unknown}"
    printf 'Triplet : %s\n' "${ADM_TRIPLET}"
    printf 'Rootfs  : %s\n' "${ADM_ROOTFS}"
    printf 'Data    : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "${readelf_output}" ]]; then
      printf '\nreadelf -l dummy (trecho):\n\n'
      printf '%s\n' "${readelf_output}" | sed -n '1,40p'
    else
      printf '\n(readelf não executado ou sem saída)\n'
    fi
  } > "${logfile}.tmp"

  mv -f "${logfile}.tmp" "${logfile}"

  # Marker para outros componentes saberem que a Glibc foi instalada
  local marker="${ADM_DESTDIR}/.adm_glibc_2_42_sane"
  echo "ok" > "${marker}"

  _log "Sanity-check da Glibc-2.42 registrado em ${logfile}"
  _log "Marker criado em ${marker}"
}
