# /opt/adm/packages/toolchain/binutils-bootstrap-2.45.1.sh
#
# Binutils - Pass 1 (toolchain bootstrap)
# Compatível com adm.sh (categorias + profiles) e profile "bootstrap".
#
# Arquivo deve estar em:
#   $ADM_ROOT/packages/toolchain/binutils-bootstrap-2.45.1.sh
#
# PKG_NAME      = binutils-bootstrap
# PKG_VERSION   = 2.45.1
# PKG_CATEGORY  = toolchain
# PKG_DEPENDS   = linux-headers  (espera receita linux-headers-<versao>.sh)
#
# Esta receita instala o Binutils Pass 1 em /tools dentro do rootfs
# do profile atual, usando DESTDIR=$PKG_BUILD_ROOT (adm empacota e
# depois extrai tudo em $PKG_ROOTFS).

PKG_NAME="binutils-bootstrap"
PKG_VERSION="2.45.1"
PKG_DESC="Binutils - Pass 1 (bootstrap toolchain)"
PKG_DEPENDS="linux-headers"
PKG_CATEGORY="toolchain"
PKG_LIBC=""   # segue o profile atual (ex.: bootstrap)

build() {
    # URL oficial do Binutils
    local url="https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
    local tar="binutils-${PKG_VERSION}.tar.xz"
    local src

    # Baixa (ou usa o cache) via adm.sh
    src="$(fetch_source "$url" "$tar")"

    # Diretório de trabalho isolado para este pacote/versão
    mkdir -p "$PKG_BUILD_WORK"
    cd "$PKG_BUILD_WORK"
    rm -rf "binutils-${PKG_VERSION}" build
    tar xf "$src"
    mkdir -p build
    cd build

    # Target LFS para o toolchain de bootstrap
    # O profile "bootstrap" define LFS_TGT em env.sh, mas deixamos um default seguro.
    local target="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"

    # sysroot = rootfs do profile atual (ex.: /opt/adm/profiles/bootstrap/rootfs)
    local sysroot="$PKG_ROOTFS"

    # Garante que o toolchain do profile (se já existir algo em /tools) está no PATH
    export PATH="${sysroot}/tools/bin:${PATH:-}"

    # Configuração Pass 1 (bem próxima do LFS atual)
    ../binutils-${PKG_VERSION}/configure \
        --prefix=/tools \
        --with-sysroot="$sysroot" \
        --target="$target" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror \
        --disable-multilib

    # Compila Binutils
    make

    # IMPORTANTE:
    #   a instalação precisa ir para $PKG_BUILD_ROOT,
    #   porque o adm.sh empacota a partir desse rootfs temporário.
    make install DESTDIR="$PKG_BUILD_ROOT"
}

# Hook pós-build opcional (aqui só loga, sanity principal é pós-instalação)
post_build() {
    echo "==> [binutils-bootstrap-${PKG_VERSION}] Build concluído (Pass 1)."
}

# Hook pré-install (antes de extrair o tarball no rootfs do profile)
pre_install() {
    echo "==> [binutils-bootstrap-${PKG_VERSION}] Instalando em /tools dentro do rootfs do profile."
}

# Hook de sanity-check após instalação no rootfs.
# Aqui já temos:
#   - Binutils em $PKG_ROOTFS/tools/bin
#   - PATH prefixado pelo adm.sh com $ADM_CURRENT_ROOTFS/tools/bin
post_install() {
    echo "==> [binutils-bootstrap-${PKG_VERSION}] Sanity-check do Binutils Pass 1"

    local sysroot="${PKG_ROOTFS:-$ADM_CURRENT_ROOTFS}"
    local tools_bin="${sysroot}/tools/bin"

    # target padrão, usando LFS_TGT se definido pelo profile bootstrap/env.sh
    local target="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"

    # Caminhos esperados dos binários de target
    local target_ld="${tools_bin}/${target}-ld"
    local target_as="${tools_bin}/${target}-as"

    # 1) Verifica existência
    if [ ! -x "$target_ld" ]; then
        echo "ERRO: ${target_ld} não encontrado ou não é executável."
        exit 1
    fi
    if [ ! -x "$target_as" ]; then
        echo "ERRO: ${target_as} não encontrado ou não é executável."
        exit 1
    fi

    # 2) Verifica se estão no PATH (deve estar, pois adm.sh já ajustou PATH)
    if ! command -v "${target}-ld" >/dev/null 2>&1; then
        echo "ERRO: ${target}-ld não está no PATH após instalação."
        echo "PATH atual: $PATH"
        exit 1
    fi
    if ! command -v "${target}-as" >/dev/null 2>&1; then
        echo "ERRO: ${target}-as não está no PATH após instalação."
        echo "PATH atual: $PATH"
        exit 1
    fi

    # 3) 'as --version' e 'ld --version' como sanity mínimo
    echo "---- ${target}-as --version ----"
    if ! "${target}-as" --version >/dev/null 2>&1; then
        echo "ERRO: ${target}-as --version falhou."
        exit 1
    fi

    echo "---- ${target}-ld --version ----"
    if ! "${target}-ld" --version >/dev/null 2>&1; then
        echo "ERRO: ${target}-ld --version falhou."
        exit 1
    fi

    # 4) Opcional: cria um pequeno assembly e monta com o as do target
    local test_s="dummy-binutils-pass1.s"
    local test_o="dummy-binutils-pass1.o"

    cat > "$test_s" <<'EOF'
    .global _start
_start:
    .byte 0
EOF

    if ! "${target}-as" "$test_s" -o "$test_o"; then
        echo "ERRO: ${target}-as falhou ao montar dummy-binutils-pass1.s"
        rm -f "$test_s" "$test_o"
        exit 1
    fi

    echo "Sanity-check Binutils Pass 1 (${PKG_VERSION}) OK."
    rm -f "$test_s" "$test_o"
}
