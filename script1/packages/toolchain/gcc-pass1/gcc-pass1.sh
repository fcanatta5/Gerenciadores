# GCC-15.2.0 - Pass 1 (toolchain temporário em /tools)

PKG_NAME="gcc-pass1"
PKG_VERSION="15.2.0"
PKG_CATEGORY="toolchain"

# Fonte oficial do GCC 15.2.0
PKG_URL="https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz"
PKG_SHA256="438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e"

# Binutils Pass 1 deve existir antes
PKG_DEPENDS=("toolchain/binutils-pass1")

# -------------------------------------------------------------------------
# Validação de perfil (glibc ou musl)
# -------------------------------------------------------------------------
_adm_profile_effective="${ADM_PROFILE:-glibc}"

case "${_adm_profile_effective}" in
  glibc|musl)
    # OK – perfis suportados
    ;;
  *)
    echo "gcc-pass1: perfil ADM_PROFILE='${ADM_PROFILE:-}' não suportado." >&2
    echo "Use ADM_PROFILE=glibc ou ADM_PROFILE=musl." >&2
    exit 1
    ;;
esac

# -------------------------------------------------------------------------
# Configuração de build para Pass 1
# -------------------------------------------------------------------------
# Importante:
# - Quem calcula TARGET_TRIPLET, ADM_SYSROOT, CFLAGS, etc. é o setup_profiles()
#   do adm.sh (chamado antes do configure).
# - Aqui só definimos opções específicas do GCC Pass 1.
#
# - Prefixo em /tools: o ADM ainda usará DESTDIR=${ADM_ROOTFS}/.../dest/...
#   → resultado final vai para ${ADM_ROOTFS}/tools.
# - with-sysroot aponta para o rootfs do ADM, coerente com o profile.
#
# Obs: Não usamos --without-headers/--with-newlib aqui porque o fluxo genérico
# do adm sempre chama "make all" e "make install". Para garantir que isso
# funcione sem erros, fazemos um build "completo" do GCC, porém isolado em
# /tools (toolchain temporário).

PKG_CONFIGURE_OPTS=(
  "--prefix=/tools"
  "--with-sysroot=${ADM_ROOTFS}"
  "--disable-nls"
  "--disable-multilib"
  "--enable-languages=c,c++"
)

# Opcionalmente, podemos suavizar algumas otimizações para deixar o Pass 1
# o mais estável possível:
PKG_CFLAGS_EXTRA="-O2 -pipe"
PKG_LDFLAGS_EXTRA=""

# Não precisamos alterar PKG_MAKE_OPTS / PKG_MAKE_INSTALL_OPTS:
# - O adm já faz: make -j$(nproc)
# - E depois: make DESTDIR=... install
