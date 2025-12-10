#!/usr/bin/env bash
# Hook post_install para toolchain/Glibc-2.42
# Sanity-check da toolchain (binutils+gcc+glibc) dentro do rootfs glibc.

set -euo pipefail

: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
: "${ADM_PROFILE:?ADM_PROFILE não definido}"

echo "[HOOK Glibc-2.42/post_install] Iniciando sanity-check da toolchain com Glibc-2.42 (perfil=${ADM_PROFILE})."

if [[ "${ADM_PROFILE}" != "glibc" ]]; then
    echo "[HOOK Glibc-2.42/post_install] ERRO: este hook só faz sentido no perfil 'glibc'." >&2
    exit 1
fi

default_target="x86_64-adm-linux-gnu"
target="${ADM_TARGET:-$default_target}"

tools_prefix="${ADM_ROOTFS}/tools"
tools_bindir="${tools_prefix}/bin"
gcc_path="${tools_bindir}/${target}-gcc"

if [[ ! -x "${gcc_path}" ]]; then
    echo "[HOOK Glibc-2.42/post_install] ERRO: compilador cross não encontrado: ${gcc_path}" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
cd "${tmpdir}"

echo 'int main(){}' > dummy.c

echo "[HOOK Glibc-2.42/post_install] Compilando dummy.c com ${gcc_path} -v -Wl,--verbose ..."
# Compila e já gera dummy.log com detalhes de linkagem
if ! "${gcc_path}" dummy.c -v -Wl,--verbose -o a.out &> dummy.log; then
    echo "[HOOK Glibc-2.42/post_install] ERRO: compilação de teste falhou." >&2
    exit 1
fi

if [[ ! -f a.out ]]; then
    echo "[HOOK Glibc-2.42/post_install] ERRO: binário de teste a.out não foi gerado." >&2
    exit 1
fi

# Se readelf estiver disponível, checa o program interpreter
if command -v readelf >/dev/null 2>&1; then
    if ! readelf -l a.out | grep -q "Requesting program interpreter"; then
        echo "[HOOK Glibc-2.42/post_install] ERRO: não foi possível encontrar 'Requesting program interpreter' em readelf -l a.out." >&2
        exit 1
    fi
else
    echo "[HOOK Glibc-2.42/post_install] AVISO: 'readelf' não encontrado, pulando checagem do program interpreter."
fi

# Verifica se /usr/include do rootfs está no search path dos headers no log
if ! grep -F " ${ADM_ROOTFS}/usr/include" dummy.log >/dev/null 2>&1; then
    echo "[HOOK Glibc-2.42/post_install] ERRO: ${ADM_ROOTFS}/usr/include não está no search path de headers do compilador." >&2
    exit 1
fi

# Verifica se libc.so.6 do rootfs está sendo usada
if ! grep -q "libc.so.6" dummy.log; then
    echo "[HOOK Glibc-2.42/post_install] ERRO: não foi possível encontrar referência à libc.so.6 no log do link." >&2
    exit 1
fi

echo "[HOOK Glibc-2.42/post_install] Sanity-check da Glibc-2.42 e toolchain concluído com sucesso para target=${target}."
