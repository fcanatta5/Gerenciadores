#!/usr/bin/env bash
# Hook post_install para Libstdc++ a partir do GCC 15.2.0 (Pass 1)
#
# Executado após a instalação em ROOTFS.
# Objetivos:
#   - Verificar se as libs libstdc++ foram instaladas em ROOTFS.
#   - Verificar presença de headers C++ em /usr/include/c++/${PKG_VERSION}.
#   - Emitir avisos básicos se algo suspeito for encontrado.

set -euo pipefail

PKG_EXPECTED_VERSION="15.2.0"

ROOTFS="${ADM_HOOK_ROOTFS:-${ADM_ROOTFS:-/opt/adm/rootfs}}"
ROOTFS="${ROOTFS%/}"

echo "[libstdc++-pass1/post_install] ROOTFS detectado: ${ROOTFS}"

LIB_DIR_1="${ROOTFS}/usr/lib"
LIB_DIR_2="${ROOTFS}/usr/lib64"
INC_BASE="${ROOTFS}/usr/include/c++"
INC_VER_DIR="${INC_BASE}/${PKG_EXPECTED_VERSION}"

echo "[libstdc++-pass1/post_install] Verificando bibliotecas em:"
echo "  - ${LIB_DIR_1}"
echo "  - ${LIB_DIR_2}"

libstd_candidates=()

if [[ -d "${LIB_DIR_1}" ]]; then
  while IFS= read -r -d '' f; do
    libstd_candidates+=("$f")
  done < <(find "${LIB_DIR_1}" -maxdepth 1 -name "libstdc++.so*" -type f -print0 || true)
fi

if [[ -d "${LIB_DIR_2}" ]]; then
  while IFS= read -r -d '' f; do
    libstd_candidates+=("$f")
  done < <(find "${LIB_DIR_2}" -maxdepth 1 -name "libstdc++.so*" -type f -print0 || true)
fi

if [[ "${#libstd_candidates[@]}" -eq 0 ]]; then
  echo "[libstdc++-pass1/post_install] ERRO: nenhum arquivo 'libstdc++.so*' encontrado em ${LIB_DIR_1} ou ${LIB_DIR_2}." >&2
  echo "[libstdc++-pass1/post_install]        A libstdc++ parece não ter sido instalada corretamente." >&2
  exit 1
fi

echo "[libstdc++-pass1/post_install] libstdc++ encontrada:"
for c in "${libstd_candidates[@]}"; do
  echo "  - ${c}"
done

###############################################################################
# Verificação dos headers C++
###############################################################################

echo "[libstdc++-pass1/post_install] Verificando headers C++ em: ${INC_VER_DIR}"

if [[ ! -d "${INC_BASE}" ]]; then
  echo "[libstdc++-pass1/post_install] ERRO: diretório base de C++ não existe: ${INC_BASE}" >&2
  exit 1
fi

if [[ ! -d "${INC_VER_DIR}" ]]; then
  echo "[libstdc++-pass1/post_install] ERRO: diretório de headers C++ para a versão esperada não existe: ${INC_VER_DIR}" >&2
  exit 1
fi

# Checagem de alguns headers básicos
headers_cpp=(
  "iostream"
  "vector"
  "string"
  "initializer_list"
)

missing_headers=0
for h in "${headers_cpp[@]}"; do
  if [[ ! -f "${INC_VER_DIR}/${h}" && ! -f "${INC_VER_DIR}/${h}.h" ]]; then
    echo "[libstdc++-pass1/post_install] AVISO: header C++ esperado não encontrado em ${INC_VER_DIR}: ${h}" >&2
    missing_headers=1
  fi
done

if [[ "${missing_headers}" -eq 0 ]]; then
  echo "[libstdc++-pass1/post_install] Headers C++ básicos encontrados em ${INC_VER_DIR}."
fi

echo "[libstdc++-pass1/post_install] Libstdc++ ${PKG_EXPECTED_VERSION} (Pass 1) parece instalada corretamente no ROOTFS."
exit 0
