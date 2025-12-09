#!/usr/bin/env bash
# Hook post_install para sanity-check do Binutils 2.45.1 - Pass 1

set -euo pipefail

PKG_EXPECTED_VERSION="2.45.1"

# Rootfs que o adm.sh passou para o hook:
#   - ADM_HOOK_ROOTFS: exportado pelo adm.sh na hora do run_hook
#   - ADM_ROOTFS: fallback, se o hook estiver sendo chamado manualmente
#   - /opt/adm/rootfs: default absoluto
ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

TOOLS_BIN="${ROOTFS}/tools/bin"

echo "[binutils-pass1/post_install] ROOTFS detectado: ${ROOTFS}"
echo "[binutils-pass1/post_install] Verificando binutils em: ${TOOLS_BIN}"

# Verifica se /tools/bin existe e contém os binários básicos
if [[ ! -d "${TOOLS_BIN}" ]]; then
  echo "[binutils-pass1/post_install] ERRO: diretório ${TOOLS_BIN} não existe." >&2
  exit 1
fi

if [[ ! -x "${TOOLS_BIN}/ld" ]]; then
  echo "[binutils-pass1/post_install] ERRO: '${TOOLS_BIN}/ld' não encontrado ou não executável." >&2
  exit 1
fi

if [[ ! -x "${TOOLS_BIN}/as" ]]; then
  echo "[binutils-pass1/post_install] ERRO: '${TOOLS_BIN}/as' não encontrado ou não executável." >&2
  exit 1
fi

# Lê as versões reportadas por ld e as
ld_version="$("${TOOLS_BIN}/ld" --version | head -n1 || true)"
as_version="$("${TOOLS_BIN}/as" --version | head -n1 || true)"

if [[ -z "${ld_version}" || -z "${as_version}" ]]; then
  echo "[binutils-pass1/post_install] ERRO: não foi possível obter versão de ld/as em ${TOOLS_BIN}." >&2
  exit 1
fi

echo "[binutils-pass1/post_install] ld --version: ${ld_version}"
echo "[binutils-pass1/post_install] as --version: ${as_version}"

# Confere se a versão do ld bate com o esperado (aviso, não fatal)
if ! grep -q "${PKG_EXPECTED_VERSION}" <<<"${ld_version}"; then
  echo "[binutils-pass1/post_install] AVISO: versão de ld não contém '${PKG_EXPECTED_VERSION}'." >&2
  echo "[binutils-pass1/post_install]         Verifique se está usando o binutils correto para o Pass 1." >&2
fi

# Monta um PATH de teste com /tools/bin na frente
PATH_TEST="${TOOLS_BIN}:${PATH:-/usr/bin:/bin}"
export PATH="${PATH_TEST}"

which_ld="$(command -v ld || true)"
if [[ -z "${which_ld}" ]]; then
  echo "[binutils-pass1/post_install] ERRO: 'ld' não encontrado no PATH de teste (${PATH_TEST})." >&2
  exit 1
fi

echo "[binutils-pass1/post_install] 'ld' resolvido para: ${which_ld}"

# Se quiser endurecer, pode exigir que seja exatamente TOOLS_BIN/ld:
if [[ "${which_ld}" != "${TOOLS_BIN}/ld" ]]; then
  echo "[binutils-pass1/post_install] AVISO: 'ld' no PATH não é o de ${TOOLS_BIN}." >&2
  echo "[binutils-pass1/post_install]         Isso pode indicar que /tools/bin não está na frente do PATH." >&2
fi

echo "[binutils-pass1/post_install] OK: Binutils Pass 1 ${PKG_EXPECTED_VERSION} em /tools parece funcional."
exit 0
