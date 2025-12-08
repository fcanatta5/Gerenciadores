#!/usr/bin/env bash
# Hook post_install para sanity-check do GNU M4 1.4.20

set -euo pipefail

PKG_EXPECTED_VERSION="1.4.20"

ROOTFS="${ADM_HOOK_ROOTFS:-/}"
# Garante que não teremos // na junção
ROOTFS="${ROOTFS%/}"

M4_BIN="${ROOTFS}/usr/bin/m4"

echo "[m4/post_install] Sanity-check do m4 em '${M4_BIN}'..."

if [[ ! -x "${M4_BIN}" ]]; then
  echo "[m4/post_install] ERRO: binário não encontrado ou não executável: ${M4_BIN}" >&2
  exit 1
fi

# Verifica versão
version_line="$("${M4_BIN}" --version 2>/dev/null | head -n1 || true)"

if [[ -z "${version_line}" ]]; then
  echo "[m4/post_install] ERRO: não foi possível obter 'm4 --version'." >&2
  exit 1
fi

echo "[m4/post_install] Versão reportada: ${version_line}"

if ! grep -q "${PKG_EXPECTED_VERSION}" <<<"${version_line}"; then
  echo "[m4/post_install] ERRO: versão inesperada de m4 (esperado: ${PKG_EXPECTED_VERSION})." >&2
  exit 1
fi

# Teste funcional simples: macro define + expansão
test_input=$'define(TEST,ok)dnl\nTEST\n'
test_output="$("${M4_BIN}" <<< "${test_input}" 2>/dev/null || true)"

# Normaliza quebras de linha
test_output="$(printf '%s' "${test_output}" | tr -d '\r')"

if [[ "${test_output}" != "ok" ]]; then
  echo "[m4/post_install] ERRO: teste funcional falhou."
  echo "[m4/post_install] Input:"
  echo "${test_input}"
  echo "[m4/post_install] Output obtido:"
  printf '%s\n' "${test_output}"
  exit 1
fi

echo "[m4/post_install] OK: m4 ${PKG_EXPECTED_VERSION} instalado e funcionando."
exit 0
