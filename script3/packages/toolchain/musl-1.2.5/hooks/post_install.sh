#!/usr/bin/env bash
# Hook post_install para toolchain/musl-1.2.5
# Sanity-check da instalação da musl no rootfs-musl.

set -euo pipefail

: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
: "${ADM_PROFILE:?ADM_PROFILE não definido}"

echo "[HOOK musl-1.2.5/post_install] Iniciando sanity-check da musl (perfil=${ADM_PROFILE})."

if [[ "${ADM_PROFILE}" != "musl" ]]; then
    echo "[HOOK musl-1.2.5/post_install] ERRO: este hook só faz sentido no perfil 'musl'." >&2
    exit 1
fi

# Determina target (mesma lógica do build.sh)
default_target="x86_64-adm-linux-musl"
target="${ADM_TARGET:-$default_target}"

# Extrai ARCH do triplo (primeira parte antes do primeiro '-')
arch="${target%%-*}"

if [[ -z "${arch}" ]]; then
    echo "[HOOK musl-1.2.5/post_install] ERRO: não foi possível deduzir arch a partir de target='${target}'." >&2
    exit 1
fi

loader_path="${ADM_ROOTFS}/lib/ld-musl-${arch}.so.1"

if [[ ! -e "${loader_path}" ]]; then
    echo "[HOOK musl-1.2.5/post_install] ERRO: loader dinâmico esperado não encontrado: ${loader_path}" >&2
    echo "[HOOK musl-1.2.5/post_install] Verifique se a instalação da musl colocou ld-musl-${arch}.so.1 em /lib." >&2
    exit 1
fi

echo "[HOOK musl-1.2.5/post_install] Loader encontrado: ${loader_path}"

# Procura compilador do target em /tools e /usr
tools_bindir="${ADM_ROOTFS}/tools/bin"
usr_bindir="${ADM_ROOTFS}/usr/bin"

candidates_gcc=(
    "${tools_bindir}/${target}-gcc"
    "${usr_bindir}/${target}-gcc"
)

gcc_path=""
for c in "${candidates_gcc[@]}"; do
    if [[ -x "${c}" ]]; then
        gcc_path="${c}"
        break
    fi
done

if [[ -z "${gcc_path}" ]]; then
    echo "[HOOK musl-1.2.5/post_install] ERRO: não encontrei compilador C do target (${target}-gcc) em ${tools_bindir} nem em ${usr_bindir}." >&2
    exit 1
fi

echo "[HOOK musl-1.2.5/post_install] Usando compilador para teste: ${gcc_path}"

# Compila um programa de teste
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
cd "${tmpdir}"

cat > hello.c << 'EOF'
#include <stdio.h>

int main(void) {
    puts("musl sanity OK");
    return 0;
}
EOF

echo "[HOOK musl-1.2.5/post_install] Compilando hello.c com ${gcc_path} ..."
if ! "${gcc_path}" hello.c -O2 -pipe -v -Wl,--verbose -o hello &> build.log; then
    echo "[HOOK musl-1.2.5/post_install] ERRO: falha ao compilar hello.c (ver build.log para detalhes)." >&2
    exit 1
fi

if [[ ! -f hello ]]; then
    echo "[HOOK musl-1.2.5/post_install] ERRO: binário 'hello' não foi gerado." >&2
    exit 1
fi

# Se readelf existir, conferir o program interpreter
if command -v readelf >/dev/null 2>&1; then
    echo "[HOOK musl-1.2.5/post_install] Inspecionando ELF com readelf -l ..."
    if readelf -l hello | grep -q "Requesting program interpreter"; then
        # Há interpreter, verificar se é o loader da musl
        if ! readelf -l hello | grep -q "Requesting program interpreter: /lib/ld-musl-${arch}.so.1"; then
            echo "[HOOK musl-1.2.5/post_install] ERRO: o program interpreter do binário de teste não é /lib/ld-musl-${arch}.so.1." >&2
            readelf -l hello | grep "Requesting program interpreter" || true
            exit 1
        fi
        echo "[HOOK musl-1.2.5/post_install] Program interpreter OK (/lib/ld-musl-${arch}.so.1)."
    else
        # Provavelmente binário estático; aceitável, mas registrar aviso
        echo "[HOOK musl-1.2.5/post_install] AVISO: binário 'hello' parece estar linkado estaticamente (sem program interpreter)."
    fi
else
    echo "[HOOK musl-1.2.5/post_install] AVISO: 'readelf' não encontrado; pulando checagem detalhada do ELF."
fi

echo "[HOOK musl-1.2.5/post_install] Sanity-check da musl-1.2.5 concluído com sucesso para target=${target}."
