# /opt/adm/packages/base/musl-1.2.5.sh
#
# musl-1.2.5 - libc alternativa (final, não pass1), para perfis musl/musl-opt
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - usa PKG_PATCH_URLS com 2 patches de segurança (baixados pelo adm)
#   - constrói em /usr do rootfs do profile (musl ou musl-opt)
#   - fluxo:
#       mkdir build
#       cd build
#       ../configure --prefix=/usr
#       make
#       make DESTDIR=${DESTDIR} install
#       criar /lib/ld-musl-<arch>.so.1 apontando para /usr/lib/ld-musl-<arch>.so.1
#   - adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
#   - hooks de sanity-check no rootfs (loader dinâmico + hello world)

PKG_NAME="musl"
PKG_VERSION="1.2.5"
PKG_CATEGORY="base"

# Fontes oficiais
PKG_SOURCE_URLS=(
  "https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"
  "https://musl.libc.org/releases/old/musl-${PKG_VERSION}.tar.gz"
)

PKG_TARBALL="musl-${PKG_VERSION}.tar.gz"

# Preencha depois com o SHA256 oficial se quiser verificação rígida
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas (ajuste os nomes para bater com os seus scripts)
PKG_DEPENDS=(
  "linux-6.17.9-api-headers"
  "musl-1.2.5-pass1"
  "binutils-2.45.1"
  "gcc-15.2.0"
  "bash-5.3"
  "coreutils-9.9"
  "gawk-5.3.2"
  "make-4.4.1"
)

# --------------------------------------------------------------------
# 2 patches de segurança
#   - Troque as URLs abaixo pelas URLs REAIS dos patches de segurança
#     que você deseja aplicar (por exemplo, patches oficiais de CVEs).
#   - Opcionalmente, preencha PKG_PATCH_SHA256 com os checksums corretos.
# --------------------------------------------------------------------
PKG_PATCH_URLS=(
  "https://example.invalid/musl-1.2.5-security-fix-1.patch"
  "https://example.invalid/musl-1.2.5-security-fix-2.patch"
)

# mesma ordem de PKG_PATCH_URLS (pode deixar vazio se não quiser verificar)
PKG_PATCH_SHA256=(
  ""
  ""
)

PKG_PATCH_MD5=()

# Se quiser usar patches locais em vez de baixar:
# PKG_PATCHES=(
#   "/opt/adm/patches/musl-1.2.5-security-fix-1.patch"
#   "/opt/adm/patches/musl-1.2.5-security-fix-2.patch"
# )

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    export LC_ALL=C

    # Só faz sentido em perfis musl
    case "${ADM_PROFILE}" in
        musl|musl-opt)
            ;;
        *)
            log_error "musl-${PKG_VERSION} final só deve ser construído em profiles musl/musl-opt (profile atual: ${ADM_PROFILE})."
            exit 1
            ;;
    esac

    # Garantir headers do kernel instalados no SYSROOT
    local headers_dir="${ADM_SYSROOT}/usr/include"
    if [ ! -d "${headers_dir}" ] || [ ! -d "${headers_dir}/linux" ]; then
        log_error "Headers do kernel não encontrados em ${headers_dir}/linux. Construa linux-*-api-headers primeiro."
        exit 1
    fi

    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi

    if [ "${ADM_IN_CHROOT:-0}" != "1" ]; then
        log_warn "musl-${PKG_VERSION} final idealmente deve ser construída dentro do chroot (ADM_IN_CHROOT!=1)."
    fi
}

build() {
    # Build em diretório separado (recomendado)
    #
    #   mkdir build
    #   cd build
    #   ../configure --prefix=/usr
    #   make
    #
    # Não usamos options exóticas para evitar problemas em versões futuras.
    # O prefix=/usr fará a instalação em /usr/lib (libc.so, ld-musl-*.so.1);
    # o loader em /lib será ajustado no post_install.

    mkdir -pv build
    cd build

    ../configure \
        --prefix=/usr

    make
}

install_pkg() {
    # Estamos em build/
    cd build

    # Instala dentro de DESTDIR; o adm faz o sync para ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Criar o loader dinâmico em /lib, apontando para /usr/lib/ld-musl-<arch>.so.1
    #   - musl instala por padrão /usr/lib/libc.so e /usr/lib/ld-musl-<arch>.so.1
    #   - o ELF interpreter precisa de /lib/ld-musl-<arch>.so.1

    local arch
    arch="${ADM_TARGET%%-*}"
    [ -z "${arch}" ] && arch="$(uname -m)"

    local dest_usr_lib="${DESTDIR}/usr/lib"
    local dest_lib="${DESTDIR}/lib"

    mkdir -pv "${dest_lib}"

    local loader_usr="${dest_usr_lib}/ld-musl-${arch}.so.1"
    local loader_lib="${dest_lib}/ld-musl-${arch}.so.1"

    if [ ! -e "${loader_usr}" ]; then
        log_warn "musl: loader ${loader_usr} não encontrado após instalação; verifique layout de instalação."
    else
        ln -svf "../usr/lib/ld-musl-${arch}.so.1" "${loader_lib}"
    fi

    # Opcional: alguns sistemas também criam um symlink libc.musl-<arch>.so.1
    # apontando para o loader em /lib.
    if [ -e "${loader_lib}" ]; then
        ln -svf "ld-musl-${arch}.so.1" "${dest_lib}/libc.musl-${arch}.so.1"
    fi
}

post_install() {
    # Sanity-check musl dentro do rootfs do profile:
    #
    # 1) verificar se /lib/ld-musl-<arch>.so.1 existe no SYSROOT
    # 2) verificar se /usr/lib/libc.so existe
    # 3) se estiver em chroot e gcc disponível, compilar e rodar um hello world

    local arch
    arch="${ADM_TARGET%%-*}"
    [ -z "${arch}" ] && arch="$(uname -m)"

    local loader_sys="${ADM_SYSROOT}/lib/ld-musl-${arch}.so.1"
    local libc_sys="${ADM_SYSROOT}/usr/lib/libc.so"

    local fail=0

    if [ ! -e "${loader_sys}" ]; then
        log_error "Sanity-check musl falhou: loader dinâmico ${loader_sys} não existe."
        fail=1
    fi

    if [ ! -e "${libc_sys}" ]; then
        log_error "Sanity-check musl falhou: libc.so não encontrada em ${libc_sys}."
        fail=1
    fi

    if [ "${fail}" -ne 0 ]; then
        log_error "Sanity-check musl-${PKG_VERSION} falhou nos arquivos principais."
        exit 1
    fi

    # Teste extra: se estivermos dentro do chroot musl e houver gcc, compilar hello world
    if [ "${ADM_IN_CHROOT:-0}" = "1" ] && command -v gcc >/dev/null 2>&1; then
        local tmpdir
        tmpdir="$(mktemp -d)"

        cat > "${tmpdir}/hello-musl.c" << 'EOF'
#include <stdio.h>
int main(void) {
    printf("hello-musl\n");
    return 0;
}
EOF

        if gcc -o "${tmpdir}/hello-musl" "${tmpdir}/hello-musl.c" >/dev/null 2>&1; then
            local out
            out="$("${tmpdir}/hello-musl" 2>/dev/null || true)"
            if [ "${out}" != "hello-musl" ]; then
                log_error "Sanity-check musl falhou: programa de teste não retornou 'hello-musl'. Saída: '${out}'"
                rm -rf "${tmpdir}"
                exit 1
            fi
            log_info "musl: programa de teste 'hello-musl' compilado e executado com sucesso."
        else
            log_warn "musl: gcc não conseguiu compilar programa de teste; verifique se o toolchain musl está funcional."
        fi

        rm -rf "${tmpdir}"
    else
        log_warn "musl: teste de execução não realizado (ADM_IN_CHROOT!=1 ou gcc ausente)."
    fi

    log_ok "Sanity-check musl-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
