# /opt/adm/packages/base/m4-1.4.20.sh
#
# GNU M4 1.4.20 - pacote base para o sistema
# Integração com o adm:
#   - usa cache de sources do adm
#   - instala em ${ADM_SYSROOT}/usr
#   - gera manifesto para uninstall
#   - hooks de sanity-check

PKG_NAME="m4"
PKG_VERSION="1.4.20"
PKG_CATEGORY="base"

# Fonte principal (tar.xz) – mirrors oficiais GNU
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/m4/m4-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/m4/m4-${PKG_VERSION}.tar.xz"
)

# Nome do tarball no cache do adm
PKG_TARBALL="m4-${PKG_VERSION}.tar.xz"

# SHA256 oficial do tarball m4-1.4.20.tar.xz
# (mesmo valor usado por Ubuntu, Homebrew, FreeBSD etc.) 
PKG_SHA256="e236ea3a1ccf5f6c270b1c4bb60726f371fa49459a8eaaebc90b216b328daf2b"

# Dependências lógicas (ajuste conforme os nomes exatos dos seus scripts)
PKG_DEPENDS=(
  "gcc-pass1"
  "binutils-pass1"
  # "glibc-pass1"    # ou "musl-pass1" se você quiser forçar a ordem
  # "libstdcxx-pass1"
)

# Nenhum patch necessário no momento
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Aqui você pode priorizar /usr/bin ou /tools/bin dependendo da fase.
    # Por padrão, só logamos o toolchain disponível.
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Construção simples estilo LFS (final system):
    #
    # Chapter 8 do LFS constrói m4 já no sistema chroot, usando o
    # toolchain “definitivo”. Aqui deixamos o configure simples,
    # sem --host, porque o adm já ajustou CC/CFLAGS conforme o profile.
    #
    ./configure \
        --prefix=/usr

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm depois sincroniza DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install
}

post_install() {
    # Sanity-check do M4:
    #  1) binário em ${ADM_SYSROOT}/usr/bin/m4
    #  2) versão correta
    #  3) macro simples funcionando

    local m4_bin="${ADM_SYSROOT}/usr/bin/m4"

    if [ ! -x "${m4_bin}" ]; then
        log_error "Sanity-check M4 falhou: ${m4_bin} não encontrado ou não executável."
        exit 1
    fi

    # Verificação de versão
    local ver
    ver="$("${m4_bin}" --version 2>/dev/null | head -n1 || true)"

    if ! printf '%s\n' "$ver" | grep -q "m4 (GNU M4) ${PKG_VERSION}"; then
        log_warn "Versão reportada pelo m4 não bate exatamente com ${PKG_VERSION}: '${ver}'"
    fi

    log_info "M4 versão reportada: ${ver}"

    # Teste simples de macro
    local out
    out="$(printf 'define(TEST,ok)\nTEST\n' | "${m4_bin}" 2>/dev/null || true)"
    if [ "$out" != "ok" ]; then
        log_error "Sanity-check M4 falhou: macro simples não funcionou (esperado 'ok', obtido '$out')."
        exit 1
    fi

    log_ok "Sanity-check M4 ${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
