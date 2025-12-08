#!/usr/bin/env bash
# Hook post_install para sanity-check do GCC 15.2.0 - Pass 1

set -euo pipefail

PKG_EXPECTED_VERSION="15.2.0"

ROOTFS="${ADM_HOOK_ROOTFS:-/}"
ROOTFS="${ROOTFS%/}"

TOOLS_BIN="${ROOTFS}/tools/bin"
GCC_BIN="${TOOLS_BIN}/gcc"

echo "[gcc-pass1/post_install] Sanity-check do GCC Pass 1 em ${GCC_BIN}..."

if [[ ! -x "${GCC_BIN}" ]]; then
  echo "[gcc-pass1/post_install] ERRO: gcc não encontrado ou não executável em ${GCC_BIN}" >&2
  exit 1
fi

# Versão
gcc_version="$("${GCC_BIN}" --version 2>/dev/null | head -n1 || true)"

if [[ -z "${gcc_version}" ]]; then
  echo "[gcc-pass1/post_install] ERRO: não foi possível obter 'gcc --version'." >&2
  exit 1
fi

echo "[gcc-pass1/post_install] gcc --version: ${gcc_version}"

if ! grep -q "${PKG_EXPECTED_VERSION}" <<<"${gcc_version}"; then
  echo "[gcc-pass1/post_install] ERRO: versão inesperada de gcc (esperado: ${PKG_EXPECTED_VERSION})." >&2
  exit 1
fi

# Prepara PATH de teste com /tools/bin na frente
PATH_TEST="${TOOLS_BIN}:${PATH}"
PATH="${PATH_TEST}"
export PATH

# Sanity LFS-like: compila um pequeno programa e inspeciona o link
TMPDIR="${ROOTFS}/tmp/adm-gcc-pass1-test"
mkdir -p "${TMPDIR}"

cat > "${TMPDIR}/dummy.c" << 'EOF'
int main(void) { return 0; }
EOF

echo "[gcc-pass1/post_install] Compilando programa de teste com gcc (Pass 1)..."

# Compila sem libs extras, estático simples
"${GCC_BIN}" dummy.c -v -Wl,--verbose -o dummy.out  >"${TMPDIR}/build.log" 2>&1 || {
  echo "[gcc-pass1/post_install] ERRO: falha ao compilar programa de teste com gcc." >&2
  sed -n '1,80p' "${TMPDIR}/build.log" || true
  exit 1
}

if [[ ! -x "${TMPDIR}/dummy.out" ]]; then
  echo "[gcc-pass1/post_install] ERRO: binário de teste não foi criado." >&2
  exit 1
fi

# Verifica que o ld usado vem de /tools (análise do log de link)
if grep -q "/tools/lib" "${TMPDIR}/build.log"; then
  echo "[gcc-pass1/post_install] OK: linkagem usando /tools/lib (esperado para Pass 1)."
else
  echo "[gcc-pass1/post_install] AVISO: não encontrei referência a /tools/lib no log de linkagem."
  echo "[gcc-pass1/post_install] Verifique se o GCC Pass 1 está realmente usando o sysroot /tools."
fi

# Limpa artefatos de teste (opcional)
rm -f "${TMPDIR}/dummy.c" "${TMPDIR}/dummy.out" "${TMPDIR}/build.log" 2>/dev/null || true
rmdir "${TMPDIR}" 2>/dev/null || true

echo "[gcc-pass1/post_install] OK: GCC Pass 1 ${PKG_EXPECTED_VERSION} em /tools parece funcional."
exit 0
