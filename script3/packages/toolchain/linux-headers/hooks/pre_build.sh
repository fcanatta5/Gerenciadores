#!/usr/bin/env bash
# Hook pre_build para core/linux-headers
# Faz sanity-check mínimo antes de construir os headers do kernel.

set -euo pipefail

: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
: "${ADM_PROFILE:?ADM_PROFILE não definido}"

echo "[HOOK linux-headers/pre_build] Verificando ambiente (perfil=${ADM_PROFILE})"

# Verificar se 'make' está disponível (deveria ser garantido pelo host/adm, mas conferimos aqui)
if ! command -v make >/dev/null 2>&1; then
    echo "[HOOK linux-headers/pre_build] ERRO: 'make' não encontrado no PATH." >&2
    exit 1
fi

# Opcional: verificar se existe ao menos um compilador C funcional (para eventuais builds auxiliares do kernel)
if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    echo "[HOOK linux-headers/pre_build] AVISO: Nenhum compilador C detectado em PATH. Headers normalmente não compilam código pesado, mas isso pode ser um problema." >&2
fi

echo "[HOOK linux-headers/pre_build] Ambiente básico OK."
