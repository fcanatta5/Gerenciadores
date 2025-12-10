#!/usr/bin/env bash
# Hook post_install para toolchain/Libstdc++-15.2.0
# Sanity-check básico da libstdc++ instalada no rootfs.

set -euo pipefail

: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
: "${ADM_PROFILE:?ADM_PROFILE não definido}"

echo "[HOOK Libstdc++-15.2.0/post_install] Iniciando sanity-check da libstdc++ (perfil=${ADM_PROFILE})."

# Determina target como no build/pre_build
local_libc=""
case "${ADM_PROFILE}" in
    musl) local_libc="musl" ;;
    *)    local_libc="gnu"  ;;
esac

default_target="x86_64-adm-linux-${local_libc}"
target="${ADM_TARGET:-$default_target}"

tools_bindir="${ADM_ROOTFS}/tools/bin"
usr_bindir="${ADM_ROOTFS}/usr/bin"

candidates=(
    "${tools_bindir}/${target}-g++"
    "${usr_bindir}/${target}-g++"
)

gxx=""
for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
        gxx="$c"
        break
    fi
done

if [[ -z "$gxx" ]]; then
    echo "[HOOK Libstdc++-15.2.0/post_install] ERRO: não encontrei ${target}-g++ após instalar libstdc++." >&2
    exit 1
fi

echo "[HOOK Libstdc++-15.2.0/post_install] Usando compilador C++ para teste: ${gxx}"

# Verifica se a libstdc++ foi instalada em /usr/lib ou /usr/lib64
root_usr_lib="${ADM_ROOTFS}/usr/lib"
root_usr_lib64="${ADM_ROOTFS}/usr/lib64"

has_lib=0

if [[ -d "${root_usr_lib}" ]] && compgen -G "${root_usr_lib}/libstdc++.so*" > /dev/null 2>&1; then
    echo "[HOOK Libstdc++-15.2.0/post_install] libstdc++.so encontrada em ${root_usr_lib}"
    has_lib=1
fi

if [[ -d "${root_usr_lib64}" ]] && compgen -G "${root_usr_lib64}/libstdc++.so*" > /dev/null 2>&1; then
    echo "[HOOK Libstdc++-15.2.0/post_install] libstdc++.so encontrada em ${root_usr_lib64}"
    has_lib=1
fi

if (( has_lib == 0 )); then
    echo "[HOOK Libstdc++-15.2.0/post_install] ERRO: nenhuma libstdc++.so encontrada sob ${ADM_ROOTFS}/usr/lib*." >&2
    exit 1
fi

# Teste de compilação C++ simples
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
cd "${tmpdir}"

cat > hello.cpp << 'EOF'
#include <iostream>

int main() {
    std::cout << "libstdc++ sanity OK" << std::endl;
    return 0;
}
EOF

echo "[HOOK Libstdc++-15.2.0/post_install] Compilando hello.cpp com ${gxx} ..."
if ! "${gxx}" hello.cpp -std=c++17 -O2 -pipe -v -o hello &> build.log; then
    echo "[HOOK Libstdc++-15.2.0/post_install] ERRO: falha ao compilar hello.cpp (veja build.log em caso de debug)." >&2
    exit 1
fi

if [[ ! -f hello ]]; then
    echo "[HOOK Libstdc++-15.2.0/post_install] ERRO: binário hello não foi gerado." >&2
    exit 1
fi

echo "[HOOK Libstdc++-15.2.0/post_install] Compilação de teste OK. libstdc++ parece funcional para target=${target}."
