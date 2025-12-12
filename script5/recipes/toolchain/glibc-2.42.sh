# /opt/adm/packages/toolchain/glibc-2.42.sh
#
# glibc 2.42 (instalação base no rootfs do profile atual)
# 100% compatível com adm.sh:
# - Receitas por categoria: packages/toolchain/glibc-2.42.sh
# - build() instala em DESTDIR=$PKG_BUILD_ROOT (adm empacota e extrai no rootfs)
# - Hook de sanity-check em post_install
#
# Requisitos externos típicos (host/build env): make, gcc, g++, binutils, bison, gawk, perl, python (dependendo do setup)
# Como o rootfs é separado por profile, recomenda-se instalar binutils-bootstrap + gcc-bootstrap no profile glibc antes.

PKG_NAME="glibc"
PKG_VERSION="2.42"
PKG_DESC="GNU C Library"
PKG_DEPENDS="linux-headers binutils-bootstrap gcc-bootstrap"
PKG_CATEGORY="toolchain"
PKG_LIBC="glibc"

build() {
    local url="https://ftp.gnu.org/gnu/glibc/glibc-${PKG_VERSION}.tar.xz"
    local tar="glibc-${PKG_VERSION}.tar.xz"
    local src

    src="$(fetch_source "$url" "$tar")"

    mkdir -p "$PKG_BUILD_WORK"
    cd "$PKG_BUILD_WORK"
    rm -rf "glibc-${PKG_VERSION}" build
    tar xf "$src"
    mkdir -p build
    cd build

    local sysroot="$PKG_ROOTFS"

    # Target: preferir LFS_TGT (bootstrap), senão inferir "nativo"
    local target="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"
    local build_triplet
    build_triplet="$("${PKG_BUILD_WORK}/glibc-${PKG_VERSION}/scripts/config.guess")"

    # PATH do profile já vem prefixado pelo adm.sh; reforçamos /tools/bin para toolchain bootstrap
    export PATH="${sysroot}/tools/bin:${PATH:-}"

    # Seleção de slibdir/rtlddir por arquitetura (loader geralmente em /lib ou /lib64)
    local slibdir="/lib"
    case "$(uname -m)" in
        x86_64|s390x|ppc64|ppc64le|aarch64)
            slibdir="/lib64"
            ;;
        *)
            slibdir="/lib"
            ;;
    esac

    # configparms direciona o local das libs "críticas" e loader
    # (mantém /usr/lib como libdir normal, mas slibdir vai para /lib*).
    echo "slibdir=${slibdir}" > configparms
    echo "rtlddir=${slibdir}" >> configparms

    # Configure glibc
    ../glibc-${PKG_VERSION}/configure \
        --prefix=/usr \
        --host="$target" \
        --build="$build_triplet" \
        --with-headers="${sysroot}/usr/include" \
        --disable-werror \
        --enable-kernel=3.2 \
        libc_cv_slibdir="$slibdir"

    # Build
    make

    # Install into DESTDIR for adm packaging
    make install DESTDIR="$PKG_BUILD_ROOT"

    # Opcional (mas útil): criar /etc/ld.so.conf padrão dentro do pacote
    # (vai para $PKG_ROOTFS/etc/ld.so.conf após instalar)
    mkdir -p "$PKG_BUILD_ROOT/etc"
    cat > "$PKG_BUILD_ROOT/etc/ld.so.conf" <<EOF
${slibdir}
/usr/lib
/usr/local/lib
EOF
}

pre_install() {
    echo "==> [glibc-${PKG_VERSION}] Instalando glibc no rootfs do profile via adm"
}

post_install() {
    echo "==> [glibc-${PKG_VERSION}] Sanity-check pós-instalação (glibc + loader + headers)"

    local sysroot="${PKG_ROOTFS:-$ADM_CURRENT_ROOTFS}"

    # 1) Verifica headers base
    if [ ! -f "${sysroot}/usr/include/gnu/libc-version.h" ]; then
        echo "ERRO: header gnu/libc-version.h não encontrado em ${sysroot}/usr/include (glibc install incompleto)."
        exit 1
    fi

    # 2) Verifica presença do libc compartilhado (pelo menos um caminho típico)
    local libc_ok=0
    if [ -f "${sysroot}/lib/libc.so.6" ] || [ -f "${sysroot}/lib64/libc.so.6" ]; then
        libc_ok=1
    fi
    if [ -f "${sysroot}/usr/lib/libc.so" ] || [ -f "${sysroot}/usr/lib/libc.so.6" ]; then
        libc_ok=1
    fi
    if [ "$libc_ok" -ne 1 ]; then
        echo "ERRO: libc não encontrada em caminhos esperados (${sysroot}/lib*, ${sysroot}/usr/lib)."
        exit 1
    fi

    # 3) Verifica loader (ld-linux*). Varia por arquitetura.
    local loader
    loader="$(find "${sysroot}/lib" "${sysroot}/lib64" -maxdepth 1 -type f -name 'ld-linux*.so*' 2>/dev/null | head -n1 || true)"
    if [ -z "$loader" ]; then
        # Algumas distros/arches usam ld.so* direto; tentamos alternativa
        loader="$(find "${sysroot}/lib" "${sysroot}/lib64" -maxdepth 1 -type f -name 'ld-*.so*' 2>/dev/null | head -n1 || true)"
    fi
    if [ -z "$loader" ]; then
        echo "ERRO: loader dinâmico (ld-linux/ld-*.so) não encontrado em ${sysroot}/lib ou ${sysroot}/lib64."
        exit 1
    fi

    # 4) Verifica que o toolchain do profile consegue compilar e linkar um binário simples contra a glibc do sysroot.
    # Preferimos ${LFS_TGT}-gcc (bootstrap), senão gcc.
    local target="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"
    local cc=""
    if command -v "${target}-gcc" >/dev/null 2>&1; then
        cc="${target}-gcc"
    elif command -v gcc >/dev/null 2>&1; then
        cc="gcc"
    else
        echo "ERRO: nenhum compilador encontrado (nem ${target}-gcc nem gcc) para sanity-check."
        exit 1
    fi

    local tdir
    tdir="$(mktemp -d)"
    local test_c="${tdir}/t.c"
    local test_bin="${tdir}/t"

    cat > "$test_c" <<'EOF'
#include <gnu/libc-version.h>
#include <stdio.h>
int main(void) {
    puts(gnu_get_libc_version());
    return 0;
}
EOF

    # Linka usando sysroot do profile (se for cross), e garante que gera binário.
    # Nota: não executamos dentro de chroot aqui; apenas validamos linkedição + interpreter via readelf.
    if ! "$cc" --sysroot="$sysroot" "$test_c" -o "$test_bin" >/dev/null 2>&1; then
        echo "ERRO: falha ao compilar/linkar programa de teste com sysroot=${sysroot}."
        rm -rf "$tdir"
        exit 1
    fi

    if command -v readelf >/dev/null 2>&1; then
        # Confere que há um INTERP e que aponta para /lib* (não para o host)
        local interp
        interp="$(readelf -l "$test_bin" 2>/dev/null | awk '/Requesting program interpreter/ {print $NF}' | tr -d '[]')"
        if [ -z "$interp" ]; then
            echo "ERRO: não foi possível extrair interpreter do binário de teste (readelf)."
            rm -rf "$tdir"
            exit 1
        fi
        case "$interp" in
            /lib/*|/lib64/*) : ;;
            *)
                echo "ERRO: interpreter inesperado no binário de teste: $interp"
                rm -rf "$tdir"
                exit 1
                ;;
        esac
    fi

    rm -rf "$tdir"

    echo "Sanity-check glibc ${PKG_VERSION}: OK (headers + libc + loader + linkedição via sysroot)."
}
