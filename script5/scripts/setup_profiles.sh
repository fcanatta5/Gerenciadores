#!/usr/bin/env bash
set -euo pipefail

ADM_ROOT="${ADM_ROOT:-/opt/adm}"

profiles=(bootstrap glibc musl)

echo "Usando ADM_ROOT=${ADM_ROOT}"

for p in "${profiles[@]}"; do
    rootfs="${ADM_ROOT}/profiles/${p}/rootfs"

    echo "==> Criando estrutura do profile '${p}' em ${rootfs}"

    # Diretórios básicos de um rootfs LFS-like
    mkdir -p \
        "${rootfs}/"{bin,sbin,lib,lib64,usr/{bin,sbin,lib,include,share},etc,var,tmp,dev,proc,sys,run,home,root,tools}

    # Permissões padrão
    chmod 1777 "${rootfs}/tmp"

    # Cria diretório do profile e DB se ainda não existirem
    mkdir -p "${ADM_ROOT}/profiles/${p}" "${ADM_ROOT}/db/${p}"

    # Cria env.sh genérico se ainda não existir
    env_file="${ADM_ROOT}/profiles/${p}/env.sh"
    if [ ! -f "$env_file" ]; then
        echo "  - Criando ${env_file}"
        case "$p" in
            bootstrap)
                cat > "$env_file" <<'EOF'
# env.sh - ambiente do profile "bootstrap"
#
# Este profile é usado para o toolchain inicial (Binutils Pass 1, GCC Pass 1, etc.)
# O adm.sh já exporta:
#   ADM_CURRENT_PROFILE
#   ADM_CURRENT_ROOTFS
# e prefixa PATH com:
#   $ADM_CURRENT_ROOTFS/tools/bin
#   $ADM_CURRENT_ROOTFS/usr/bin
#   $ADM_CURRENT_ROOTFS/bin

export LFS_TGT="$(uname -m)-lfs-linux-gnu"

# Refina PATH para garantir que o toolchain de bootstrap vem antes de tudo
export PATH="${ADM_CURRENT_ROOTFS}/tools/bin:${PATH}"

# Ferramentas do target
export CC="${LFS_TGT}-gcc"
export CXX="${LFS_TGT}-g++"
export AR="${LFS_TGT}-ar"
export AS="${LFS_TGT}-as"
export RANLIB="${LFS_TGT}-ranlib"
export LD="${LFS_TGT}-ld"
export STRIP="${LFS_TGT}-strip"

# Flags padrão de compilação para o toolchain inicial
export CFLAGS="-O2 -pipe"
export CXXFLAGS="${CFLAGS}"

# Evita que pkg-config do host interfira
export PKG_CONFIG_PATH=
EOF
                ;;
            glibc)
                cat > "$env_file" <<'EOF'
# env.sh - ambiente do profile "glibc"
#
# Profile principal baseado em glibc.
# Aqui você normalmente já terá um toolchain razoavelmente estável dentro do rootfs.

# O adm.sh já prefixa PATH com:
#   $ADM_CURRENT_ROOTFS/tools/bin
#   $ADM_CURRENT_ROOTFS/usr/bin
#   $ADM_CURRENT_ROOTFS/bin

# Compilador "nativo" esperado dentro do rootfs glibc
export CC="gcc"
export CXX="g++"
export AR="ar"
export AS="as"
export RANLIB="ranlib"
export LD="ld"
export STRIP="strip"

export CFLAGS="-O2 -pipe"
export CXXFLAGS="${CFLAGS}"

# Em fases avançadas você pode querer algo como:
# export LDFLAGS="-Wl,-O1"
EOF
                ;;
            musl)
                cat > "$env_file" <<'EOF'
# env.sh - ambiente do profile "musl"
#
# Profile baseado em musl. O target típico pode ser algo como:
#   x86_64-lfs-linux-musl

export MUSL_TGT="$(uname -m)-lfs-linux-musl"

# O adm.sh já prefixa PATH com o tools/bin do próprio rootfs musl.
# Se você tiver um cross-toolchain musl, ele deve estar lá dentro.

export PATH="${ADM_CURRENT_ROOTFS}/tools/bin:${PATH}"

# Preferimos o toolchain musl do próprio profile
export CC="${MUSL_TGT}-gcc"
export CXX="${MUSL_TGT}-g++"
export AR="${MUSL_TGT}-ar"
export AS="${MUSL_TGT}-as"
export RANLIB="${MUSL_TGT}-ranlib"
export LD="${MUSL_TGT}-ld"
export STRIP="${MUSL_TGT}-strip"

export CFLAGS="-O2 -pipe"
export CXXFLAGS="${CFLAGS}"

export PKG_CONFIG_PATH=
EOF
                ;;
            *)
                cat > "$env_file" <<'EOF'
# env.sh - ambiente do profile genérico
#
# Ajuste as variáveis abaixo de acordo com a necessidade do seu profile.

export CC="gcc"
export CXX="g++"
export AR="ar"
export AS="as"
export RANLIB="ranlib"
export LD="ld"
export STRIP="strip"

export CFLAGS="-O2 -pipe"
export CXXFLAGS="${CFLAGS}"
EOF
                ;;
        esac
    else
        echo "  - Mantendo env.sh existente em ${env_file}"
    fi
done

echo
echo "Perfis criados. Agora você pode, por exemplo:"
echo "  ./adm.sh profile set bootstrap"
echo "  ./adm.sh profile set glibc"
echo "  ./adm.sh profile set musl"
