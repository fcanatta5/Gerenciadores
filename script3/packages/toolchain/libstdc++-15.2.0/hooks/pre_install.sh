#!/usr/bin/env bash
# Hook pre_install para toolchain/Libstdc++-15.2.0
# Executado antes de o ADM mesclar DESTDIR em ${ADM_ROOTFS}.

set -euo pipefail

: "${ADM_PROFILE:?ADM_PROFILE não definido}"
: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

echo "[HOOK Libstdc++-15.2.0/pre_install] Preparando para instalar libstdc++ em ${ADM_ROOTFS} (perfil=${ADM_PROFILE})."
