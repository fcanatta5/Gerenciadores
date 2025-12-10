# /opt/adm/packages/base/glibc-2.42.sh
#
# Glibc-2.42 - biblioteca C GNU (fase final, não pass1)
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - constrói em /usr do rootfs do profile glibc/glibc-opt
#   - fluxo baseado em LFS, adaptado ao adm:
#       mkdir build
#       cd build
#       ../configure --prefix=/usr --libdir=/usr/lib \
#                    --sysconfdir=/etc \
#                    --enable-kernel=4.19 \
#                    --enable-stack-protector=strong \
#                    --enable-bind-now \
#                    --with-headers=${ADM_SYSROOT}/usr/include \
#                    --build=... --host=${ADM_TARGET}
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs (libc.so.6, ld.so, ldd, nsswitch.conf)

PKG_NAME="glibc"
PKG_VERSION="2.42"
PKG_CATEGORY="base"

# Fontes oficiais (GNU)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/libc/glibc-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/libc/glibc-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="glibc-${PKG_VERSION}.tar.xz"

# Preencha com o SHA256 oficial quando quiser travar checksum.
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas (ajuste nomes para bater exatamente com os seus scripts)
PKG_DEPENDS=(
  "linux-6.17.9-api-headers"
  "glibc-2.42-pass1"
  "binutils-2.45.1"
  "gcc-15.2.0"
  "bash-5.3"
  "coreutils-9.9"
  "gawk-5.3.2"
  "make-4.4.1"
)

PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# Se tiver patches locais (por exemplo correções de segurança):
# PKG_PATCHES=("/opt/adm/patches/glibc-2.42-something.patch")

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Glibc só faz sentido em profiles baseados em glibc
    case "${ADM_PROFILE}" in
        glibc|glibc-opt)
            ;;
        *)
            log_error "Este pacote glibc-${PKG_VERSION} só deve ser construído em profiles glibc/glibc-opt (profile atual: ${ADM_PROFILE})."
            exit 1
            ;;
    esac

    export LC_ALL=C

    local headers_dir="${ADM_SYSROOT}/usr/include"
    if [ ! -d "${headers_dir}" ]; then
        log_error "Headers do kernel não encontrados em ${headers_dir}. Construa e instale linux-*-api-headers primeiro."
        exit 1
    fi

    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Build recomendado: diretório separado "build"
    #
    #   mkdir build
    #   cd build
    #   ../configure --prefix=/usr \
    #                --libdir=/usr/lib \
    #                --sysconfdir=/etc \
    #                --enable-kernel=4.19 \
    #                --enable-stack-protector=strong \
    #                --enable-bind-now \
    #                --with-headers=${ADM_SYSROOT}/usr/include \
    #                --build=$(../scripts/config.guess) \
    #                --host=${ADM_TARGET}
    #   make
    #
    # Em chroot: build == host == target; fora do chroot é mais sensível,
    # mas mantemos o mesmo esquema.

    mkdir -pv build
    cd build

    local build_triplet
    if [ -x "../scripts/config.guess" ]; then
        build_triplet="$("../scripts/config.guess")"
    elif [ -x "../config.guess" ]; then
        build_triplet="$("../config.guess")"
    else
        build_triplet="$(uname -m)-unknown-linux-gnu"
    fi

    ../configure \
        --prefix=/usr \
        --libdir=/usr/lib \
        --sysconfdir=/etc \
        --enable-kernel=4.19 \
        --enable-stack-protector=strong \
        --enable-bind-now \
        --with-headers="${ADM_SYSROOT}/usr/include" \
        --build="${build_triplet}" \
        --host="${ADM_TARGET}" \
        --disable-werror

    make
}

install_pkg() {
    # Estamos dentro de $srcdir; glibc foi compilado em build/
    cd build

    # Instala em DESTDIR; o adm sincroniza depois DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Instalar locale opcionalmente aqui se o usuário quiser (geralmente
    # é feito depois com localedef). Mantemos apenas a instalação padrão.
}

post_install() {
    # Ajustes básicos e sanity-check da glibc dentro do rootfs do profile.

    # 1) Garantir nsswitch.conf mínimo se não existir
    local nss="${ADM_SYSROOT}/etc/nsswitch.conf"
    if [ ! -f "${nss}" ]; then
        log_info "Criando /etc/nsswitch.conf padrão em ${ADM_SYSROOT}."
        cat > "${nss}" << 'EOF'
# /etc/nsswitch.conf padrão (gerado pelo adm)
passwd: files
group:  files
shadow: files

hosts:  files dns
networks: files

protocols: files
services:  files
ethers:   files
rpc:      files
EOF
    fi

    # 2) ld.so.conf básico (se não existir)
    local ldconf="${ADM_SYSROOT}/etc/ld.so.conf"
    if [ ! -f "${ldconf}" ]; then
        log_info "Criando /etc/ld.so.conf padrão em ${ADM_SYSROOT}."
        cat > "${ldconf}" << 'EOF'
# /etc/ld.so.conf padrão (gerado pelo adm)
/usr/local/lib
/opt/lib
EOF
    fi

    # 3) Verificações de arquivos principais
    local libc_so="${ADM_SYSROOT}/usr/lib/libc.so.6"
    local loader1="${ADM_SYSROOT}/lib/ld-linux-x86-64.so.2"
    local loader2="${ADM_SYSROOT}/lib64/ld-linux-x86-64.so.2"
    local ldd_bin="${ADM_SYSROOT}/usr/bin/ldd"

    local fail=0

    if [ ! -e "${libc_so}" ]; then
        log_error "Sanity-check glibc falhou: ${libc_so} não existe."
        fail=1
    fi

    if [ ! -e "${loader1}" ] && [ ! -e "${loader2}" ]; then
        log_error "Sanity-check glibc falhou: loader dinâmico não encontrado (${loader1} nem ${loader2})."
        fail=1
    fi

    if [ ! -x "${ldd_bin}" ]; then
        log_error "Sanity-check glibc falhou: ${ldd_bin} não é executável."
        fail=1
    fi

    if [ "${fail}" -ne 0 ]; then
        log_error "Sanity-check glibc-${PKG_VERSION} falhou nos arquivos principais."
        exit 1
    fi

    # 4) Testes adicionais se estivermos realmente dentro de um chroot glibc
    if [ "${ADM_IN_CHROOT:-0}" = "1" ]; then
        # Dentro do chroot, o sysroot é /, então podemos chamar ldd diretamente.
        local ldd_ver
        ldd_ver="$(/usr/bin/ldd --version 2>/dev/null | head -n1 || true)"
        if [ -z "${ldd_ver}" ]; then
            log_error "Sanity-check glibc falhou: ldd --version não retornou saída válida dentro do chroot."
            exit 1
        fi
        log_info "glibc: ldd --version → ${ldd_ver}"

        # Opcional: compilar e rodar um hello world simples.
        # Supõe que gcc já esteja funcional dentro do chroot.
        if command -v gcc >/dev/null 2>&1; then
            local tmpdir
            tmpdir="$(mktemp -d)"
            cat > "${tmpdir}/hello.c" << 'EOF'
#include <stdio.h>
int main(void) {
    printf("hello-glibc\n");
    return 0;
}
EOF
            if gcc -o "${tmpdir}/hello" "${tmpdir}/hello.c" >/dev/null 2>&1; then
                local out
                out="$("${tmpdir}/hello" 2>/dev/null || true)"
                if [ "$out" != "hello-glibc" ]; then
                    log_error "Sanity-check glibc falhou: programa de teste não retornou 'hello-glibc'. Saída: '$out'"
                    rm -rf "${tmpdir}"
                    exit 1
                fi
                log_info "glibc: programa de teste 'hello-glibc' executado com sucesso."
            else
                log_warn "glibc: gcc não conseguiu compilar programa de teste; verifique toolchain."
            fi
            rm -rf "${tmpdir}"
        else
            log_warn "glibc: gcc não encontrado dentro do chroot para teste extra."
        fi
    else
        log_warn "Sanity-check glibc: ADM_IN_CHROOT != 1, testes foram apenas de presença de arquivos (sem execução)."
    fi

    log_ok "Sanity-check glibc-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
