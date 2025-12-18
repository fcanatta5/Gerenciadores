#!/usr/bin/env bash

###############################################################################
# Cross Toolchain Temporário x86_64-musl
# Local: /mnt/adm/tools
# Foco: simplicidade, robustez e correção de problemas conhecidos
###############################################################################

set -euo pipefail

###############################################################################
# CONFIGURAÇÃO CENTRALIZADA (manutenção simples)
###############################################################################

TARGET="x86_64-linux-musl"
TOOLS="/mnt/adm/tools"
BUILD="/mnt/adm/build"
SRC="/mnt/adm/sources"

BINUTILS_VER="2.42"
GCC_VER="13.2.0"
MUSL_VER="1.2.5"
LINUX_HEADERS_VER="6.6.8"

MAKEFLAGS="-j$(nproc)"

###############################################################################
# FUNÇÕES UTILITÁRIAS
###############################################################################

msg() {
    echo -e "\n\033[1;32m==> $*\033[0m\n"
}

die() {
    echo -e "\n\033[1;31mERRO: $*\033[0m\n"
    exit 1
}

cleanup_build() {
    rm -rf "$BUILD"
    mkdir -p "$BUILD"
}

###############################################################################
# PREPARAÇÃO DO AMBIENTE
###############################################################################

msg "Preparando diretórios"
mkdir -p "$TOOLS" "$BUILD" "$SRC"

msg "Exportando variáveis do toolchain"
export PATH="$TOOLS/bin:$PATH"
export LC_ALL=POSIX
export CONFIG_SITE=/dev/null

###############################################################################
# VERIFICAÇÕES BÁSICAS
###############################################################################

command -v gcc >/dev/null || die "gcc do host não encontrado"
command -v make >/dev/null || die "make não encontrado"

###############################################################################
# BINUTILS – PASSO 1
###############################################################################

msg "Construindo Binutils ${BINUTILS_VER}"

cleanup_build
tar -xf "$SRC/binutils-${BINUTILS_VER}.tar.xz" -C "$BUILD"
mkdir -v "$BUILD/binutils-build"
cd "$BUILD/binutils-build"

"$BUILD/binutils-${BINUTILS_VER}/configure" \
    --prefix="$TOOLS" \
    --target="$TARGET" \
    --with-sysroot \
    --disable-nls \
    --disable-werror

make $MAKEFLAGS
make install

###############################################################################
# HEADERS DO KERNEL (mínimos)
###############################################################################

msg "Instalando Linux Headers ${LINUX_HEADERS_VER}"

cleanup_build
tar -xf "$SRC/linux-${LINUX_HEADERS_VER}.tar.xz" -C "$BUILD"
cd "$BUILD/linux-${LINUX_HEADERS_VER}"

make mrproper
make headers
find usr/include -type f ! -name '*.h' -delete
cp -rv usr/include "$TOOLS/$TARGET"

###############################################################################
# MUSL – HEADERS + CRT
###############################################################################

msg "Instalando headers e CRT do musl ${MUSL_VER}"

cleanup_build
tar -xf "$SRC/musl-${MUSL_VER}.tar.gz" -C "$BUILD"
cd "$BUILD/musl-${MUSL_VER}"

./configure \
    --prefix="/usr" \
    --target="$TARGET"

make install-headers DESTDIR="$TOOLS/$TARGET"
make install-crt DESTDIR="$TOOLS/$TARGET"

###############################################################################
# GCC – PASSO 1 (somente compilador + libgcc)
###############################################################################

msg "Construindo GCC ${GCC_VER} (passo 1)"

cleanup_build
tar -xf "$SRC/gcc-${GCC_VER}.tar.xz" -C "$BUILD"
cd "$BUILD/gcc-${GCC_VER}"

./contrib/download_prerequisites

mkdir -v "$BUILD/gcc-build"
cd "$BUILD/gcc-build"

"$BUILD/gcc-${GCC_VER}/configure" \
    --target="$TARGET" \
    --prefix="$TOOLS" \
    --with-sysroot="$TOOLS/$TARGET" \
    --disable-nls \
    --disable-multilib \
    --disable-libsanitizer \
    --disable-libquadmath \
    --disable-libssp \
    --disable-libvtv \
    --enable-languages=c

make $MAKEFLAGS all-gcc
make $MAKEFLAGS all-target-libgcc
make install-gcc
make install-target-libgcc

###############################################################################
# MUSL – BIBLIOTECA COMPLETA
###############################################################################

msg "Construindo musl completo"

cleanup_build
tar -xf "$SRC/musl-${MUSL_VER}.tar.gz" -C "$BUILD"
cd "$BUILD/musl-${MUSL_VER}"

CC="$TARGET-gcc" \
./configure \
    --prefix="/usr"

make $MAKEFLAGS
make install DESTDIR="$TOOLS/$TARGET"

###############################################################################
# TESTE DO TOOLCHAIN
###############################################################################

msg "Validando o cross-toolchain"

cat > "$BUILD/test.c" << 'EOF'
int main(void) { return 0; }
EOF

"$TARGET-gcc" "$BUILD/test.c" -o "$BUILD/test-bin"

readelf -l "$BUILD/test-bin" | grep interpreter \
    || die "Linker dinâmico não configurado corretamente"

msg "Toolchain funcional e validado com sucesso"

###############################################################################
# FINALIZAÇÃO
###############################################################################

msg "Cross-toolchain temporário concluído em $TOOLS"
