#!/usr/bin/env bash
# Hook pre_uninstall para toolchain/musl-1.2.5
# Aviso antes de remover a libc musl do rootfs-musl.

set -euo pipefail

: "${ADM_PROFILE:?ADM_PROFILE não definido}"
: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

echo "[HOOK musl-1.2.5/pre_uninstall] ATENÇÃO: prestes a desinstalar musl-1.2.5 do perfil ${ADM_PROFILE}."
echo "[HOOK musl-1.2.5/pre_uninstall] Rootfs: ${ADM_ROOTFS}"

if [[ "${ADM_PROFILE}" != "musl" ]]; then
    echo "[HOOK musl-1.2.5/pre_uninstall] ERRO: este hook só faz sentido no perfil 'musl'." >&2
    exit 1
fi

echo "[HOOK musl-1.2.5/pre_uninstall] Remover a musl pode tornar o rootfs (${ADM_ROOTFS}) inutilizável para binários desse target."
echo "[HOOK musl-1.2.5/pre_uninstall] Certifique-se de que você realmente deseja prosseguir."
