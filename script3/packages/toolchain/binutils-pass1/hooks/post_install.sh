#!/usr/bin/env bash
# Hook post_install para toolchain/binutils-pass1
# Faz sanity-check básico do binutils cross instalado em /tools.

set -euo pipefail

: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
: "${ADM_PROFILE:?ADM_PROFILE não definido}"

echo "[HOOK binutils-pass1/post_install] Iniciando sanity-check (perfil=${ADM_PROFILE})"

# Deduz o mesmo target padrão usado no build.sh,
# mas permite sobrescrever via ADM_TARGET se você quiser.
local_libc=""
case "${ADM_PROFILE}" in
    musl) local_libc="musl" ;;
    *)    local_libc="gnu"  ;;
esac

target="${ADM_TARGET:-x86_64-adm-linux-${local_libc}}"

tools_prefix="${ADM_ROOTFS}/tools"
tools_bindir="${tools_prefix}/bin"

if [[ ! -d "${tools_prefix}" ]]; then
    echo "[HOOK binutils-pass1/post_install] ERRO: diretório ${tools_prefix} não existe." >&2
    exit 1
fi

if [[ ! -d "${tools_bindir}" ]]; then
    echo "[HOOK binutils-pass1/post_install] ERRO: diretório ${tools_bindir} não existe." >&2
    exit 1
fi

ld_path="${tools_bindir}/${target}-ld"

if [[ ! -x "${ld_path}" ]]; then
    echo "[HOOK binutils-pass1/post_install] ERRO: linker cross não encontrado ou não executável: ${ld_path}" >&2
    exit 1
fi

echo "[HOOK binutils-pass1/post_install] Encontrado linker: ${ld_path}"
echo "[HOOK binutils-pass1/post_install] Saída de ${target}-ld --version:"
"${ld_path}" --version | head -n 3 || {
    echo "[HOOK binutils-pass1/post_install] ERRO: falha ao executar ${ld_path} --version" >&2
    exit 1
}

echo "[HOOK binutils-pass1/post_install] Sanity-check básico de binutils-pass1 OK para perfil ${ADM_PROFILE} (target=${target})"
