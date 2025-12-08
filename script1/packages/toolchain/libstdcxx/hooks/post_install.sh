#!/usr/bin/env bash
# Hook post_install para Libstdc++ (GCC 15.2.0) - Pass 1

set -euo pipefail

PKG_EXPECTED_GCC_VERSION="15.2.0"

# ENV do adm.sh
ROOTFS="${ADM_ROOTFS:-/opt/adm/rootfs}"
ROOTFS="${ROOTFS%/}"

echo "[libstdcxx-pass1/post_install] Sanity-check da Libstdc++ Pass 1 em ${ROOTFS}..."

# 1) Procurar libstdc++ em /usr/lib* dentro do rootfs
LIBDIRS=(
  "${ROOTFS}/usr/lib"
  "${ROOTFS}/usr/lib64"
)

found_so=""
found_a=""

for d in "${LIBDIRS[@]}"; do
  [[ -d "$d" ]] || continue

  if [[ -z "${found_so}" ]]; then
    f="$(find "$d" -maxdepth 1 -type f -name 'libstdc++.so*' 2>/dev/null | head -n1 || true)"
    [[ -n "$f" ]] && found_so="$f"
  fi

  if [[ -z "${found_a}" ]]; then
    f="$(find "$d" -maxdepth 1 -type f -name 'libstdc++.a' 2>/dev/null | head -n1 || true)"
    [[ -n "$f" ]] && found_a="$f"
  fi
done

if [[ -z "${found_so}" ]]; then
  echo "[libstdcxx-pass1/post_install] ERRO: libstdc++.so* não encontrada em ${ROOTFS}/usr/lib*." >&2
  exit 1
fi

echo "[libstdcxx-pass1/post_install] libstdc++.so encontrada em: ${found_so}"

if [[ -n "${found_a}" ]]; then
  echo "[libstdcxx-pass1/post_install] libstdc++.a encontrada em: ${found_a}"
fi

# 2) Encontrar um compilador C++ para o teste
CCXX=""

# Preferimos o cross C++ que está em /tools (GCC Pass 1)
if [[ -n "${TARGET_TRIPLET:-}" ]]; then
  if [[ -x "${ROOTFS}/tools/bin/${TARGET_TRIPLET}-g++" ]]; then
    CCXX="${ROOTFS}/tools/bin/${TARGET_TRIPLET}-g++"
  elif [[ -x "${ROOTFS}/tools/bin/${TARGET_TRIPLET}-c++" ]]; then
    CCXX="${ROOTFS}/tools/bin/${TARGET_TRIPLET}-c++"
  fi
fi

# Fallback: g++ do sistema host, se existir
if [[ -z "${CCXX}" ]]; then
  if command -v g++ >/dev/null 2>&1; then
    CCXX="g++"
  fi
fi

if [[ -z "${CCXX}" ]]; then
  echo "[libstdcxx-pass1/post_install] AVISO: nenhum compilador C++ encontrado; pulando teste de compilação." >&2
  exit 0
fi

echo "[libstdcxx-pass1/post_install] Usando compilador para teste: ${CCXX}"

# 3) Compilar um programa C++ simples apontando para o rootfs

TMPDIR="$(mktemp -d /tmp/adm-libstdcxx-pass1-test.XXXXXX)"
trap 'rm -rf "${TMPDIR}" 2>/dev/null || true' EXIT

cat > "${TMPDIR}/hello.cpp" << 'EOF'
#include <iostream>
#include <string>

int main() {
    std::string s = "libstdc++ sanity test";
    std::cout << s << std::endl;
    return 0;
}
EOF

echo "[libstdcxx-pass1/post_install] Compilando programa de teste com --sysroot=${ROOTFS} ..."

if ! "${CCXX}" --sysroot="${ROOTFS}" "${TMPDIR}/hello.cpp" -o "${TMPDIR}/hello" -v >"${TMPDIR}/build.log" 2>&1; then
  echo "[libstdcxx-pass1/post_install] ERRO: falha ao compilar programa C++ de teste." >&2
  sed -n '1,80p' "${TMPDIR}/build.log" || true
  exit 1
fi

if [[ ! -x "${TMPDIR}/hello" ]]; then
  echo "[libstdcxx-pass1/post_install] ERRO: binário de teste não foi criado." >&2
  exit 1
fi

# 4) Verifica dependência em libstdc++ (não precisa executar o binário)

if command -v readelf >/dev/null 2>&1; then
  needed="$(readelf -d "${TMPDIR}/hello" 2>/dev/null \
            | awk '/NEEDED/ {gsub(/\[|\]/, "", $NF); print $NF}' \
            | grep -E '^libstdc\+\+' || true)"
  if [[ -z "${needed}" ]]; then
    echo "[libstdcxx-pass1/post_install] AVISO: não encontrei NEEDED para libstdc++ no binário de teste." >&2
  else
    echo "[libstdcxx-pass1/post_install] Binário depende de: ${needed}"
  fi
elif command -v ldd >/dev/null 2>&1; then
  if ldd "${TMPDIR}/hello" 2>/dev/null | grep -q 'libstdc++'; then
    echo "[libstdcxx-pass1/post_install] ldd mostra dependência em libstdc++ (OK)."
  else
    echo "[libstdcxx-pass1/post_install] AVISO: ldd não mostra libstdc++ explicitamente." >&2
  fi
else
  echo "[libstdcxx-pass1/post_install] AVISO: nem readelf nem ldd disponíveis; skip do check de dependência dinâmica." >&2
fi

echo "[libstdcxx-pass1/post_install] ✅ Libstdc++ (GCC ${PKG_EXPECTED_GCC_VERSION}) parece instalada e funcional."
exit 0
