#!/usr/bin/env bash
# Hook post_install para core/linux-headers
# Sanity-check da árvore de headers no rootfs do perfil.

set -euo pipefail

: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
: "${ADM_PROFILE:?ADM_PROFILE não definido}"

echo "[HOOK linux-headers/post_install] Iniciando sanity-check dos headers (perfil=${ADM_PROFILE})."

root_usr_include="${ADM_ROOTFS}/usr/include"

if [[ ! -d "${root_usr_include}" ]]; then
    echo "[HOOK linux-headers/post_install] ERRO: diretório ${root_usr_include} não existe." >&2
    exit 1
fi

declare -a required_headers=(
    "linux/version.h"
    "linux/limits.h"
    "linux/types.h"
)

# Nota: asm/unistd.h é dependente da arquitetura; tente checar se existir pasta asm
if [[ -d "${root_usr_include}/asm" ]]; then
    required_headers+=("asm/unistd.h")
fi

missing=0
for h in "${required_headers[@]}"; do
    if [[ ! -f "${root_usr_include}/${h}" ]]; then
        echo "[HOOK linux-headers/post_install] ERRO: header obrigatório ausente: ${root_usr_include}/${h}" >&2
        missing=1
    fi
done

if (( missing != 0 )); then
    echo "[HOOK linux-headers/post_install] ERRO: um ou mais headers obrigatórios não foram encontrados." >&2
    exit 1
fi

echo "[HOOK linux-headers/post_install] Headers do kernel parecem OK em ${root_usr_include}."
