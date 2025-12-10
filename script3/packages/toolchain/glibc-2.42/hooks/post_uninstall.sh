#!/usr/bin/env bash
# Hook post_uninstall para toolchain/Glibc-2.42
# Log simples após remoção da glibc.

set -euo pipefail

: "${ADM_PROFILE:?ADM_PROFILE não definido}"

echo "[HOOK Glibc-2.42/post_uninstall] Glibc-2.42 desinstalada do perfil ${ADM_PROFILE}."
echo "[HOOK Glibc-2.42/post_uninstall] Verifique se existe alguma outra libc (por exemplo, em outro rootfs) antes de continuar usando esse ambiente."
