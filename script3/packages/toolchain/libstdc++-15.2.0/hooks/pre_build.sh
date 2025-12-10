#!/usr/bin/env bash
# Hook pre_build para toolchain/Libstdc++-15.2.0
# Verifica se o toolchain C++ para o target está disponível.

set -euo pipefail

: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
: "${ADM_PROFILE:?ADM_PROFILE não definido}"

echo "[HOOK Libstdc++-15.2.0/pre_build] Verificando pré-requisitos (perfil=${ADM_PROFILE})"

# Determina libc no triplo (mesmo critério do build.sh)
local_libc=""
case "${ADM_PROFILE}" in
    musl) local_libc="musl" ;;
    *)    local_libc="gnu"  ;;
esac

default_target="x86_64-adm-linux-${local_libc}"
target="${ADM_TARGET:-$default_target}"

tools_bindir="${ADM_ROOTFS}/tools/bin"
usr_bindir="${ADM_ROOTFS}/usr/bin"

# Preferência: cross em /tools, mas aceita em /usr também
candidates=(
    "${tools_bindir}/${target}-g++"
    "${usr_bindir}/${target}-g++"
)

found=""
for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
        found="$c"
        break
    fi
done

if [[ -z "$found" ]]; then
    echo "[HOOK Libstdc++-15.2.0/pre_build] ERRO: não encontrei ${target}-g++ em ${tools_bindir} nem em ${usr_bindir}." >&2
    echo "[HOOK Libstdc++-15.2.0/pre_build] Certifique-se de que seu GCC final (com C++) já está instalado para esse target." >&2
    exit 1
fi

echo "[HOOK Libstdc++-15.2.0/pre_build] Encontrado compilador C++ do target: ${found}"

# checa headers básicos C++ no rootfs (include/c++ pode estar em /usr/include/c++ ou /usr/<triplo>/include/c++)
if [[ -d "${ADM_ROOTFS}/usr/include/c++" ]]; then
    echo "[HOOK Libstdc++-15.2.0/pre_build] Diretório genérico de headers C++ encontrado em ${ADM_ROOTFS}/usr/include/c++ (ok)."
fi

echo "[HOOK Libstdc++-15.2.0/pre_build] Pré-requisitos básicos OK para target=${target}."
