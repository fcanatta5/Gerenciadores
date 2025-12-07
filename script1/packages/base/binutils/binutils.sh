# Binutils-2.45.1 – script de construção para o ADM

PKG_NAME="binutils"
PKG_VERSION="2.45.1"
PKG_CATEGORY="toolchain"

# URL oficial do tarball (formato .tar.xz)
PKG_URL="https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"

# SHA256 (recomendo preencher após baixar e checar localmente)
# Exemplo para preencher depois:
#   sha256sum binutils-2.45.1.tar.xz
PKG_SHA256="FILL_ME_WITH_REAL_SHA256"

# Dependências (ajuste conforme o layout do seu tree de pacotes)
# LFS recomenda usar zlib do sistema (--with-system-zlib)1
PKG_DEPENDS=(
  "core/zlib"
)

###############################################################################
#  Configurações específicas de build para o Binutils
#
#  O seu script principal do ADM pode usar estas variáveis assim:
#
#    ./configure \
#      ${ADM_CONFIGURE_ARGS_COMMON} \
#      "${PKG_CONFIGURE_OPTS[@]}"
#
#    make "${PKG_MAKE_OPTS[@]}"
#
#    make DESTDIR="${destdir}" "${PKG_MAKE_INSTALL_OPTS[@]}" install
#
#  E depois executar os comandos em PKG_POST_INSTALL_CMDS dentro do rootfs.
###############################################################################

# Opções extra de configure, além de ADM_CONFIGURE_ARGS_COMMON
# Baseadas nas recomendações do LFS 8.21 Binutils-2.45.12
PKG_CONFIGURE_OPTS=(
  "--enable-ld=default"             # linker bfd como ld e ld.bfd
  "--enable-plugins"                # suporte a plugins
  "--enable-shared"                 # bibliotecas compartilhadas
  "--disable-werror"                # não tratar warnings como erro
  "--enable-64-bit-bfd"             # suporte 64 bits no BFD
  "--enable-new-dtags"              # DT_RUNPATH em vez de DT_RPATH
  "--with-system-zlib"              # usar zlib do sistema
  "--enable-default-hash-style=gnu" # estilo de hash padrão 'gnu'
)

# Opções adicionais para make
# LFS usa: make tooldir=/usr3
PKG_MAKE_OPTS=(
  "tooldir=/usr"
)

# Opções para make install
PKG_MAKE_INSTALL_OPTS=(
  "tooldir=/usr"
)

###############################################################################
#  Pós-instalação dentro do rootfs
#
#  A ideia é que, após o ADM fazer:
#    rsync -a "${destdir}/" "${ADM_ROOTFS}/"
#
#  Ele rode os comandos abaixo *chrootados* ou apontando direto
#  para ${ADM_ROOTFS}. Para simplificar, aqui estão em forma de
#  shell inline, e o ADM pode substituir o prefixo /usr por
#  "${ADM_ROOTFS}/usr" automaticamente.
###############################################################################

PKG_POST_INSTALL_CMDS='
# Remover bibliotecas estáticas e doc do gprofng conforme LFS4
rm -rfv /usr/lib/lib{bfd,ctf,ctf-nobfd,gprofng,opcodes,sframe}.a \
        /usr/share/doc/gprofng/ || true
'

###############################################################################
#  Notas para integração com o ADM
#
#  1) O script principal do ADM deve:
#     - fazer o download/extração usando PKG_URL/PKG_VERSION
#     - chamar setup_profiles() para ter CC/CFLAGS/LDFLAGS, etc.
#     - entrar no diretório de build (pode ser um subdir "build")
#       se você quiser seguir exatamente o LFS:
#
#         mkdir -p build
#         cd build
#         ../configure ...
#
#       ou usar o diretório de trabalho padrão do ADM.
#
#  2) Exemplo de trechos a adicionar no seu adm (pseudo-código):
#
#     if [[ -n "${PKG_CONFIGURE_OPTS[*]:-}" ]]; then
#       ./configure \
#         ${ADM_CONFIGURE_ARGS_COMMON} \
#         "${PKG_CONFIGURE_OPTS[@]}"
#     else
#       ./configure ${ADM_CONFIGURE_ARGS_COMMON}
#     fi
#
#     if [[ -n "${PKG_MAKE_OPTS[*]:-}" ]]; then
#       make "${PKG_MAKE_OPTS[@]}"
#     else
#       make -j"$(nproc)"
#     fi
#
#     if [[ -n "${PKG_MAKE_INSTALL_OPTS[*]:-}" ]]; then
#       make DESTDIR="${destdir}" "${PKG_MAKE_INSTALL_OPTS[@]}" install
#     else
#       make DESTDIR="${destdir}" install
#     fi
#
#  3) Para executar PKG_POST_INSTALL_CMDS dentro do rootfs:
#
#     if [[ -n "${PKG_POST_INSTALL_CMDS:-}" ]]; then
#       # exemplo simples sem chroot:
#       (
#         cd "${ADM_ROOTFS}"
#         /bin/sh -c "${PKG_POST_INSTALL_CMDS}"
#       )
#     fi
#
###############################################################################
