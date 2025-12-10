#!/usr/bin/env bash
# Hook post_install para toolchain/gcc-pass1
# Sanity-check básico do cross-compiler C-only instalado em /tools.

set -euo pipefail

: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
: "${ADM_PROFILE:?ADM_PROFILE não definido}"

echo "[HOOK gcc-pass1/post_install] Iniciando sanity-check (perfil=${ADM_PROFILE})"

# Mesmo cálculo de target do build.sh
local_libc=""
case "${ADM_PROFILE}" in
    musl) local_libc="musl" ;;
    *)    local_libc="gnu"  ;;
esac

target="${ADM_TARGET:-x86_64-adm-linux-${local_libc}}"

tools_prefix="${ADM_ROOTFS}/tools"
tools_bindir="${tools_prefix}/bin"

if [[ ! -d "${tools_bindir}" ]]; then
    echo "[HOOK gcc-pass1/post_install] ERRO: diretório ${tools_bindir} não existe." >&2
    exit 1
fi

gcc_path="${tools_bindir}/${target}-gcc"

if [[ ! -x "${gcc_path}" ]]; then
    echo "[HOOK gcc-pass1/post_install] ERRO: compilador cross não encontrado ou não executável: ${gcc_path}" >&2
    exit 1
fi

echo "[HOOK gcc-pass1/post_install] Encontrado GCC: ${gcc_path}"
echo "[HOOK gcc-pass1/post_install] Saída de ${target}-gcc --version:"
"${gcc_path}" --version | head -n 3 || {
    echo "[HOOK gcc-pass1/post_install] ERRO: falha ao executar ${gcc_path} --version" >&2
    exit 1
}

# Teste simples de compilação (sem link, apenas objeto)
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

cat > "${tmpdir}/hello.c" << 'EOF'
int main(void) { return 0; }
EOF

echo "[HOOK gcc-pass1/post_install] Compilando teste simples (apenas objeto) ..."
if ! "${gcc_path}" -c "${tmpdir}/hello.c" -o "${tmpdir}/hello.o"; then
    echo "[HOOK gcc-pass1/post_install] ERRO: falha ao compilar hello.c com ${target}-gcc" >&2
    exit 1
fi

if [[ ! -f "${tmpdir}/hello.o" ]]; then
    echo "[HOOK gcc-pass1/post_install] ERRO: objeto de teste não foi gerado." >&2
    exit 1
fi

echo "[HOOK gcc-pass1/post_install] Sanity-check de gcc-pass1 OK para target=${target}"
