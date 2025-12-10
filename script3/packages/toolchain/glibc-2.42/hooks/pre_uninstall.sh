#!/usr/bin/env bash
# Hook pre_uninstall para toolchain/Glibc-2.42
# Apenas um aviso forte: remover glibc pode quebrar o rootfs.

set -euo pipefail

: "${ADM_PROFILE:?ADM_PROFILE não definido}"

echo "[HOOK Glibc-2.42/pre_uninstall] ATENÇÃO: prestes a desinstalar Glibc-2.42 do perfil ${ADM_PROFILE}."
echo "[HOOK Glibc-2.42/pre_uninstall] Isso pode tornar o rootfs inutilizável se não houver outra libc disponível."
