#!/usr/bin/env bash
# Hook post_uninstall para toolchain/musl-1.2.5
# Log e checagem simples após remoção da musl.

set -euo pipefail

: "${ADM_PROFILE:?ADM_PROFILE não definido}"
: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"

echo "[HOOK musl-1.2.5/post_uninstall] musl-1.2.5 desinstalada do perfil ${ADM_PROFILE}."
echo "[HOOK musl-1.2.5/post_uninstall] Rootfs: ${ADM_ROOTFS}"

if [[ "${ADM_PROFILE}" != "musl" ]]; then
    echo "[HOOK musl-1.2.5/post_uninstall] AVISO: perfil não é 'musl'; este hook não deveria ter sido chamado aqui." >&2
fi

libdir="${ADM_ROOTFS}/lib"

if [[ -d "${libdir}" ]]; then
    # Procura loaders da musl remanescentes
    if compgen -G "${libdir}/ld-musl-*.so.1" > /dev/null 2>&1; then
        echo "[HOOK musl-1.2.5/post_uninstall] AVISO: ainda existem loaders ld-musl-*.so.1 em ${libdir}."
        echo "[HOOK musl-1.2.5/post_uninstall]         Isso pode indicar sobras de outra instalação de musl ou de outro pacote."
    else
        echo "[HOOK musl-1.2.5/post_uninstall] Nenhum loader ld-musl-*.so.1 detectado em ${libdir}."
    fi
fi

echo "[HOOK musl-1.2.5/post_uninstall] Pós-desinstalação concluída."
