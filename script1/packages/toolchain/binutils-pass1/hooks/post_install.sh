#!/usr/bin/env bash
# Hook post_install para sanity-check do Binutils 2.45.1 - Pass 1

set -euo pipefail

PKG_EXPECTED_VERSION="2.45.1"

ROOTFS="${ADM_HOOK_ROOTFS:-/}"
ROOTFS="${ROOTFS%/}"

TOOLS_BIN="${ROOTFS}/tools/bin"

LD_BIN="${TOOLS_BIN}/ld"
AS_BIN="${TOOLS_BIN}/as"


TARGET_TRIPLET="${TARGET_TRIPLET:-}"
if [[ -z "${TARGET_TRIPLET}" ]]; then
  # Fallback simples: tenta ler do meta instalado no DB
  # (não é obrigatório, mas ajuda a identificar problemas)
  :
fi

echo "[binutils-pass1/post_install] Sanity-check do Binutils Pass 1..."

# Caminhos esperados
BIN_DIR_USR="${ROOTFS}/usr/bin"
BIN_DIR_TARGET="${ROOTFS}/usr/${TARGET_TRIPLET}/bin"

# Verifica existência de ld e as em /usr/bin
LD_BIN="${BIN_DIR_USR}/ld"
AS_BIN="${BIN_DIR_USR}/as"

if [[ ! -x "${LD_BIN}" ]]; then
  echo "[binutils-pass1/post_install] ERRO: ld não encontrado em ${LD_BIN}" >&2
  exit 1
fi

if [[ ! -x "${AS_BIN}" ]]; then
  echo "[binutils-pass1/post_install] ERRO: as não encontrado em ${AS_BIN}" >&2
  exit 1
fi

echo "[binutils-pass1/post_install] ld encontrado em: ${LD_BIN}"
echo "[binutils-pass1/post_install] as encontrado em: ${AS_BIN}"

# Se o diretório target existir, loga também
if [[ -n "${TARGET_TRIPLET}" && -d "${BIN_DIR_TARGET}" ]]; then
  echo "[binutils-pass1/post_install] Diretório de binários do target: ${BIN_DIR_TARGET}"
fi

# Verifica versão do ld e as
ld_version="$("${LD_BIN}" --version 2>/dev/null | head -n1 || true)"
as_version="$("${AS_BIN}" --version 2>/dev/null | head -n1 || true)"

if [[ -z "${ld_version}" ]]; then
  echo "[binutils-pass1/post_install] ERRO: não foi possível obter 'ld --version'." >&2
  exit 1
fi

if [[ -z "${as_version}" ]]; then
  echo "[binutils-pass1/post_install] ERRO: não foi possível obter 'as --version'." >&2
  exit 1
fi

echo "[binutils-pass1/post_install] ld --version: ${ld_version}"
echo "[binutils-pass1/post_install] as --version: ${as_version}"

if ! grep -q "${PKG_EXPECTED_VERSION}" <<<"${ld_version}"; then
  echo "[binutils-pass1/post_install] ERRO: versão inesperada de ld (esperado: ${PKG_EXPECTED_VERSION})." >&2
  exit 1
fi

# Sanity extra: garante que o ld “ativo” no PATH do rootfs é o nosso
# (isso só funciona bem se o seu PATH dentro do rootfs estiver montado
# de forma padrão; aqui montamos um PATH local apenas para o teste).
PATH_TEST="${BIN_DIR_USR}"
if [[ -n "${TARGET_TRIPLET}" && -d "${BIN_DIR_TARGET}" ]]; then
  PATH_TEST="${BIN_DIR_TARGET}:${PATH_TEST}"
fi

PATH_TEST="${TOOLS_BIN}"
PATH="${PATH_TEST}:${PATH}"
export PATH

which_ld="$(command -v ld || true)"
if [[ -z "${which_ld}" ]]; then
  echo "[binutils-pass1/post_install] ERRO: 'ld' não encontrado no PATH de teste (${PATH_TEST})." >&2
  exit 1
fi

echo "[binutils-pass1/post_install] 'ld' resolvido para: ${which_ld}"

# Caso você queira garantir que é exatamente aquele sob ROOTFS:
case "${which_ld}" in
  "${LD_BIN}"|*/usr/bin/ld)
    # Aceito
    ;;
  *)
    echo "[binutils-pass1/post_install] AVISO: 'ld' no PATH aponta para ${which_ld}, e não para ${LD_BIN}."
    echo "[binutils-pass1/post_install] Verifique se o PATH do ambiente de build está correto."
    ;;
esac

echo "[binutils-pass1/post_install] OK: Binutils Pass 1 ${PKG_EXPECTED_VERSION} instalado e aparentemente funcional."
exit 0
