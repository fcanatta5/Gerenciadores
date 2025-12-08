#!/usr/bin/env bash
# Hook post_install para Glibc 2.42 - Pass 1

set -euo pipefail

PKG_EXPECTED_VERSION="2.42"

# O adm.sh define ADM_ROOTFS globalmente. Se não existir, cai no default.
ROOTFS="${ADM_ROOTFS:-/opt/adm/rootfs}"
ROOTFS="${ROOTFS%/}"

echo "[glibc-pass1/post_install] Sanity-check da Glibc Pass 1 em ${ROOTFS}..."

# 1) Verificar arquivos básicos da Glibc no rootfs
LIBDIR_CANDIDATES=(
  "${ROOTFS}/lib"
  "${ROOTFS}/lib64"
  "${ROOTFS}/usr/lib"
  "${ROOTFS}/usr/lib64"
)

found_libc=""
found_loader=""

for d in "${LIBDIR_CANDIDATES[@]}"; do
  [[ -d "$d" ]] || continue

  if [[ -z "${found_libc}" ]]; then
    f="$(find "$d" -maxdepth 1 -type f -name 'libc.so.6' 2>/dev/null | head -n1 || true)"
    [[ -n "$f" ]] && found_libc="$f"
  fi

  if [[ -z "${found_loader}" ]]; then
    f="$(find "$d" -maxdepth 1 -type f -name 'ld-linux*.so.*' 2>/dev/null | head -n1 || true)"
    [[ -n "$f" ]] && found_loader="$f"
  fi
done

if [[ -z "${found_libc}" ]]; then
  echo "[glibc-pass1/post_install] ERRO: libc.so.6 não encontrada em ${ROOTFS}/lib* ou ${ROOTFS}/usr/lib*." >&2
  exit 1
fi

if [[ -z "${found_loader}" ]]; then
  echo "[glibc-pass1/post_install] ERRO: loader ld-linux*.so.* não encontrado em ${ROOTFS}/lib* ou ${ROOTFS}/usr/lib*." >&2
  exit 1
fi

echo "[glibc-pass1/post_install] libc encontrada:  ${found_libc}"
echo "[glibc-pass1/post_install] loader encontrado: ${found_loader}"

# 2) Compilar um programa simples usando o GCC do Pass 1 e apontando para o rootfs

# Descobre o compilador preferencial:
CC=""
if [[ -n "${TARGET_TRIPLET:-}" ]] && command -v "${TARGET_TRIPLET}-gcc" >/dev/null 2>&1; then
  CC="${TARGET_TRIPLET}-gcc"
elif command -v gcc >/dev/null 2>&1; then
  CC="gcc"
else
  echo "[glibc-pass1/post_install] AVISO: nenhum gcc encontrado no PATH; pulando teste de compilação." >&2
  exit 0
fi

echo "[glibc-pass1/post_install] Usando compilador para teste: ${CC}"

TMPDIR="$(mktemp -d /tmp/adm-glibc-pass1-test.XXXXXX)"
trap 'rm -rf "${TMPDIR}" 2>/dev/null || true' EXIT

cat > "${TMPDIR}/dummy.c" << 'EOF'
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    printf("glibc dummy test\n");
    return EXIT_SUCCESS;
}
EOF

echo "[glibc-pass1/post_install] Compilando programa de teste com --sysroot=${ROOTFS} ..."

if ! "${CC}" --sysroot="${ROOTFS}" "${TMPDIR}/dummy.c" -o "${TMPDIR}/dummy" -Wl,--verbose >"${TMPDIR}/build.log" 2>&1; then
  echo "[glibc-pass1/post_install] ERRO: falha ao compilar programa de teste com a Glibc Pass 1." >&2
  sed -n '1,80p' "${TMPDIR}/build.log" || true
  exit 1
fi

if [[ ! -x "${TMPDIR}/dummy" ]]; then
  echo "[glibc-pass1/post_install] ERRO: binário de teste não foi criado." >&2
  exit 1
fi

# 3) Verifica o loader configurado no binário (não precisa executar o binário)

interp=""

if command -v readelf >/dev/null 2>&1; then
  interp="$(readelf -l "${TMPDIR}/dummy" 2>/dev/null \
            | awk '/Requesting program interpreter/ {print $NF}' \
            | tr -d '[]' \
            | head -n1 || true)"
elif command -v file >/dev/null 2>&1; then
  interp="$(file "${TMPDIR}/dummy" 2>/dev/null \
            | sed -n 's/.*interpreter \([^,]*\),.*/\1/p' \
            | head -n1 || true)"
fi

if [[ -z "${interp}" ]]; then
  echo "[glibc-pass1/post_install] AVISO: não foi possível determinar o program interpreter do binário de teste." >&2
else
  echo "[glibc-pass1/post_install] Interpreter configurado no binário de teste: ${interp}"
  if [[ ! -f "${ROOTFS}${interp}" ]]; then
    echo "[glibc-pass1/post_install] ERRO: interpreter ${interp} não encontrado dentro do rootfs (${ROOTFS})." >&2
    exit 1
  fi
fi

echo "[glibc-pass1/post_install] ✅ Glibc Pass 1 (${PKG_EXPECTED_VERSION}) instalada de forma consistente no rootfs."
exit 0
