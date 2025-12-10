#!/usr/bin/env bash
# Hook pre_build para toolchain/musl-1.2.5
# Verifica se o ambiente está pronto para construir a musl.

set -euo pipefail

: "${ADM_ROOTFS:?ADM_ROOTFS não definido}"
: "${ADM_PROFILE:?ADM_PROFILE não definido}"

echo "[HOOK musl-1.2.5/pre_build] Verificando pré-requisitos (perfil=${ADM_PROFILE})."

if [[ "${ADM_PROFILE}" != "musl" ]]; then
    echo "[HOOK musl-1.2.5/pre_build] ERRO: este pacote só é suportado no perfil 'musl'." >&2
    exit 1
fi

# Target padrão (mesma lógica do build.sh)
default_target="x86_64-adm-linux-musl"
target="${ADM_TARGET:-$default_target}"

if [[ "${target}" != *"-musl" ]]; then
    echo "[HOOK musl-1.2.5/pre_build] ERRO: target '${target}' não parece ser um triplo musl (deveria terminar em '-musl')." >&2
    exit 1
fi

tools_bindir="${ADM_ROOTFS}/tools/bin"
usr_bindir="${ADM_ROOTFS}/usr/bin"

if [[ ! -d "${tools_bindir}" && ! -d "${usr_bindir}" ]]; then
    echo "[HOOK musl-1.2.5/pre_build] ERRO: diretórios de binários do toolchain (${tools_bindir} e ${usr_bindir}) não existem." >&2
    exit 1
fi

# Verifica binários básicos do toolchain (primeiro em /tools, depois em /usr)
need_bins=(
    "${target}-gcc"
    "${target}-ld"
    "${target}-as"
)

for prog in "${need_bins[@]}"; do
    found=""

    if [[ -x "${tools_bindir}/${prog}" ]]; then
        found="${tools_bindir}/${prog}"
    elif [[ -x "${usr_bindir}/${prog}" ]]; then
        found="${usr_bindir}/${prog}"
    fi

    if [[ -z "${found}" ]]; then
        echo "[HOOK musl-1.2.5/pre_build] ERRO: binário obrigatório não encontrado: ${prog} (procurei em ${tools_bindir} e ${usr_bindir})." >&2
        exit 1
    fi

    echo "[HOOK musl-1.2.5/pre_build] OK: encontrado ${found}"
done

# Verifica se os headers do kernel estão instalados no rootfs do perfil musl
if [[ ! -d "${ADM_ROOTFS}/usr/include/linux" ]]; then
    echo "[HOOK musl-1.2.5/pre_build] ERRO: linux headers parecem não instalados em ${ADM_ROOTFS}/usr/include/linux." >&2
    echo "[HOOK musl-1.2.5/pre_build] Instale o pacote de headers do kernel antes de construir a musl." >&2
    exit 1
fi

echo "[HOOK musl-1.2.5/pre_build] Linux headers encontrados em ${ADM_ROOTFS}/usr/include/linux."

# Aviso opcional sobre patch de segurança
# (o adm aplica automaticamente todos os *.patch na pasta do pacote)
pkg_dir="/opt/adm/packages/toolchain/musl-1.2.5"
if [[ -d "${pkg_dir}" ]]; then
    if compgen -G "${pkg_dir}/CVE-2025-26519*.patch" > /dev/null 2>&1; then
        echo "[HOOK musl-1.2.5/pre_build] Patches de segurança CVE-2025-26519* encontrados em ${pkg_dir} (serão aplicados pelo adm)."
    else
        echo "[HOOK musl-1.2.5/pre_build] AVISO: nenhum patch CVE-2025-26519*.patch encontrado em ${pkg_dir}."
        echo "[HOOK musl-1.2.5/pre_build]         Certifique-se de aplicar os patches de segurança necessários para musl-1.2.5."
    fi
fi

echo "[HOOK musl-1.2.5/pre_build] Pré-requisitos verificados com sucesso para target=${target}."
