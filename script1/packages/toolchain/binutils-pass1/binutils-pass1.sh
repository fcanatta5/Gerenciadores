# Binutils-2.45.1 - Pass 1 para o ADM

# Metadados básicos
PKG_NAME="binutils-pass1"
PKG_VERSION="2.45.1"
PKG_CATEGORY="toolchain"

# Fonte oficial (tar.xz) + checksum
PKG_URL="https://sourceware.org/pub/binutils/releases/binutils-2.45.1.tar.xz"
PKG_SHA256="5fe101e6fe9d18fdec95962d81ed670fdee5f37e3f48f0bef87bddf862513aa5"

# Dependências em termos de outros pacotes do ADM.
# Para o Pass 1, não forçamos nenhuma dependência além do que o próprio sistema
# de build do ADM já exige (host com toolchain básico).
PKG_DEPENDS=()

# -------------------------------------------------------------------------
# Garantia de perfil suportado (glibc ou musl)
# -------------------------------------------------------------------------
# Aqui nós apenas validamos o perfil selecionado. Quem "detecta" e aplica o
# profile é a função setup_profiles() do próprio adm.sh, que será chamada
# depois de load_pkg_metadata().
#
# Se ADM_PROFILE não estiver definido, consideramos glibc (mesmo padrão do ADM).

_adm_profile_effective="${ADM_PROFILE:-glibc}"

case "${_adm_profile_effective}" in
  glibc|musl)
    # OK – perfis explicitamente suportados
    ;;
  aggressive)
    # Se você quiser tratar "aggressive" como variação de glibc,
    # basta mover isso para o caso acima. Por enquanto, bloqueamos
    # explicitamente para deixar claro o que está sendo usado.
    echo "binutils-pass1: o perfil 'aggressive' não é suportado explicitamente para Pass 1." >&2
    echo "Use ADM_PROFILE=glibc ou ADM_PROFILE=musl." >&2
    exit 1
    ;;
  *)
    echo "binutils-pass1: perfil ADM_PROFILE='${ADM_PROFILE:-}' não suportado." >&2
    echo "Use ADM_PROFILE=glibc ou ADM_PROFILE=musl." >&2
    exit 1
    ;;
esac

# -------------------------------------------------------------------------
# Configuração de build
# -------------------------------------------------------------------------
# Regras importantes:
# - Quem define TARGET_TRIPLET, ADM_SYSROOT, ADM_ROOTFS, CFLAGS, etc. é
#   setup_profiles() em adm.sh.
# - Esta receita não reimplementa isso: ela só adiciona flags específicas
#   do Binutils Pass 1.
# - O ADM vai chamar:
#     ./configure ${ADM_CONFIGURE_ARGS_COMMON} ${PKG_CONFIGURE_OPTS[@]}
#   onde ADM_CONFIGURE_ARGS_COMMON já inclui:
#     --host=${HOST_TRIPLET}
#     --build=${BUILD_TRIPLET}
#     --prefix=/usr
#     --sysconfdir=/etc
#     --localstatedir=/var
#
# Ou seja: o binutils-pass1 será automaticamente construído para o
# TARGET_TRIPLET correspondente ao profile (glibc ou musl).

PKG_CONFIGURE_OPTS=(
  # Importante: *não* interpolamos TARGET_TRIPLET/ADM_SYSROOT aqui, porque
  # essas variáveis ainda não estão definidas na hora em que a receita é
  # carregada. Elas serão aplicadas via ADM_CONFIGURE_ARGS_COMMON.
  #
  # As opções abaixo são baseadas no LFS (Pass 1) e são neutras em relação
  # a glibc/musl – quem decide isso é o toolchain selecionado no profile.
  "--disable-nls"
  "--enable-gprofng=no"
  "--disable-werror"
  "--enable-new-dtags"
  "--enable-default-hash-style=gnu"
)

# Se quiser forçar algo específico de toolchain (tipo usar lib interna de zlib),
# você pode adicionar aqui, por exemplo:
#  "--without-system-zlib"
# e assim evitar dependência explícita de zlib do sistema alvo.
#
# PKG_MAKE_OPTS e PKG_MAKE_INSTALL_OPTS podem ficar vazios – o ADM já usa
# -j$(nproc) por padrão.
# Exemplo, se um dia precisar:
# PKG_MAKE_OPTS=( )
# PKG_MAKE_INSTALL_OPTS=( )
