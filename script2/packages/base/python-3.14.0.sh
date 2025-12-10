# /opt/adm/packages/base/python-3.14.0.sh
#
# Python-3.14.0 - interpretador Python 3 final do sistema
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL / PKG_SHA256 para cache de sources
#   - construído em /usr do rootfs do profile (glibc ou musl)
#   - fluxo típico:
#       ./configure --prefix=/usr --enable-shared \
#                   --with-system-expat --with-system-ffi \
#                   --enable-optimizations --with-ensurepip=yes \
#                   --build=... --host=$ADM_TARGET
#       make
#       make DESTDIR=${DESTDIR} install
#   - instala em ${ADM_SYSROOT} via DESTDIR
#   - hooks de sanity-check no rootfs (python3 --version, python3 -c, pip)

PKG_NAME="python"
PKG_VERSION="3.14.0"
PKG_CATEGORY="base"

# Fontes oficiais (CPython)
PKG_SOURCE_URLS=(
  "https://www.python.org/ftp/python/${PKG_VERSION}/Python-${PKG_VERSION}.tar.xz"
  "https://www.mirrorservice.org/sites/www.python.org/ftp/python/${PKG_VERSION}/Python-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="Python-${PKG_VERSION}.tar.xz"

# Preencha com o SHA256 oficial quando quiser travar; por enquanto deixamos vazio.
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas (ajuste os nomes para bater com os seus pacotes)
PKG_DEPENDS=(
  "bash-5.3"
  "coreutils-9.9"
  "sed-4.9"
  "grep-3.12"
  "gawk-5.3.2"
  "make-4.4.1"
  "gcc-15.2.0"
  # bibliotecas de sistema recomendadas (crie pacotes específicos depois):
  # "zlib"
  # "bzip2"
  # "xz-5.8.1"
  # "openssl"
  # "libffi"
  # "sqlite"
)

PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Em geral vamos construir Python dentro do chroot, então host == target.
    # Se ainda estiver fora do chroot, a cross-compilação de Python é bem mais
    # complexa; o caminho recomendado é sempre usar o chroot.

    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional disponível em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi

    # Não usar zlib/bzip2 embutidos se as libs do sistema estiverem presentes.
    export PYTHON_DISABLE_SSL=0
}

build() {
    # Construção padrão, adaptada ao esquema cross/profile:
    #
    #   ./configure --prefix=/usr \
    #               --build=$(./config.guess) \
    #               --host=$ADM_TARGET \
    #               --enable-shared \
    #               --with-system-expat \
    #               --with-system-ffi \
    #               --enable-optimizations \
    #               --with-ensurepip=yes
    #   make
    #
    # Em chroot, build == host == target; fora do chroot, isso é mais limitado.

    local build_triplet

    if [ -x "./config.guess" ]; then
        build_triplet="$(./config.guess)"
    else
        build_triplet="$(uname -m)-unknown-linux-gnu"
    fi

    ./configure \
        --prefix=/usr \
        --build="${build_triplet}" \
        --host="${ADM_TARGET}" \
        --enable-shared \
        --with-system-expat \
        --with-system-ffi \
        --enable-optimizations \
        --with-ensurepip=yes

    make
}

install_pkg() {
    # Instala em DESTDIR; o adm sincroniza depois DESTDIR -> ${ADM_SYSROOT}
    make DESTDIR="${DESTDIR}" install

    # Em geral, o Python instala:
    #   /usr/bin/python3.14
    #   /usr/bin/python3
    #   /usr/bin/pip3.14, pip3
    #
    # Se quiser garantir symlink /usr/bin/python -> python3, podemos criar aqui.

    local dest_usr_bin="${DESTDIR}/usr/bin"
    mkdir -pv "${dest_usr_bin}"

    if [ -x "${dest_usr_bin}/python3" ] && [ ! -e "${dest_usr_bin}/python" ]; then
        ln -sv python3 "${dest_usr_bin}/python"
    fi
}

post_install() {
    # Sanity-check Python dentro do rootfs do profile:
    #
    # 1) localizar python3.14 ou python3 em ${ADM_SYSROOT}/usr/bin
    # 2) python --version funciona
    # 3) python -c 'print("ok-python")'
    # 4) pip funciona minimamente (python -m pip --version)

    local py_bin=""

    if [ -x "${ADM_SYSROOT}/usr/bin/python3.14" ]; then
        py_bin="${ADM_SYSROOT}/usr/bin/python3.14"
    elif [ -x "${ADM_SYSROOT}/usr/bin/python3" ]; then
        py_bin="${ADM_SYSROOT}/usr/bin/python3"
    elif [ -x "${ADM_SYSROOT}/usr/bin/python" ]; then
        py_bin="${ADM_SYSROOT}/usr/bin/python"
    else
        log_error "Sanity-check Python falhou: python3.14/python3/python não encontrado em ${ADM_SYSROOT}/usr/bin."
        exit 1
    fi

    # Versão
    local ver
    ver="$("${py_bin}" --version 2>/dev/null || true)"
    if [ -z "${ver}" ]; then
        log_error "Sanity-check Python falhou: não foi possível obter versão de ${py_bin}."
        exit 1
    fi
    log_info "Python: ${py_bin} --version → ${ver}"

    # Teste simples: python -c 'print("ok-python")'
    local out
    out="$("${py_bin}" -c 'print("ok-python")' 2>/dev/null || true)"
    if [ "$out" != "ok-python" ]; then
        log_error "Sanity-check Python falhou: python -c 'print(...)' não retornou 'ok-python'. Saída foi: '$out'"
        exit 1
    fi

    # Teste pip (não é fatal se falhar, mas avisamos)
    local pip_ok=1
    local pip_info
    pip_info="$("${py_bin}" -m pip --version 2>/dev/null || true)"
    if [ -z "${pip_info}" ]; then
        log_warn "Python: pip não está funcional (python -m pip --version falhou). Verifique se ensurepip foi ativado."
        pip_ok=0
    else
        log_info "Python: python -m pip --version → ${pip_info}"
    fi

    # Teste simples de módulo da lib padrão
    local std_mod_out
    std_mod_out="$("${py_bin}" - << 'EOF'
import sys
import math
print("ok-stdlib", math.isfinite(1.0), sys.version_info[:2] >= (3, 14))
EOF
    )"

    if ! printf '%s\n' "$std_mod_out" | grep -q "ok-stdlib"; then
        log_warn "Python: teste de stdlib não retornou 'ok-stdlib'; saída foi: ${std_mod_out}"
    else
        log_info "Python: stdlib básica funcionando."
    fi

    if [ "$pip_ok" -eq 1 ]; then
        log_ok "Sanity-check Python-${PKG_VERSION} OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
    else
        log_warn "Python-${PKG_VERSION} instalado, mas pip não pôde ser validado completamente."
    fi
}
