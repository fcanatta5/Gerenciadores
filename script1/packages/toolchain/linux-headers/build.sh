#!/usr/bin/env bash
# Receita ADM para Linux-6.17.9 API Headers

PKG_NAME="linux-headers"
PKG_VERSION="6.17.9"

# Tarball oficial do kernel
PKG_URLS=(
  "https://www.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
)

# MD5 conforme livro Multilib LFS ml-12.4-134-systemd (sec. de downloads)
# linux-6.17.9.tar.xz → MD5 512f1c964520792d9337f43b9177b181
PKG_MD5S=(
  "512f1c964520792d9337f43b9177b181"
)

# Sem dependências diretas (o próprio kernel se constrói "sozinho"),
# mas em termos de sistema você obviamente precisa de um toolchain mínimo.
PKG_DEPENDS=(
  # "core/make"
  # "core/gcc-pass1"
)

# Kernel NÃO usa ./configure, então PKG_CONFIGURE_OPTS fica vazio.
# O adm.sh já detecta ausência de ./configure e pula a fase configure.
# (Nada para configurar aqui.)
# PKG_CONFIGURE_OPTS=()

###############################################################################
# Integração especial com o ADM
#
# O adm.sh sempre faz:
#   destdir="${ADM_BUILD_ROOT}/dest/${full}"
# para este pacote, "full" = "core/linux-headers".
#
# Vamos assumir esse nome de pacote aqui pra poder apontar o INSTALL_HDR_PATH
# diretamente para o DESTDIR que o ADM usa internamente.
###############################################################################

# IMPORTANTE: o nome abaixo *tem* que bater com o nome do pacote
# (categoria/nome) que você usa ao chamar ./adm.sh build core/linux-headers.
ADM_LINUX_HEADERS_FULL="toolchain/linux-headers"

# Diretório DESTDIR *exato* que o ADM vai usar para esse pacote:
PKG_LINUX_HEADERS_DESTDIR="${ADM_BUILD_ROOT}/dest/${ADM_LINUX_HEADERS_FULL}"

# Fase BUILD:
#  - make mrproper        → limpa árvore do kernel
#  - make headers_check   → sanity básico dos headers (opcional, mas bom)
PKG_MAKE_OPTS=(
  "mrproper"
  "headers_check"
)

# Fase INSTALL:
#  Vamos usar o alvo oficial do kernel:
#    make headers_install INSTALL_HDR_PATH="${DESTDIR}/usr"
#
# Como o adm.sh chama:
#   ( cd "$build_dir" && make DESTDIR="${destdir}" install "${PKG_MAKE_INSTALL_OPTS[@]}" )
#
# não temos acesso direto a ${destdir} aqui, então fixamos INSTALL_HDR_PATH
# para o mesmo caminho que o ADM usa como DESTDIR para *este* pacote:
#
#   INSTALL_HDR_PATH="${PKG_LINUX_HEADERS_DESTDIR}/usr"
#
# Assim os headers saneados vão direto para o DESTDIR, que depois o ADM
# sincroniza com o rootfs.
PKG_MAKE_INSTALL_OPTS=(
  "INSTALL_HDR_PATH=${PKG_LINUX_HEADERS_DESTDIR}/usr"
  "headers_install"
)

# Observações:
# - O comando final na fase install será algo como:
#     make DESTDIR="${PKG_LINUX_HEADERS_DESTDIR}" install \
#          INSTALL_HDR_PATH="${PKG_LINUX_HEADERS_DESTDIR}/usr" headers_install
#
#   Isso também roda o alvo "install" do kernel, que pode construir/instalar
#   kernel e módulos dentro de ${PKG_LINUX_HEADERS_DESTDIR}. Não é ideal se
#   você quer *apenas* headers, mas é funcional.
#
# - Se quiser manter somente os headers no rootfs final, você pode depois
#   limpar o que não quiser dentro de ${ADM_ROOTFS} (p.ex. /boot, /lib/modules)
#   ou ajustar o adm.sh futuramente para suportar um "install customizado"
#   para esse pacote específico.
