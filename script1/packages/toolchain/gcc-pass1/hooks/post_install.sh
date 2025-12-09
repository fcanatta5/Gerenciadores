#!/usr/bin/env bash
# Hook post_install para GCC 15.2.0 - Pass 1
#
# Objetivos:
#   - Verificar se um GCC funcional foi instalado em /tools/bin.
#   - Fazer sanity-check básico via gcc --version.
#   - Avisar se nenhum compilador adequado for encontrado.

set -euo pipefail

PKG_EXPECTED_VERSION="15.2.0"

# ROOTFS passado pelo adm.sh (ou fallback)
ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

TOOLS_BIN="${ROOTFS}/tools/bin"

echo "[gcc-pass1/post_install] ROOTFS detectado: ${ROOTFS}"
echo "[gcc-pass1/post_install] Verificando GCC em: ${TOOLS_BIN}"

if [[ ! -d "${TOOLS_BIN}" ]]; then
  echo "[gcc-pass1/post_install] ERRO: diretório ${TOOLS_BIN} não existe." >&2
  exit 1
fi

# Procura por compiladores em /tools/bin
gcc_candidates=()
while IFS= read -r -d '' f; do
  gcc_candidates+=("$f")
done < <(find "${TOOLS_BIN}" -maxdepth 1 -type f \( -name "*-gcc" -o -name "gcc" \) -print0)

if [[ "${#gcc_candidates[@]}" -eq 0 ]]; then
  echo "[gcc-pass1/post_install] ERRO: nenhum 'gcc' ou '*-gcc' encontrado em ${TOOLS_BIN}." >&2
  exit 1
fi

echo "[gcc-pass1/post_install] Compiladores encontrados em /tools/bin:"
for c in "${gcc_candidates[@]}"; do
  echo "  - ${c}"
done

# Usa o primeiro candidato para sanity-check
GCC_BIN="${gcc_candidates[0]}"

echo "[gcc-pass1/post_install] Usando '${GCC_BIN}' para sanity-check."

# Garante que /tools/bin está na frente do PATH
export PATH="${TOOLS_BIN}:${PATH:-/usr/bin:/bin}"

gcc_version="$("${GCC_BIN}" --version | head -n1 || true)"

if [[ -z "${gcc_version}" ]]; then
  echo "[gcc-pass1/post_install] ERRO: não foi possível obter 'gcc --version' de ${GCC_BIN}." >&2
  exit 1
fi

echo "[gcc-pass1/post_install] gcc --version: ${gcc_version}"

if ! grep -q "${PKG_EXPECTED_VERSION}" <<<"${gcc_version}"; then
  echo "[gcc-pass1/post_install] AVISO: versão reportada não contém '${PKG_EXPECTED_VERSION}'." >&2
  echo "[gcc-pass1/post_install]         Verifique se o GCC correto (Pass 1) foi instalado." >&2
fi

echo "[gcc-pass1/post_install] Sanity-check básico do GCC Pass 1 concluído com sucesso."
exit 0
