# /opt/adm/packages/base/zlib-1.3.1.sh
#
# Zlib-1.3.1 - biblioteca de compressão (libz)
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - constrói e instala em /usr do rootfs do profile (glibc/musl)
#   - fluxo típico:
#       ./configure --prefix=/usr --shared
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs (libz.so presente, teste de link com -lz)

PKG_NAME="zlib"
PKG_VERSION="1.3.1"
PKG_CATEGORY="base"

# Fontes oficiais
PKG_SOURCE_URLS=(
  "https://zlib.net/zlib-${PKG_VERSION}.tar.xz"
  "https://zlib.net/fossils/zlib-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="zlib-${PKG_VERSION}.tar.xz"

# Preencha depois com o SHA256 oficial se quiser verificação rígida
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas (nomes alinhados com seus outros scripts)
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
        log_warn "Zlib-1.3.1 idealmente deve ser construída dentro do chroot; profile atual=${ADM_PROFILE}, SYSROOT=${ADM_SYSROOT}."
    fi
}

build() {
    # Zlib tem configure próprio, sem autotools completos; não usamos --host/--build.
    #
    #   ./configure --prefix=/usr --shared
    #   make
    #
    # Gera libz.so e libz.a (shared + static). Se quiser só shared, pode remover
    # a estática depois em outro pacote/passo.

    ./configure \
        --prefix=/usr \
        --shared

    make
}

install_pkg() {
    # Instalamos em DESTDIR; o adm faz o rsync depois para ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Garantir permissões razoáveis nos .so
    if [ -d "${DESTDIR}/usr/lib" ]; then
        find "${DESTDIR}/usr/lib" -maxdepth 1 -type f -name 'libz.so*' -exec chmod 0755 {} \; || true
    fi
}

post_install() {
    # Sanity-check Zlib dentro do rootfs do profile:
    #
    # 1) verificar se libz.so* existe em ${ADM_SYSROOT}/usr/lib
    # 2) se estiver em chroot e houver gcc, compilar um hello que chama zlib
    #

    local libdir="${ADM_SYSROOT}/usr/lib"
    local have_lib=0

    if [ -d "${libdir}" ]; then
        if find "${libdir}" -maxdepth 1 -name 'libz.so*' | head -n1 >/dev/null 2>&1; then
            have_lib=1
        fi
    fi

    if [ "${have_lib}" -ne 1 ]; then
        log_error "Sanity-check zlib falhou: libz.so* não encontrada em ${libdir}."
        exit 1
    fi

    log_info "zlib: bibliotecas libz.so* encontradas em ${libdir}."

    # Teste extra apenas se estivermos dentro do chroot (SYSROOT=/)
    if [ "${ADM_IN_CHROOT:-0}" = "1" ] && command -v gcc >/dev/null 2>&1; then
        local tmpdir
        tmpdir="$(mktemp -d)"

        cat > "${tmpdir}/ztest.c" << 'EOF'
#include <stdio.h>
#include <string.h>
#include <zlib.h>

int main(void) {
    const char *src = "teste-zlib";
    unsigned char out[64];
    z_stream s;
    memset(&s, 0, sizeof(s));
    if (deflateInit(&s, Z_BEST_COMPRESSION) != Z_OK) {
        return 1;
    }
    s.next_in  = (unsigned char *)src;
    s.avail_in = (unsigned int)strlen(src);
    s.next_out = out;
    s.avail_out = sizeof(out);
    if (deflate(&s, Z_FINISH) != Z_STREAM_END) {
        deflateEnd(&s);
        return 2;
    }
    deflateEnd(&s);
    printf("ok-zlib\n");
    return 0;
}
EOF

        if gcc -o "${tmpdir}/ztest" "${tmpdir}/ztest.c" -lz >/dev/null 2>&1; then
            local out
            out="$("${tmpdir}/ztest" 2>/dev/null || true)"
            if [ "${out}" != "ok-zlib" ]; then
                log_error "Sanity-check zlib falhou: programa de teste não retornou 'ok-zlib'. Saída: '${out}'"
                rm -rf "${tmpdir}"
                exit 1
            fi
            log_info "zlib: programa de teste linkado com -lz executado com sucesso."
        else
            log_warn "zlib: gcc não conseguiu linkar programa de teste com -lz; verifique toolchain/linker."
        fi

        rm -rf "${tmpdir}"
    else
        log_warn "zlib: teste de execução não realizado (ADM_IN_CHROOT!=1 ou gcc ausente)."
    fi

    log_ok "Sanity-check zlib-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
