#!/usr/bin/env bash
# Hook pre_build para Binutils 2.45.1 - Pass 1
#
# Executado após o fetch/extract e antes de configure/build.
# Objetivos:
#   - Garantir que a hierarquia /tools exista dentro do ROOTFS.
#   - Reconstruir o diretório de build exatamente como o adm.sh faz.
#   - Fazer sanity-check do diretório de build e da presença de ./configure.
#   - Em caso de ADM_FORCE_REBUILD=1, limpar artefatos antigos de configuração
#     (config.cache, config.log, config.status, Makefile de topo).
#   - Emitir avisos úteis (PATH, binutils velhos em /tools/bin, etc.).

set -euo pipefail

###############################################################################
# Descoberta de ROOTFS / BUILD_ROOT / BUILD_DIR
###############################################################################

# ROOTFS que o adm.sh passou para o hook:
#   - ADM_HOOK_ROOTFS: exportado pelo adm.sh ao chamar run_hook
#   - ADM_ROOTFS: fallback, se o hook for chamado em outro contexto
#   - /opt/adm/rootfs: default absoluto de segurança
ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[binutils-pass1/pre_build] ROOTFS detectado: ${ROOTFS}"

# A partir do ROOTFS (tipicamente algo como /opt/adm/rootfs-glibc),
# reconstruímos o BUILD_ROOT no mesmo modelo do adm.sh:
#   ADM_ROOTFS="${ADM_ROOTFS:-${ADM_ROOT}/rootfs${suffix}}"
#   ADM_BUILD_ROOT="${ADM_BUILD_ROOT:-${ADM_ROOT}/build${suffix}}"
#
# Então:
#   - base = diretório pai do ROOTFS (ex.: /opt/adm)
#   - last = nome do último componente (ex.: rootfs-glibc)
#   - suffix = parte depois de "rootfs" (ex.: "-glibc")
#   - BUILD_ROOT = "${base}/build${suffix}" (ex.: /opt/adm/build-glibc)
last="${ROOTFS##*/}"
suffix=""
if [[ "${last}" == rootfs* ]]; then
  suffix="${last#rootfs}"
fi
adm_base="${ROOTFS%/*}"
BUILD_ROOT="${adm_base}/build${suffix}"

# Nome lógico completo do pacote recebido do adm.sh (ex.: toolchain/binutils-pass1)
PKG_FULL="${ADM_HOOK_PKG:-binutils-pass1}"

# O adm.sh define:
#   pkg_build_dir() { echo "${ADM_BUILD_ROOT}/build/${full}"; }
# Portanto, o build_dir real do pacote é:
BUILD_DIR="${BUILD_ROOT}/build/${PKG_FULL}"

echo "[binutils-pass1/pre_build] BUILD_ROOT reconstruído: ${BUILD_ROOT}"
echo "[binutils-pass1/pre_build] Diretório de build do pacote: ${BUILD_DIR}"

###############################################################################
# Garantia de /tools dentro do ROOTFS
###############################################################################

TOOLS_DIR="${ROOTFS}/tools"
TOOLS_BIN="${TOOLS_DIR}/bin"

echo "[binutils-pass1/pre_build] Diretório /tools em ROOTFS: ${TOOLS_DIR}"

if [[ ! -d "${TOOLS_DIR}" ]]; then
  echo "[binutils-pass1/pre_build] /tools não encontrado em ${ROOTFS}. Criando diretório..."
  mkdir -p "${TOOLS_DIR}"
fi

if [[ ! -d "${TOOLS_BIN}" ]]; then
  echo "[binutils-pass1/pre_build] /tools/bin não encontrado em ${ROOTFS}. Criando diretório..."
  mkdir -p "${TOOLS_BIN}"
fi

###############################################################################
# Sanity-check do diretório de build
###############################################################################

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "[binutils-pass1/pre_build] ERRO: diretório de build ${BUILD_DIR} não existe." >&2
  echo "[binutils-pass1/pre_build]        Isso sugere problema na fase de extract do adm.sh." >&2
  exit 1
fi

# Binutils oficial sempre fornece um ./configure na raiz do source.
if [[ ! -f "${BUILD_DIR}/configure" ]]; then
  echo "[binutils-pass1/pre_build] ERRO: 'configure' não encontrado em ${BUILD_DIR}." >&2
  echo "[binutils-pass1/pre_build]        Verifique a extração do tarball e o layout do pacote." >&2
  exit 1
fi

###############################################################################
# Limpeza agressiva em caso de ADM_FORCE_REBUILD=1
###############################################################################

FORCE_REBUILD="${ADM_FORCE_REBUILD:-0}"

if [[ "${FORCE_REBUILD}" = "1" ]]; then
  echo "[binutils-pass1/pre_build] ADM_FORCE_REBUILD=1 -> limpando artefatos antigos em ${BUILD_DIR}"

  # Remove artefatos típicos de configure/autotools da raiz do build_dir.
  for f in config.cache config.log config.status; do
    if [[ -f "${BUILD_DIR}/${f}" ]]; then
      echo "[binutils-pass1/pre_build] Removendo ${BUILD_DIR}/${f}"
      rm -f "${BUILD_DIR}/${f}"
    fi
  done

  # Remove Makefile apenas no topo do BUILD_DIR (não desce em subdiretórios).
  if [[ -f "${BUILD_DIR}/Makefile" ]]; then
    echo "[binutils-pass1/pre_build] Removendo Makefile de topo em ${BUILD_DIR}/Makefile"
    rm -f "${BUILD_DIR}/Makefile"
  fi

  # Opcional: se houver um subdiretório 'build' típico de out-of-tree,
  # você pode querer limpá-lo. Aqui só avisamos:
  if [[ -d "${BUILD_DIR}/build" ]]; then
    echo "[binutils-pass1/pre_build] AVISO: subdiretório '${BUILD_DIR}/build' detectado."
    echo "[binutils-pass1/pre_build]         Se esse for um build out-of-tree antigo, "
    echo "[binutils-pass1/pre_build]         considere limpá-lo manualmente se necessário."
  fi
fi

###############################################################################
# Informações de ambiente e avisos úteis
###############################################################################

PROFILE="${ADM_PROFILE:-default}"
TRIPLET="${TARGET_TRIPLET:-native}"

echo "[binutils-pass1/pre_build] Perfil ADM (ADM_PROFILE): ${PROFILE}"
echo "[binutils-pass1/pre_build] TARGET_TRIPLET (se definido): ${TRIPLET}"

# Aviso se já houver ld/as em /tools/bin (pode ser rebuild)
if compgen -G "${TOOLS_BIN}/ld*" >/dev/null 2>&1 || compgen -G "${TOOLS_BIN}/as*" >/dev/null 2>&1; then
  echo "[binutils-pass1/pre_build] AVISO: já existem arquivos ld/as em ${TOOLS_BIN}."
  echo "[binutils-pass1/pre_build]         Para rebuild do Pass 1, verifique se isso é esperado."
fi

CURRENT_PATH="${PATH:-/usr/bin:/bin}"
echo "[binutils-pass1/pre_build] PATH atual no contexto do hook:"
echo "  ${CURRENT_PATH}"

if ! grep -q "/tools/bin" <<<"${CURRENT_PATH}"; then
  echo "[binutils-pass1/pre_build] AVISO: '/tools/bin' não aparece no PATH atual."
  echo "[binutils-pass1/pre_build]         No contexto do adm.sh isso pode ser ok, "
  echo "[binutils-pass1/pre_build]         mas para usar o toolchain em /tools interativamente,"
  echo "[binutils-pass1/pre_build]         você provavelmente vai querer adicioná-lo ao PATH."
fi

echo "[binutils-pass1/pre_build] Sanity-check agressivo concluído. Ambiente para build do Binutils Pass 1 preparado."
exit 0
