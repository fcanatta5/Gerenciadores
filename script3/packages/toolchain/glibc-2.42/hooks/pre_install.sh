#!/usr/bin/env bash
# Hook pre_install para toolchain/Glibc-2.42
# Executado antes de o ADM mesclar o DESTDIR no rootfs.

set -euo pipefail

: "${ADM_PROFILE:?ADM_PROFILE não definido}"
: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

echo "[HOOK Glibc-2.42/pre_install] Preparando para instalar Glibc-2.42 em ${ADM_ROOTFS} (perfil=${ADM_PROFILE})."

if [[ "${ADM_PROFILE}" != "glibc" ]]; then
    echo "[HOOK Glibc-2.42/pre_install] ERRO: perfil não é 'glibc'. Abortando instalação." >&2
    exit 1
fi
