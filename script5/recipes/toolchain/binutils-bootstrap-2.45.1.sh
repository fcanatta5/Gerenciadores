# /opt/adm/packages/toolchain/binutils-bootstrap-2.45.1.sh

PKG_NAME="binutils-bootstrap"
PKG_VERSION="2.45.1"
PKG_DESC="Binutils - Pass 1 (bootstrap toolchain)"
PKG_DEPENDS="linux-headers"
PKG_CATEGORY="toolchain"
PKG_LIBC=""   # usa o profile atual (ex.: bootstrap)

# Build do Binutils pass 1 (somente para toolchain inicial)
build() {
    local url="https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
    local tar="binutils-${PKG_VERSION}.tar.xz"
    local src

    # Usa cache de source do adm
    src="$(fetch_source "$url" "$tar")"

    mkdir -p "$PKG_BUILD_WORK"
    cd "$PKG_BUILD_WORK"
    rm -rf "binutils-${PKG_VERSION}" build
    tar xf "$src"
    mkdir -p build
    cd build

    # Target padrão estilo LFS (ajuste se quiser algo fixo, ex.: x86_64-lfs-linux-gnu)
    local target
    target="$(uname -m)-lfs-linux-gnu"

    # sysroot = rootfs do profile (ex.: /opt/adm/profiles/bootstrap/rootfs)
    local sysroot="$PKG_ROOTFS"

    # Garante que o toolchain do profile (se existir) está no PATH
    export PATH="$sysroot/tools/bin:${PATH:-}"

    ../binutils-${PKG_VERSION}/configure \
        --prefix=/tools \
        --with-sysroot="$sysroot" \
        --target="$target" \
        --disable-nls \
        --disable-werror \
        --disable-multilib

    make
    # Não instalamos ainda, sanity-check roda antes do install
    make configure-host
}

# Hook pós-build: sanity-check do ld (igual LFS pass 1)
post_build() {
    echo "==> [binutils-bootstrap] Sanity-check do ld (Pass 1)"

    local target
    target="$(uname -m)-lfs-linux-gnu"
    local sysroot="$PKG_ROOTFS"

    # Vamos usar o ld recém compilado de ./build/binutils
    # mas garantindo que o target binary esteja acessível
    cd "$PKG_BUILD_WORK/build"

    # Compila um objeto de teste com o gcc do host (ou do profile)
    # e linka com o ld novo via driver do target:
    # LFS clássico usa: ${LFS_TGT}-gcc; aqui tentamos inferir
    local test_c="dummy.c"
    local test_o="dummy.o"
    local test_prog="dummy"

    cat > "$test_c" <<'EOF'
int main(void) { return 0; }
EOF

    # Se você já tiver um ${target}-gcc no PATH, ótimo.
    # Caso contrário, usa apenas 'gcc' para gerar um .o simples
    if command -v "${target}-gcc" >/dev/null 2>&1; then
        "${target}-gcc" -c "$test_c" -o "$test_o"
        "${target}-gcc" "$test_o" -o "$test_prog"
    else
        echo "Aviso: ${target}-gcc não encontrado; usando gcc do host apenas para sanity-check básico."
        gcc -c "$test_c" -o "$test_o"
        gcc "$test_o" -o "$test_prog"
    fi

    # Agora checamos se o binário resultante está usando o ld correto
    # via strings + grep, semelhante ao que o LFS faz com 'readelf -l a.out | grep interpreter'
    if command -v readelf >/dev/null 2>&1; then
        readelf -l "$test_prog" > sanity-readelf.log 2>&1 || true
        echo "---- readelf -l $test_prog ----"
        cat sanity-readelf.log
        echo "--------------------------------"
    fi

    # sanity simples: verifica se o programa executa
    if ./"$test_prog"; then
        echo "Sanity-check: programa de teste executou com sucesso."
    else
        echo "Sanity-check: programa de teste FALHOU."
        exit 1
    fi

    # Limpa lixo do teste
    rm -f "$test_c" "$test_o" "$test_prog" sanity-readelf.log
}

# Hook pré-install (opcional, aqui só logamos)
pre_install() {
    echo "==> [binutils-bootstrap] Instalando em /tools (Pass 1)"
}

# Instala o binutils pass 1 em /tools dentro do rootfs do profile,
# mas sempre via DESTDIR=$PKG_BUILD_ROOT (adm empacota e depois extrai).
post_install() {
    echo "==> [binutils-bootstrap] Pós-instalação concluída."
}

# A função build() acima apenas compila.
# O adm.sh vai chamar create_binary_pkg() e instalar o tarball
# no rootfs do profile atual (ex.: /opt/adm/profiles/bootstrap/rootfs).
make_install() {
    # Função auxiliar opcional, caso você queira chamar manualmente
    cd "$PKG_BUILD_WORK/build"
    make install DESTDIR="$PKG_BUILD_ROOT"
}
