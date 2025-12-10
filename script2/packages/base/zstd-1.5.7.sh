# /opt/adm/packages/base/zstd-1.5.7.sh
#
# Zstd-1.5.7 - utilitários e biblioteca de compressão Zstandard
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - constrói e instala em /usr do rootfs do profile (glibc/musl)
#   - fluxo típico:
#       make
#       make install PREFIX=/usr DESTDIR=${DESTDIR}
#   - adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
#   - hooks de sanity-check no rootfs (binário zstd funcional + libzstd.so)

PKG_NAME="zstd"
PKG_VERSION="1.5.7"
PKG_CATEGORY="base"

# Fontes oficiais (GitHub releases)
PKG_SOURCE_URLS=(
  "https://github.com/facebook/zstd/releases/download/v${PKG_VERSION}/zstd-${PKG_VERSION}.tar.gz"
  "https://github.com/facebook/zstd/archive/refs/tags/v${PKG_VERSION}.tar.gz"
)

PKG_TARBALL="zstd-${PKG_VERSION}.tar.gz"

# Preencha depois com o SHA256 oficial se quiser verificação rígida
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas mínimas
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
  "sed-4.9"
  "grep-3.12"
  "gawk-5.3.2"
  "make-4.4.1"
  "gcc-15.2.0"
)

PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# Se tiver patches locais:
# PKG_PATCHES=("/opt/adm/patches/zstd-1.5.7-fix-xyz.patch")

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    export LC_ALL=C

    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi

    if [ "${ADM_IN_CHROOT:-0}" != "1" ]; then
        log_warn "Zstd-${PKG_VERSION} idealmente deve ser construída dentro do chroot; profile=${ADM_PROFILE}, SYSROOT=${ADM_SYSROOT}."
    fi
}

build() {
    # Zstd usa um Makefile simples no diretório raiz:
    #
    #   make
    #
    # Isso constrói binários (zstd, zstdcat, unzstd) e bibliotecas (libzstd).
    # Suporte a PREFIX/DESTDIR é feito no 'make install'.

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
    make PREFIX=/usr DESTDIR="${DESTDIR}" install

    # Ajustar permissões das libs compartilhadas
    if [ -d "${DESTDIR}/usr/lib" ]; then
        find "${DESTDIR}/usr/lib" -maxdepth 1 -type f -name 'libzstd.so*' -exec chmod 0755 {} \; || true
    fi

    # Instalar documentação, se existir
    if [ -d "doc" ]; then
        install -v -d -m755 "${DESTDIR}/usr/share/doc/zstd-${PKG_VERSION}"
        cp -v doc/* "${DESTDIR}/usr/share/doc/zstd-${PKG_VERSION}" 2>/dev/null || true
    fi
}

post_install() {
    # Sanity-check Zstd dentro do rootfs do profile:
    #
    # 1) localizar /usr/bin/zstd (ou /bin/zstd)
    # 2) zstd --version
    # 3) comprimir e descomprimir um arquivo pequeno
    # 4) verificar libzstd.so* em /usr/lib
    # 5) (opcional) se estiver em chroot + gcc, compilar e linkar um teste com -lzstd

    local zstd_bin=""

    if [ -x "${ADM_SYSROOT}/usr/bin/zstd" ]; then
        zstd_bin="${ADM_SYSROOT}/usr/bin/zstd"
    elif [ -x "${ADM_SYSROOT}/bin/zstd" ]; then
        zstd_bin="${ADM_SYSROOT}/bin/zstd"
    else
        log_error "Sanity-check zstd falhou: zstd não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    local ver
    ver="$("${zstd_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check zstd falhou: não foi possível obter versão de ${zstd_bin}."
        exit 1
    fi
    log_info "zstd: zstd --version → ${ver}"

    # Teste de compressão/descompressão
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "teste-zstd" > "${tmpdir}/in.txt"

    if ! "${zstd_bin}" -q "${tmpdir}/in.txt" -o "${tmpdir}/in.txt.zst" >/dev/null 2>&1; then
        log_error "Sanity-check zstd falhou: não conseguiu comprimir in.txt."
        rm -rf "${tmpdir}"
        exit 1
    fi

    if [ ! -f "${tmpdir}/in.txt.zst" ]; then
        log_error "Sanity-check zstd falhou: arquivo in.txt.zst não foi gerado."
        rm -rf "${tmpdir}"
        exit 1
    fi

    if ! "${zstd_bin}" -q -d "${tmpdir}/in.txt.zst" -o "${tmpdir}/out.txt" >/dev/null 2>&1; then
        log_error "Sanity-check zstd falhou: não conseguiu descomprimir in.txt.zst."
        rm -rf "${tmpdir}"
        exit 1
    fi

    local original decompressed
    original="$(cat "${tmpdir}/in.txt")"
    decompressed="$(cat "${tmpdir}/out.txt" 2>/dev/null || true)"

    if [ "${original}" != "${decompressed}" ]; then
        log_error "Sanity-check zstd falhou: conteúdo descomprimido difere do original."
        rm -rf "${tmpdir}"
        exit 1
    fi

    rm -rf "${tmpdir}"
    log_info "zstd: compressão/descompressão de teste OK."

    # Verificar libzstd.so em /usr/lib
    local libdir="${ADM_SYSROOT}/usr/lib"
    local have_lib=0
    if [ -d "${libdir}" ]; then
        if find "${libdir}" -maxdepth 1 -name 'libzstd.so*' | head -n1 >/dev/null 2>&1; then
            have_lib=1
        fi
    fi

    if [ "${have_lib}" -ne 1 ]; then
        log_error "Sanity-check zstd falhou: libzstd.so* não encontrada em ${libdir}."
        exit 1
    fi

    # Teste extra: só se estivermos em chroot e com gcc disponível
    if [ "${ADM_IN_CHROOT:-0}" = "1" ] && command -v gcc >/dev/null 2>&1; then
        local tmpc
        tmpc="$(mktemp -d)"

        cat > "${tmpc}/zstdtest.c" << 'EOF'
#include <stdio.h>
#include <string.h>
#include <zstd.h>

int main(void) {
    const char* src = "hello-zstd";
    size_t srcSize = strlen(src);
    char cbuf[128];
    char dbuf[128];

    size_t cSize = ZSTD_compress(cbuf, sizeof(cbuf), src, srcSize, 1);
    if (ZSTD_isError(cSize)) return 1;

    size_t dSize = ZSTD_decompress(dbuf, sizeof(dbuf), cbuf, cSize);
    if (ZSTD_isError(dSize)) return 2;

    dbuf[dSize] = '\0';
    if (strcmp(src, dbuf) != 0) return 3;

    printf("ok-zstd-lib\n");
    return 0;
}
EOF

        if gcc -o "${tmpc}/zstdtest" "${tmpc}/zstdtest.c" -lzstd >/dev/null 2>&1; then
            local out
            out="$("${tmpc}/zstdtest" 2>/dev/null || true)"
            if [ "${out}" != "ok-zstd-lib" ]; then
                log_warn "zstd: teste de link com -lzstd não retornou 'ok-zstd-lib' (saída='${out}')."
            else
                log_info "zstd: programa de teste linkado com -lzstd executado com sucesso."
            fi
        else
            log_warn "zstd: gcc não conseguiu linkar programa de teste com -lzstd; verifique toolchain."
        fi

        rm -rf "${tmpc}"
    else
        log_warn "zstd: teste de linkagem com -lzstd não realizado (ADM_IN_CHROOT!=1 ou gcc ausente)."
    fi

    log_ok "Sanity-check zstd-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
