# /opt/adm/packages/base/gcc-15.2.0.sh
#
# GCC-15.2.0 - compilador C/C++ final do sistema (com libstdc++ e plugins)
#
# Integração com adm:
#   - usa PKG_SOURCE_URLS / PKG_TARBALL para cache de source
#   - baixa e embute gmp/mpfr/mpc via adm_fetch_file (build "in-tree")
#   - constrói em diretório build/ separado
#   - configura com:
#       ../configure --prefix=/usr --build=... --host=$ADM_TARGET --target=$ADM_TARGET \
#                    --enable-languages=c,c++ \
#                    --enable-default-pie --enable-default-ssp \
#                    --disable-multilib --disable-bootstrap \
#                    --enable-plugin \
#                    --disable-libsanitizer
#   - make && make DESTDIR=${DESTDIR} install
#   - cria /usr/bin/cc -> gcc em DESTDIR
#   - hooks de sanity-check no rootfs (gcc/g++, libstdc++ básica)

PKG_NAME="gcc"
PKG_VERSION="15.2.0"
PKG_CATEGORY="base"

# Fontes oficiais (GNU + mirrors)
PKG_SOURCE_URLS=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
  "https://ftp.unicamp.br/pub/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
)

PKG_TARBALL="gcc-${PKG_VERSION}.tar.xz"

# GCC 15.2.0 ainda é bem novo; deixe o checksum vazio por enquanto.
# O adm apenas vai emitir warning e pular a verificação.
PKG_SHA256=""
PKG_MD5=""

# Dependências lógicas (ajuste os nomes conforme seus scripts)
PKG_DEPENDS=(
  "binutils-2.45.1"
  "make-4.4.1"
  "glibc-pass1"      # ou glibc-final, dependendo do nome que você está usando
  "zlib"             # se você tiver pacote de zlib; caso não tenha, remova
)

# Sem patches padrão aqui; adicione se precisar
PKG_PATCH_URLS=()
PKG_PATCH_SHA256=()
PKG_PATCH_MD5=()

# --------------------------------------------------------------------
# Helper interno: embutir gmp/mpfr/mpc in-tree
# --------------------------------------------------------------------

_gcc_fetch_and_embed_libs() {
    # Usa adm_fetch_file() do adm.sh para baixar gmp/mpfr/mpc em SOURCE_CACHE
    # e extrair dentro da árvore do GCC (gmp/, mpfr/, mpc/).
    #
    # Faz isso de forma idempotente: se o diretório já existir, não re-extrai.

    # GMP
    if [ ! -d "gmp" ]; then
        local gmp_tar="gmp-6.3.0.tar.xz"
        local gmp_urls=(
            "https://ftp.gnu.org/gnu/gmp/${gmp_tar}"
            "https://ftpmirror.gnu.org/gmp/${gmp_tar}"
        )
        adm_fetch_file "${gmp_tar}" "${gmp_urls[*]}" "" ""
        tar -xf "${SOURCE_CACHE}/${gmp_tar}"
        mv -v "gmp-6.3.0" "gmp"
    fi

    # MPFR
    if [ ! -d "mpfr" ]; then
        local mpfr_tar="mpfr-4.2.1.tar.xz"
        local mpfr_urls=(
            "https://ftp.gnu.org/gnu/mpfr/${mpfr_tar}"
            "https://ftpmirror.gnu.org/mpfr/${mpfr_tar}"
        )
        adm_fetch_file "${mpfr_tar}" "${mpfr_urls[*]}" "" ""
        tar -xf "${SOURCE_CACHE}/${mpfr_tar}"
        mv -v "mpfr-4.2.1" "mpfr"
    fi

    # MPC
    if [ ! -d "mpc" ]; then
        local mpc_tar="mpc-1.3.1.tar.gz"
        local mpc_urls=(
            "https://ftp.gnu.org/gnu/mpc/${mpc_tar}"
            "https://ftpmirror.gnu.org/mpc/${mpc_tar}"
        )
        adm_fetch_file "${mpc_tar}" "${mpc_urls[*]}" "" ""
        tar -xf "${SOURCE_CACHE}/${mpc_tar}"
        mv -v "mpc-1.3.1" "mpc"
    fi
}

# --------------------------------------------------------------------
# Hooks
# --------------------------------------------------------------------

pre_build() {
    # Ambiente previsível
    export LC_ALL=C

    # Log de contexto de toolchain
    local tools_bin="${ADM_SYSROOT}/tools/bin"
    if [ -d "${tools_bin}" ]; then
        log_info "Toolchain adicional encontrado em ${tools_bin} (TARGET=${ADM_TARGET})."
    fi

    # Estamos dentro do diretório de source do GCC (srcdir).
    # Baixar e embutir gmp/mpfr/mpc dentro da árvore.
    if ! command -v adm_fetch_file >/dev/null 2>&1; then
        log_error "adm_fetch_file não disponível no ambiente; verifique se o adm.sh está atualizado."
        exit 1
    fi

    _gcc_fetch_and_embed_libs
}

build() {
    # Build final do GCC, com C e C++ (libstdc++) e plugins ativados.
    #
    # Estratégia:
    #   mkdir -v build
    #   cd build
    #   ../configure --prefix=/usr \
    #       --build=$(../config.guess) \
    #       --host=$ADM_TARGET \
    #       --target=$ADM_TARGET \
    #       --enable-languages=c,c++ \
    #       --enable-default-pie \
    #       --enable-default-ssp \
    #       --disable-multilib \
    #       --disable-bootstrap \
    #       --enable-plugin \
    #       --disable-libsanitizer
    #   make
    #
    # Observações:
    #   - gmp/mpfr/mpc foram embutidos via pre_build() (diretórios gmp/, mpfr/, mpc/)
    #   - --disable-libsanitizer evita dor de cabeça inicial com dependências extras
    #   - ADM_TARGET (ex: x86_64-pc-linux-gnu ou x86_64-pc-linux-musl) vem do profile.

    mkdir -pv build
    pushd build >/dev/null

    local build_triplet
    if [ -x "../config.guess" ]; then
        build_triplet="$(../config.guess)"
    else
        build_triplet="$(uname -m)-unknown-linux-gnu"
    fi

    ../configure \
        --prefix=/usr \
        --build="${build_triplet}" \
        --host="${ADM_TARGET}" \
        --target="${ADM_TARGET}" \
        --enable-languages=c,c++ \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-multilib \
        --disable-bootstrap \
        --enable-plugin \
        --disable-libsanitizer

    make

    popd >/dev/null
}

install_pkg() {
    # Instala a partir do diretório build em DESTDIR; o adm faz sync para o SYSROOT.
    pushd build >/dev/null

    make DESTDIR="${DESTDIR}" install

    popd >/dev/null

    # Criar /usr/bin/cc -> gcc em DESTDIR (como em LFS)
    local dest_usr_bin="${DESTDIR}/usr/bin"
    mkdir -pv "${dest_usr_bin}"

    if [ -x "${dest_usr_bin}/gcc" ] && [ ! -e "${dest_usr_bin}/cc" ]; then
        ln -sv gcc "${dest_usr_bin}/cc"
    fi

    # Opcional: remover arquivos .la de libstdc++ e afins, se quiser um sistema mais limpo.
    # Exemplo (descomente se quiser):
    #
    # local dest_usr_lib="${DESTDIR}/usr/lib"
    # find "${dest_usr_lib}" -name '*.la' -type f -delete || true
}

post_install() {
    # Sanity-check do GCC final no rootfs do profile:
    #
    # 1) ${ADM_SYSROOT}/usr/bin/gcc existe e é executável
    # 2) ${ADM_SYSROOT}/usr/bin/g++ existe e é executável
    # 3) gcc --version / g++ --version funcionam
    # 4) compilar e linkar um programa C simples
    # 5) compilar e linkar um programa C++ simples que usa libstdc++
    #
    local usrbin="${ADM_SYSROOT}/usr/bin"
    local gcc_bin="${usrbin}/gcc"
    local gxx_bin="${usrbin}/g++"

    if [ ! -x "${gcc_bin}" ]; then
        log_error "Sanity-check GCC falhou: ${gcc_bin} não encontrado ou não executável."
        exit 1
    fi

    if [ ! -x "${gxx_bin}" ]; then
        log_error "Sanity-check GCC falhou: ${gxx_bin} (g++) não encontrado ou não executável."
        exit 1
    fi

    local gcc_ver gxx_ver
    gcc_ver="$("${gcc_bin}" --version 2>/dev/null | head -n1 || true)"
    gxx_ver="$("${gxx_bin}" --version 2>/dev/null | head -n1 || true)"

    if [ -z "${gcc_ver}" ]; then
        log_error "Sanity-check GCC falhou: não foi possível obter versão de ${gcc_bin}."
        exit 1
    fi
    if [ -z "${gxx_ver}" ]; then
        log_error "Sanity-check GCC falhou: não foi possível obter versão de ${gxx_bin}."
        exit 1
    fi

    log_info "GCC: gcc --version → ${gcc_ver}"
    log_info "GCC: g++ --version → ${gxx_ver}"

    # Testes de compilação (C e C++).
    #
    # Observação importante:
    # - Fora de chroot, o gcc instalado em ${ADM_SYSROOT} ainda vai procurar
    #   includes/libc padrão do sistema host, não de ${ADM_SYSROOT}. Então,
    #   estes testes garantem principalmente que o toolchain está completo
    #   (cc1, collect2, libstdc++ etc), não que a linkage contra o rootfs
    #   do profile está 100% isolada.
    #
    local tmpdir
    tmpdir="$(mktemp -d)"

    # Teste C simples
    cat > "${tmpdir}/test.c" << 'EOF'
#include <stdio.h>
int main(void) {
    printf("ok-c\n");
    return 0;
}
EOF

    "${gcc_bin}" "${tmpdir}/test.c" -o "${tmpdir}/test-c" >/dev/null 2>&1 || {
        log_error "Sanity-check GCC falhou: não foi possível compilar/linkar programa C simples."
        rm -rf "${tmpdir}"
        exit 1
    }

    # Não precisamos necessariamente executar o binário; pode ser cross diferente.

    # Teste C++ com libstdc++
    cat > "${tmpdir}/test.cpp" << 'EOF'
#include <iostream>
#include <vector>
int main() {
    std::vector<int> v = {1, 2, 3};
    int soma = 0;
    for (int x : v) soma += x;
    if (soma == 6) {
        std::cout << "ok-cpp" << std::endl;
        return 0;
    }
    return 1;
}
EOF

    "${gxx_bin}" "${tmpdir}/test.cpp" -o "${tmpdir}/test-cpp" >/dev/null 2>&1 || {
        log_error "Sanity-check GCC falhou: não foi possível compilar/linkar programa C++ simples (libstdc++)."
        rm -rf "${tmpdir}"
        exit 1
    }

    # Se for nativo (host == target), podemos tentar rodar o binário apenas como teste extra.
    # Se falhar, não abortamos, apenas avisamos.
    if "${tmpdir}/test-cpp" >/dev/null 2>&1; then
        log_info "GCC: binário C++ de teste executou com sucesso (ok-cpp)."
    else
        log_warn "GCC: não foi possível executar o binário C++ de teste (talvez cross-target diferente do host)."
    fi

    rm -rf "${tmpdir}"

    # Verificar presença básica de libstdc++ no rootfs (não exaustivo)
    local libdir_candidates=(
        "${ADM_SYSROOT}/usr/lib"
        "${ADM_SYSROOT}/usr/lib64"
    )
    local found_libstdcxx=0
    local d
    for d in "${libdir_candidates[@]}"; do
        if [ -d "$d" ] && ls "$d"/libstdc++.so* >/dev/null 2>&1; then
            log_info "GCC: libstdc++ encontrada em ${d}."
            found_libstdcxx=1
            break
        fi
    done

    if [ "$found_libstdcxx" -eq 0 ]; then
        log_warn "GCC: nenhuma libstdc++ encontrada em ${ADM_SYSROOT}/usr/lib*; verifique manualmente se necessário."
    fi

    log_ok "Sanity-check GCC-${PKG_VERSION} (com libstdc++) OK em ${ADM_SYSROOT} (profile=${ADM_PROFILE})."
}
