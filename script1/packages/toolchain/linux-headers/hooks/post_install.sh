#!/usr/bin/env bash
# Hook post_install para Linux-6.17.9 API Headers

set -euo pipefail

PKG_EXPECTED_VERSION="6.17.9"

ROOTFS="${ADM_HOOK_ROOTFS:-/}"
ROOTFS="${ROOTFS%/}"

INCLUDE_DIR="${ROOTFS}/usr/include"
LINUX_DIR="${INCLUDE_DIR}/linux"
ASM_DIR="${INCLUDE_DIR}/asm"
ASM_GENERIC_DIR="${INCLUDE_DIR}/asm-generic"

echo "[linux-headers/post_install] Sanity-check dos Linux API Headers (${PKG_EXPECTED_VERSION})..."

# 1) Verifica diretórios básicos
if [[ ! -d "${INCLUDE_DIR}" ]]; then
  echo "[linux-headers/post_install] ERRO: diretório ${INCLUDE_DIR} não existe." >&2
  exit 1
fi

if [[ ! -d "${LINUX_DIR}" ]]; then
  echo "[linux-headers/post_install] ERRO: diretório ${LINUX_DIR} não existe." >&2
  exit 1
fi

if [[ ! -d "${ASM_DIR}" && ! -d "${ASM_GENERIC_DIR}" ]]; then
  echo "[linux-headers/post_install] ERRO: nem ${ASM_DIR} nem ${ASM_GENERIC_DIR} existem." >&2
  echo "[linux-headers/post_install]        headers de asm não foram instalados corretamente." >&2
  exit 1
fi

echo "[linux-headers/post_install] Encontrado /usr/include/linux e asm/asm-generic OK."

# 2) Verifica alguns headers críticos
critical_headers=(
  "linux/limits.h"
  "linux/errno.h"
  "linux/ioctl.h"
  "linux/types.h"
)

for h in "${critical_headers[@]}"; do
  if [[ ! -f "${INCLUDE_DIR}/${h}" ]]; then
    echo "[linux-headers/post_install] ERRO: header crítico ausente: ${INCLUDE_DIR}/${h}" >&2
    exit 1
  fi
done

echo "[linux-headers/post_install] Headers críticos presentes."

# 3) Tenta extrair versão dos headers
#    Dependendo da versão do kernel, a info pode estar em:
#    - include/linux/version.h
#    - include/generated/uapi/linux/version.h
#    - ou macros UTS_RELEASE em headers relacionados.
version_files=(
  "${INCLUDE_DIR}/linux/version.h"
  "${INCLUDE_DIR}/generated/uapi/linux/version.h"
)

header_version=""
for vf in "${version_files[@]}"; do
  if [[ -f "${vf}" ]]; then
    # Procura algo tipo 6.17.9
    if grep -Eq '6\.17\.9' "${vf}"; then
      header_version="${PKG_EXPECTED_VERSION}"
      break
    fi
    # Como fallback, tenta extrair qualquer coisa parecida com X.Y.Z
    candidate="$(grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' "${vf}" | head -n1 || true)"
    if [[ -n "${candidate}" ]]; then
      header_version="${candidate}"
      break
    fi
  fi
done

if [[ -z "${header_version}" ]]; then
  echo "[linux-headers/post_install] AVISO: não consegui determinar a versão exata dos headers."
  echo "[linux-headers/post_install]         Verifique manualmente algum arquivo em ${LINUX_DIR}."
else
  echo "[linux-headers/post_install] Versão detectada dos headers: ${header_version}"
  if [[ "${header_version}" != "${PKG_EXPECTED_VERSION}" ]]; then
    echo "[linux-headers/post_install] AVISO: versão dos headers (${header_version}) difere da esperada (${PKG_EXPECTED_VERSION})." >&2
    # Não dou exit 1 aqui porque alguns arranjos podem ter número um pouco diferente
    # (por exemplo, se você aplicar patch manualmente).
  fi
fi

echo "[linux-headers/post_install] OK: Linux API Headers parecem instalados corretamente em ${ROOTFS}/usr/include."
exit 0
