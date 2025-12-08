#!/usr/bin/env bash
# Hook post_install para sanity-check do GCC 15.2.0 - Pass 1

set -euo pipefail

PKG_EXPECTED_VERSION="15.2.0"

# Mesmo esquema: usa ADM_ROOTFS se estiver exportado, senão cai no default
ROOTFS="${ADM_ROOTFS:-/opt/adm/rootfs}"
ROOTFS="${ROOTFS%/}"

TOOLS_BIN="${ROOTFS}/tools/bin"
GCC_BIN="${TOOLS_BIN}/gcc"

echo "[gcc-pass1/post_install] Sanity-check do GCC Pass 1 em ${GCC_BIN}..."

if [[ ! -x "${GCC_BIN}" ]]; then
  echo "[gcc-pass1/post_install] ERRO: gcc não encontrado em ${GCC_BIN}" >&2
  exit 1
fi

gcc_version="$("${GCC_BIN}" --version 2>/dev/null | head -n1 || true)"
if [[ -z "${gcc_version}" ]]; then
  echo "[gcc-pass1/post_install] ERRO: não foi possível obter 'gcc --version'." >&2
  exit 1
fi

echo "[gcc-pass1/post_install] gcc --version: ${gcc_version}"

if ! grep -q "${PKG_EXPECTED_VERSION}" <<<"${gcc_version}"; then
  echo "[gcc-pass1/post_install] ERRO: versão inesperada de gcc (esperado ${PKG_EXPECTED_VERSION})." >&2
  exit 1
fi

# PATH de teste com /tools/bin na frente
PATH="${TOOLS_BIN}:${PATH}"
export PATH

# Compila um programa simples e checa se o binário é criado
TMPDIR="${ROOTFS}/tmp/adm-gcc-pass1-test"
mkdir -p "${TMPDIR}"

cat > "${TMPDIR}/dummy.c" << 'EOF'
int main(void) { return 0; }
EOF

echo "[gcc-pass1/post_install] Compilando programa de teste com gcc (Pass 1)..."

if ! "${GCC_BIN}" dummy.c -v -Wl,--verbose -o dummy.out >"${TMPDIR}/build.log" 2>&1; then
  echo "[gcc-pass1/post_install] ERRO: falha ao compilar programa de teste com gcc." >&2
  sed -n '1,80p' "${TMPDIR}/build.log" || true
  exit 1
fi

if [[ ! -x "${TMPDIR}/dummy.out" ]]; then
  echo "[gcc-pass1/post_install] ERRO: binário de teste não foi criado." >&2
  exit 1
fi

# Apenas um check simples de que o toolchain está olhando para /tools
if grep -q "/tools" "${TMPDIR}/build.log"; then
  echo "[gcc-pass1/post_install] OK: log de linkagem mostra referências a /tools (esperado para Pass 1)."
else
  echo "[gcc-pass1/post_install] AVISO: não encontrei referência a /tools no log de linkagem."
  echo "[gcc-pass1/post_install]         Verifique se o PATH/sysroot do seu ambiente de build está correto."
fi

# Limpa artefatos de teste (melhor esforço)
rm -f "${TMPDIR}/dummy.c" "${TMPDIR}/dummy.out" "${TMPDIR}/build.log" 2>/dev/null || true
rmdir "${TMPDIR}" 2>/dev/null || true

echo "[gcc-pass1/post_install] OK: GCC Pass 1 ${PKG_EXPECTED_VERSION} em /tools parece funcional."
exit 0
