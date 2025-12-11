# /opt/adm/packages/toolchain/linux-headers-6.17.9.sh
#
# Linux API Headers 6.17.9 (para toolchain)
# Integração com adm.sh:
#   - Usa PKG_BUILD_ROOT como DESTDIR temporário
#   - adm.sh empacota e depois instala em $PKG_ROOTFS (rootfs do profile)
#   - Hook de sanity-check em post_build

PKG_NAME="linux-headers"
PKG_VERSION="6.17.9"
PKG_DESC="Linux API headers for toolchain/bootstrap"
PKG_DEPENDS=""
PKG_CATEGORY="toolchain"
PKG_LIBC=""    # usa o profile atual (ex.: bootstrap, glibc, musl)

build() {
    # Tarball do kernel (ajuste se você quiser usar mirror diferente)
    local url="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
    local tar="linux-${PKG_VERSION}.tar.xz"
    local src

    # Usa cache de source do adm (ADM_SRC_CACHE)
    src="$(fetch_source "$url" "$tar")"

    mkdir -p "$PKG_BUILD_WORK"
    cd "$PKG_BUILD_WORK"
    rm -rf "linux-${PKG_VERSION}"
    tar xf "$src"
    cd "linux-${PKG_VERSION}"

    # Limpa árvore, gera headers e "sanitize" igual LFS
    make mrproper

    # Gera headers de user-space
    make headers

    # Remove arquivos ocultos e Makefile dos headers
    find usr/include -name '.*' -delete
    rm -f usr/include/Makefile

    # Copia os headers gerados para o DESTDIR temporário do pacote
    mkdir -p "$PKG_BUILD_ROOT/usr"
    cp -rv usr/include "$PKG_BUILD_ROOT/usr/"
}

# Hook pós-build: sanity-check dos headers antes de empacotar
post_build() {
    echo "==> [linux-headers-${PKG_VERSION}] Sanity-check dos Linux API headers"

    local hdr_root="$PKG_BUILD_ROOT/usr/include"

    # 1) Diretório base precisa existir
    if [ ! -d "$hdr_root" ]; then
        echo "ERRO: diretório $hdr_root não foi criado."
        exit 1
    fi

    # 2) Alguns diretórios-chave que sempre deveriam existir
    local need_dirs="linux asm asm-generic"
    local d
    for d in $need_dirs; do
        if [ ! -d "${hdr_root}/${d}" ]; then
            echo "ERRO: diretório de headers esperado não encontrado: ${hdr_root}/${d}"
            exit 1
        fi
    done

    # 3) Verificar alguns headers importantes
    local need_files="
        linux/errno.h
        linux/limits.h
        linux/types.h
        linux/ioctl.h
    "
    local f
    for f in $need_files; do
        if [ ! -f "${hdr_root}/${f}" ]; then
            echo "ERRO: header essencial não encontrado: ${hdr_root}/${f}"
            exit 1
        fi
    done

    # 4) Checar se há uma quantidade razoável de headers
    # (evita caso de cópia parcial)
    if command -v find >/dev/null 2>&1 && command -v wc >/dev/null 2>&1; then
        local count
        count="$(find "$hdr_root" -type f | wc -l)"
        # Exigimos pelo menos 200 arquivos, valor bem baixo para qualquer kernel moderno
        if [ "$count" -lt 200 ]; then
            echo "ERRO: quantidade de headers muito baixa ($count arquivos). Algo deu errado no make headers."
            exit 1
        fi
    fi

    echo "Sanity-check Linux API headers 6.17.9: OK."
}

# Hooks opcionais (aqui apenas logam, o trabalho real já foi feito em build+post_build)
pre_install() {
    echo "==> [linux-headers-${PKG_VERSION}] Instalando headers no rootfs do profile via adm"
}

post_install() {
    echo "==> [linux-headers-${PKG_VERSION}] Pós-instalação concluída."
}
