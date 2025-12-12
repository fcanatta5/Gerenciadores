#!/usr/bin/env bash
set -euo pipefail

ADM_ROOT="${ADM_ROOT:-/opt/adm}"
FORCE="${FORCE:-0}"          # FORCE=1 sobrescreve env.sh existentes
PROFILES_DEFAULT=(bootstrap glibc musl)

# Permite passar perfis na linha de comando:
#   ./setup_profiles.sh bootstrap glibc
profiles=("$@")
if [ "${#profiles[@]}" -eq 0 ]; then
  profiles=("${PROFILES_DEFAULT[@]}")
fi

echo "ADM_ROOT=${ADM_ROOT}"
echo "Profiles: ${profiles[*]}"
echo

# Estrutura ADM básica (o adm.sh também cria, mas aqui garantimos)
mkdir -p "${ADM_ROOT}/"{profiles,db,packages,sources,binaries,build,log}

# Se não existir, define profile padrão como glibc
if [ ! -f "${ADM_ROOT}/current_profile" ]; then
  echo "glibc" > "${ADM_ROOT}/current_profile"
fi

create_rootfs_layout() {
  local rootfs="$1"

  mkdir -p \
    "${rootfs}/"{bin,sbin,lib,lib64,usr/{bin,sbin,lib,include,share},etc,var,tmp,dev,proc,sys,run,home,root,tools}

  chmod 1777 "${rootfs}/tmp"

  # Diretórios que costumam aparecer cedo em LFS-like (não é obrigatório, mas ajuda)
  mkdir -p "${rootfs}/var/"{log,lib,cache} || true
}

write_env_bootstrap() {
  local env_file="$1"
  cat > "$env_file" <<'EOF'
# env.sh - profile "bootstrap"
#
# Objetivo: suportar o bootstrap do toolchain em /tools (dentro do rootfs do profile).
# Importante: NÃO exportamos CC/CXX/LD do target se eles ainda não existem,
# para não quebrar a construção do próprio binutils/gcc pass 1.

export LFS_TGT="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"

# PATH: garanta prioridade para /tools do rootfs atual
export PATH="${ADM_CURRENT_ROOTFS}/tools/bin:${ADM_CURRENT_ROOTFS}/usr/bin:${ADM_CURRENT_ROOTFS}/bin:${PATH}"

# Flags básicas (ajuste conforme necessário)
export CFLAGS="${CFLAGS:-"-O2 -pipe"}"
export CXXFLAGS="${CXXFLAGS:-"${CFLAGS}"}"

# Evita interferência do host via pkg-config
export PKG_CONFIG_PATH=

# Só exporta toolchain cross quando ele existir de fato
if [ -x "${ADM_CURRENT_ROOTFS}/tools/bin/${LFS_TGT}-gcc" ]; then
  export CC="${LFS_TGT}-gcc"
  export CXX="${LFS_TGT}-g++"
  export AR="${LFS_TGT}-ar"
  export AS="${LFS_TGT}-as"
  export RANLIB="${LFS_TGT}-ranlib"
  export LD="${LFS_TGT}-ld"
  export STRIP="${LFS_TGT}-strip"
else
  unset CC CXX AR AS RANLIB LD STRIP 2>/dev/null || true
fi
EOF
}

write_env_glibc() {
  local env_file="$1"
  cat > "$env_file" <<'EOF'
# env.sh - profile "glibc"
#
# Profile destinado ao sistema glibc "nativo" dentro do rootfs do profile.

export PATH="${ADM_CURRENT_ROOTFS}/tools/bin:${ADM_CURRENT_ROOTFS}/usr/bin:${ADM_CURRENT_ROOTFS}/bin:${PATH}"

export CC="${CC:-gcc}"
export CXX="${CXX:-g++}"
export AR="${AR:-ar}"
export AS="${AS:-as}"
export RANLIB="${RANLIB:-ranlib}"
export LD="${LD:-ld}"
export STRIP="${STRIP:-strip}"

export CFLAGS="${CFLAGS:-"-O2 -pipe"}"
export CXXFLAGS="${CXXFLAGS:-"${CFLAGS}"}"
EOF
}

write_env_musl() {
  local env_file="$1"
  cat > "$env_file" <<'EOF'
# env.sh - profile "musl"
#
# Profile destinado a um sistema musl. Normalmente usa um toolchain cross:
#   $(uname -m)-lfs-linux-musl

export MUSL_TGT="${MUSL_TGT:-"$(uname -m)-lfs-linux-musl"}"

export PATH="${ADM_CURRENT_ROOTFS}/tools/bin:${ADM_CURRENT_ROOTFS}/usr/bin:${ADM_CURRENT_ROOTFS}/bin:${PATH}"

export CFLAGS="${CFLAGS:-"-O2 -pipe"}"
export CXXFLAGS="${CXXFLAGS:-"${CFLAGS}"}"
export PKG_CONFIG_PATH=

# Só exporta toolchain musl quando ele existir
if [ -x "${ADM_CURRENT_ROOTFS}/tools/bin/${MUSL_TGT}-gcc" ]; then
  export CC="${MUSL_TGT}-gcc"
  export CXX="${MUSL_TGT}-g++"
  export AR="${MUSL_TGT}-ar"
  export AS="${MUSL_TGT}-as"
  export RANLIB="${MUSL_TGT}-ranlib"
  export LD="${MUSL_TGT}-ld"
  export STRIP="${MUSL_TGT}-strip"
else
  unset CC CXX AR AS RANLIB LD STRIP 2>/dev/null || true
fi
EOF
}

write_env_generic() {
  local env_file="$1"
  cat > "$env_file" <<'EOF'
# env.sh - profile genérico

export PATH="${ADM_CURRENT_ROOTFS}/tools/bin:${ADM_CURRENT_ROOTFS}/usr/bin:${ADM_CURRENT_ROOTFS}/bin:${PATH}"

export CC="${CC:-gcc}"
export CXX="${CXX:-g++}"
export AR="${AR:-ar}"
export AS="${AS:-as}"
export RANLIB="${RANLIB:-ranlib}"
export LD="${LD:-ld}"
export STRIP="${STRIP:-strip}"

export CFLAGS="${CFLAGS:-"-O2 -pipe"}"
export CXXFLAGS="${CXXFLAGS:-"${CFLAGS}"}"
EOF
}

for p in "${profiles[@]}"; do
  profile_dir="${ADM_ROOT}/profiles/${p}"
  rootfs="${profile_dir}/rootfs"
  env_file="${profile_dir}/env.sh"

  echo "==> Profile: ${p}"
  mkdir -p "$profile_dir" "${ADM_ROOT}/db/${p}"
  create_rootfs_layout "$rootfs"

  if [ -f "$env_file" ] && [ "$FORCE" != "1" ]; then
    echo "  - Mantendo env.sh existente: ${env_file}"
  else
    echo "  - Criando env.sh: ${env_file}"
    case "$p" in
      bootstrap) write_env_bootstrap "$env_file" ;;
      glibc)     write_env_glibc "$env_file" ;;
      musl)      write_env_musl "$env_file" ;;
      *)         write_env_generic "$env_file" ;;
    esac
  fi

  echo "  - Rootfs: ${rootfs}"
  echo
done

cat <<EOF
Concluído.

Próximos passos típicos:
  1) ./adm.sh init
  2) ./adm.sh profile set bootstrap
  3) ./adm.sh install toolchain/linux-headers@6.17.9
  4) ./adm.sh install toolchain/binutils-bootstrap@2.45.1
  5) ./adm.sh install toolchain/gcc-bootstrap@15.2.0

Para recriar env.sh mesmo se já existir:
  FORCE=1 ${0} ${profiles[*]}
EOF
