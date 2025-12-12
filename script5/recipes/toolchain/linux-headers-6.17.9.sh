# /opt/adm/packages/toolchain/linux-headers-6.17.9.sh
#
# Linux API Headers 6.17.9 (toolchain/bootstrap)
# 100% compatível com adm.sh (categorias + profiles) e alinhado ao binutils-bootstrap:
# - Instala headers em $PKG_ROOTFS/usr/include (via DESTDIR = $PKG_BUILD_ROOT)
# - Binutils Pass 1 usa --with-sysroot="$PKG_ROOTFS", então os headers devem ficar em:
#     $PKG_ROOTFS/usr/include
#
# Requer: make, tar, find, rm (coreutils) no host/build-env.

PKG_NAME="linux-headers"
PKG_VERSION="6.17.9"
PKG_DESC="Linux API headers for toolchain/bootstrap"
PKG_DEPENDS=""
PKG_CATEGORY="toolchain"
PKG_LIBC=""   # segue o profile atual

build() {
    local url="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
    local tar="linux-${PKG_VERSION}.tar.xz"
    local src

    src="$(fetch_source "$url" "$tar")"

    mkdir -p "$PKG_BUILD_WORK"
    cd "$PKG_BUILD_WORK"
    rm -rf "linux-${PKG_VERSION}"
    tar xf "$src"
    cd "linux-${PKG_VERSION}"

    # Limpa para garantir árvore consistente
    make mrproper

    # Gera headers de userspace
    make headers

    # Sanitiza (estilo LFS): remove arquivos ocultos e Makefile do include
    find usr/include -name '.*' -delete
    rm -f usr/include/Makefile

    # Instala no DESTDIR do pacote (adm vai empacotar e extrair no rootfs final)
    mkdir -p "$PKG_BUILD_ROOT/usr"
    cp -a usr/include "$PKG_BUILD_ROOT/usr/"
}

post_build() {
    echo "==> [linux-headers-${PKG_VERSION}] Sanity-check (pré-empacote)"

    local hdr_root="$PKG_BUILD_ROOT/usr/include"

    # 1) Diretório base
    if [ ! -d "$hdr_root" ]; then
        echo "ERRO: $hdr_root não existe (headers não foram instalados no DESTDIR)."
        exit 1
    fi

    # 2) Diretórios essenciais (precisam existir para toolchain)
    local d
    for d in linux asm asm-generic; do
        if [ ! -d "${hdr_root}/${d}" ]; then
            echo "ERRO: diretório esperado ausente: ${hdr_root}/${d}"
            exit 1
        fi
    done

    # 3) Headers essenciais (mínimo prático)
    local f
    for f in linux/types.h linux/errno.h linux/limits.h linux/ioctl.h; do
        if [ ! -f "${hdr_root}/${f}" ]; then
            echo "ERRO: header essencial ausente: ${hdr_root}/${f}"
            exit 1
        fi
    done

    # 4) Contagem mínima (evita cópia parcial)
    if command -v wc >/dev/null 2>&1; then
        local count
        count="$(find "$hdr_root" -type f | wc -l)"
        if [ "$count" -lt 200 ]; then
            echo "ERRO: poucos headers instalados ($count). 'make headers' pode ter falhado."
            exit 1
        fi
    fi

    echo "Sanity-check pré-empacote: OK."
}

pre_install() {
    echo "==> [linux-headers-${PKG_VERSION}] Instalando headers no rootfs do profile via adm"
}

post_install() {
    echo "==> [linux-headers-${PKG_VERSION}] Sanity-check (pós-instalação) alinhado ao binutils-bootstrap"

    # Após instalação, os headers devem estar no ROOTFS real:
    #   $PKG_ROOTFS/usr/include
    # Isso é o que o binutils-bootstrap (Pass 1) espera ao usar:
    #   --with-sysroot="$PKG_ROOTFS"
    local sysroot="${PKG_ROOTFS:-$ADM_CURRENT_ROOTFS}"
    local hdr_root="${sysroot}/usr/include"

    if [ ! -d "$hdr_root" ]; then
        echo "ERRO: $hdr_root não existe após instalação."
        exit 1
    fi

    # Checagem direta de alinhamento com binutils-bootstrap:
    # Binutils usa o sysroot para achar include em $sysroot/usr/include
    # então validamos arquivos críticos nesse caminho.
    local f
    for f in linux/types.h asm/errno.h asm-generic/errno-base.h; do
        if [ ! -f "${hdr_root}/${f}" ]; then
            echo "ERRO: header esperado ausente em sysroot (${hdr_root}/${f})."
            exit 1
        fi
    done

    echo "Sanity-check pós-instalação: headers presentes em ${sysroot}/usr/include (OK para binutils-bootstrap)."
}
