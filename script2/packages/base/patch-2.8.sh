# /opt/adm/packages/base/patch-2.8.sh
#
# Patch-2.8 - utilitário GNU patch
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - compila com ./configure --prefix=/usr --host=$ADM_TARGET --build=$(config.guess)
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs (aplica um patch simples de teste)
#
# Versão: 2.8 (lançada em 29/03/2025) 

PKG_NAME="patch"
PKG_VERSION="2.8"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors) 
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/patch/patch-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/gnu/patch/patch-${PKG_VERSION}.tar.xz"
  "https://ftp.unicamp.br/pub/gnu/patch/patch-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="patch-${PKG_VERSION}.tar.xz"

# SHA256 do patch-2.8.tar.xz (do anúncio oficial info-gnu) 
PKG_SHA256="f87cee69eec2b4fcbf60a396b030ad6aa3415f192aa5f7ee84cad5e11f7f5ae3"

# Dependências lógicas (nomes conforme o seu tree de pacotes)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
)

# Nenhum patch externo necessário aqui
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Deixar ambiente previsível
    export LC_ALL=C

    # Log informativo sobre toolchain disponível
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional encontrado em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi
}

build() {
    # Build padrão estilo LFS, adaptado para o esquema de profiles do adm.
    #
    #   ./configure --prefix=/usr \
    #               --host=$LFS_TGT \
    #               --build=$(config.guess)
    #   make
    #
    # Aqui:
    #   LFS_TGT  -> ADM_TARGET
    #   DESTDIR  -> gerenciado pelo adm (rsync depois para ADM_SYSROOT)
    #
    # 2.8 é bem recente, mas o fluxo continua simples. 

    local build_triplet

    if [ -x "./build-aux/config.guess" ]; then
        build_triplet="$(./build-aux/config.guess)"
    else
        build_triplet="$(./config.guess)"
    fi

    ./configure \
        --prefix=/usr \
        --host="${ADM_TARGET}" \
        --build="${build_triplet}"

    make
}

install_pkg() {
    # Instala tudo em DESTDIR; o adm faz o sync depois para ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Não há ajustes FHS específicos para o patch.
    # Se precisar de algo especial (ex.: mover para /bin), este é o lugar.
}

post_install() {
    # Sanity-check do Patch-2.8 dentro do rootfs do profile:
    #
    # 1) localizar /usr/bin/patch (ou /bin/patch, se você mover futuramente)
    # 2) patch --version funciona
    # 3) aplicar um patch simples em um arquivo de teste e conferir o resultado

    local patch_bin=""

    if [ -x "${ADM_SYSROOT}/usr/bin/patch" ]; then
        patch_bin="${ADM_SYSROOT}/usr/bin/patch"
    elif [ -x "${ADM_SYSROOT}/bin/patch" ]; then
        patch_bin="${ADM_SYSROOT}/bin/patch"
    else
        log_error "Sanity-check Patch falhou: patch não encontrado em ${ADM_SYSROOT}/usr/bin nem em ${ADM_SYSROOT}/bin."
        exit 1
    fi

    # Versão
    local ver
    ver="$("${patch_bin}" --version 2>/dev/null | head -n1 || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Patch falhou: não foi possível obter versão de ${patch_bin}."
        exit 1
    fi
    log_info "Patch: patch --version → ${ver}"

    # Teste real: aplicar um patch unificado simples
    local tmpdir
    tmpdir="$(mktemp -d)"
    local orig="${tmpdir}/arquivo.txt"
    local patched="${tmpdir}/arquivo.txt"
    local diff="${tmpdir}/arquivo.patch"

    # Conteúdo original
    cat > "${orig}" << 'EOF'
linha1
linha2
linha3
EOF

    # Diff unificado que altera linha2
    cat > "${diff}" << 'EOF'
--- arquivo.txt.orig	2025-01-01
+++ arquivo.txt	2025-01-01
@@ -1,3 +1,3 @@
 linha1
-linha2
+linha2-modificada
 linha3
EOF

    # Para usar o patch, criamos uma cópia com o nome esperado no diff (arquivo.txt)
    cp "${orig}" "${patched}"
    ( cd "${tmpdir}" && "${patch_bin}" -p0 < "arquivo.patch" >/dev/null 2>&1 )

    # Verifica se a linha realmente foi alterada
    if ! grep -q "linha2-modificada" "${patched}"; then
        log_error "Sanity-check Patch falhou: conteúdo de teste não foi modificado conforme o patch."
        rm -rf "${tmpdir}"
        exit 1
    fi

    log_info "Patch: teste de aplicação de patch unificado simples OK."

    rm -rf "${tmpdir}"

    log_ok "Sanity-check Patch-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
