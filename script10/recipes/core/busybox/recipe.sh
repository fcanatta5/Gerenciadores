# /var/lib/adm/recipes/core/busybox/recipe.sh

pkgname="busybox"
pkgver="1.37.0"
srcext="tar.bz2"
srcurl="https://busybox.net/downloads/busybox-${pkgver}.tar.bz2"

# SHA256 (busybox-1.37.0.tar.bz2) = 3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4 1
sha256="3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4"
md5=""

description="BusyBox - utilitários UNIX mínimos em um único binário multicall"
category="core"

deps=("core/musl" "core/binutils" "core/gcc")
provides=("cmd:busybox" "cmd:sh")

# Política padrão: raiz mínima com busybox estático e links instalados.
: "${BUSYBOX_STATIC:=1}"                  # Deixe 0 para não criar estático 
: "${BUSYBOX_INSTALL_SYMLINKS:=1}"        # "make install" cria os applets
: "${BUSYBOX_SH_STANDALONE:=1}"           # /bin/sh resolve applets sem symlinks (útil em bootstrap)
: "${BUSYBOX_DISABLE_HWCRYPTO:=1}"        # evita armadilhas em alguns toolchains/CPUs (opcional)

build() {
  # BusyBox usa Kconfig. defconfig é um bom baseline.
  make distclean
  make defconfig

  # Ajustes via sed (sem depender de scripts/config)
  if [[ "${BUSYBOX_STATIC}" == "1" ]]; then
    if grep -q '^# CONFIG_STATIC is not set' .config; then
      sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    else
      sed -i 's/^CONFIG_STATIC=.*/CONFIG_STATIC=y/' .config || true
    fi
  else
    sed -i 's/^CONFIG_STATIC=.*/# CONFIG_STATIC is not set/' .config || true
  fi

  if [[ "${BUSYBOX_SH_STANDALONE}" == "1" ]]; then
    if grep -q '^# CONFIG_FEATURE_SH_STANDALONE is not set' .config; then
      sed -i 's/^# CONFIG_FEATURE_SH_STANDALONE is not set/CONFIG_FEATURE_SH_STANDALONE=y/' .config
    else
      sed -i 's/^CONFIG_FEATURE_SH_STANDALONE=.*/CONFIG_FEATURE_SH_STANDALONE=y/' .config || true
    fi
  fi

  # (Opcional) desabilita aceleração de SHA1/SHA256 por instruções (pode dar dor de cabeça em alguns ambientes)
  if [[ "${BUSYBOX_DISABLE_HWCRYPTO}" == "1" ]]; then
    sed -i \
      -e 's/^CONFIG_SHA1_HWACCEL=.*/# CONFIG_SHA1_HWACCEL is not set/' \
      -e 's/^CONFIG_SHA256_HWACCEL=.*/# CONFIG_SHA256_HWACCEL is not set/' \
      .config 2>/dev/null || true

    # Alguns trees usam nomes alternativos:
    sed -i \
      -e 's/^CONFIG_SHA1_USE_*.*=.*/# CONFIG_SHA1_USE_* is not set/' \
      -e 's/^CONFIG_SHA256_USE_*.*=.*/# CONFIG_SHA256_USE_* is not set/' \
      .config 2>/dev/null || true
  fi

  # Garante que /bin/sh exista (mesmo em rootfs minimalista)
  # Normalmente busybox fornece applet "sh" quando ash está habilitado (defconfig costuma habilitar).
  # A instalação cria /bin/busybox e symlinks conforme config.

  make -j"${JOBS}"
}

install_pkg() {
  # BusyBox ignora PREFIX clássico; usa CONFIG_PREFIX como root de instalação.
  # O seu adm passa DESTDIR=<staging>. 2
  if [[ "${BUSYBOX_INSTALL_SYMLINKS}" == "1" ]]; then
    make CONFIG_PREFIX="${DESTDIR}" install
  else
    # Só instala o binário, sem criar os links (útil se você gerencia links manualmente).
    install -D -m 0755 busybox "${DESTDIR}/bin/busybox"
  fi

  # Garante /bin/sh -> busybox (para bootstrap)
  install -d "${DESTDIR}/bin"
  ln -sf busybox "${DESTDIR}/bin/sh"

  # Copia files/ se existir
  if [[ -d "${FILES_DIR}" ]]; then
    cp -a "${FILES_DIR}/." "${DESTDIR}/"
  fi
}
