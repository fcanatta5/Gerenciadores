#!/usr/bin/env bash
# Hook pre_build para toolchain/gcc-pass1
# Garante que o binutils cross do Pass 1 existe antes de tentar compilar o GCC.

set -euo pipefail

: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
: "${ADM_PROFILE:?ADM_PROFILE não definido}"

echo "[HOOK gcc-pass1/pre_build] Verificando pré-requisitos (perfil=${ADM_PROFILE})"

# Mesmo esquema de target do build.sh
local_libc=""
case "${ADM_PROFILE}" in
    musl) local_libc="musl" ;;
    *)    local_libc="gnu"  ;;
esac

target="${ADM_TARGET:-x86_64-adm-linux-${local_libc}}"

tools_prefix="${ADM_ROOTFS}/tools"
tools_bindir="${tools_prefix}/bin"

if [[ ! -d "${tools_bindir}" ]]; then
    echo "[HOOK gcc-pass1/pre_build] ERRO: diretório ${tools_bindir} não existe. Binutils Pass 1 não instalado?" >&2
    exit 1
fi

need_bins=(
    "${target}-as"
    "${target}-ld"
    "${target}-ar"
)

for b in "${need_bins[@]}"; do
    if [[ ! -x "${tools_bindir}/${b}" ]]; then
        echo "[HOOK gcc-pass1/pre_build] ERRO: binário obrigatório não encontrado: ${tools_bindir}/${b}" >&2
        exit 1
    fi
done

echo "[HOOK gcc-pass1/pre_build] Binutils Pass 1 OK para target=${target}"
