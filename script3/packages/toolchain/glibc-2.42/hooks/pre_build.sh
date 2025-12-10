#!/usr/bin/env bash
# Hook pre_build para toolchain/Glibc-2.42
# Verifica se o toolchain cross e os linux headers existem antes de construir a glibc.

set -euo pipefail

: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
: "${ADM_PROFILE:?ADM_PROFILE não definido}"

echo "[HOOK Glibc-2.42/pre_build] Verificando pré-requisitos (perfil=${ADM_PROFILE})"

if [[ "${ADM_PROFILE}" != "glibc" ]]; then
    echo "[HOOK Glibc-2.42/pre_build] ERRO: este pacote só é suportado no perfil 'glibc'." >&2
    exit 1
fi

# Target padrão (mesma lógica de build.sh)
default_target="x86_64-adm-linux-gnu"
target="${ADM_TARGET:-$default_target}"

tools_prefix="${ADM_ROOTFS}/tools"
tools_bindir="${tools_prefix}/bin"

if [[ ! -d "${tools_bindir}" ]]; then
    echo "[HOOK Glibc-2.42/pre_build] ERRO: diretório ${tools_bindir} não existe. Toolchain cross não instalado?" >&2
    exit 1
fi

# Binários essenciais do toolchain cross
need_bins=(
    "${target}-gcc"
    "${target}-g++"
    "${target}-ld"
    "${target}-as"
)

for b in "${need_bins[@]}"; do
    if [[ ! -x "${tools_bindir}/${b}" ]]; then
        echo "[HOOK Glibc-2.42/pre_build] ERRO: binário obrigatório não encontrado: ${tools_bindir}/${b}" >&2
        exit 1
    fi
done

# Verifica headers do kernel já instalados
if [[ ! -d "${ADM_ROOTFS}/usr/include/linux" ]]; then
    echo "[HOOK Glibc-2.42/pre_build] ERRO: linux headers parecem não instalados em ${ADM_ROOTFS}/usr/include/linux." >&2
    exit 1
fi

echo "[HOOK Glibc-2.42/pre_build] Toolchain cross e linux headers OK para target=${target}"
