# /opt/adm/packages/base/bash-5.3.sh
#
# bash 5.3 (base) — instala em /usr no rootfs do profile atual
# Alinhado ao adm.sh:
# - build() instala em DESTDIR="$PKG_BUILD_ROOT"
# - adm.sh empacota e extrai no $PKG_ROOTFS do profile
# - hook de sanity-check em post_install
#
# Dependências típicas:
# - base/ncurses (para readline)
# - glibc (no profile glibc)
#
# Observação:
# - Esta receita cria /bin/bash e /bin/sh (symlinks) apontando para /usr/bin/bash
#   dentro do pacote, para garantir compatibilidade no rootfs.

PKG_NAME="bash"
PKG_VERSION="5.3"
PKG_DESC="GNU Bourne Again Shell"
PKG_DEPENDS="glibc base/ncurses"
PKG_CATEGORY="base"
PKG_LIBC="glibc"

build() {
  local url="https://ftp.gnu.org/gnu/bash/bash-${PKG_VERSION}.tar.gz"
  local tar="bash-${PKG_VERSION}.tar.gz"
  local src

  src="$(fetch_source "$url" "$tar")"

  mkdir -p "$PKG_BUILD_WORK"
  cd "$PKG_BUILD_WORK"
  rm -rf "bash-${PKG_VERSION}" build
  tar xf "$src"

  cd "bash-${PKG_VERSION}"

  mkdir -p "$PKG_BUILD_WORK/build"
  cd "$PKG_BUILD_WORK/build"

  # Configure para /usr
  # --with-installed-readline usa readline do sistema (fornecido via ncurses/readline)
  ../bash-${PKG_VERSION}/configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --without-bash-malloc \
    --with-installed-readline

  make

  make install DESTDIR="$PKG_BUILD_ROOT"

  # Compatibilidade: /bin/bash e /bin/sh
  mkdir -p "$PKG_BUILD_ROOT/bin"
  ln -sf ../usr/bin/bash "$PKG_BUILD_ROOT/bin/bash"
  ln -sf bash "$PKG_BUILD_ROOT/bin/sh"

  # /etc/bash.bashrc (opcional; seguro)
  mkdir -p "$PKG_BUILD_ROOT/etc"
  if [ ! -f "$PKG_BUILD_ROOT/etc/bash.bashrc" ]; then
    cat > "$PKG_BUILD_ROOT/etc/bash.bashrc" <<'EOF'
# /etc/bash.bashrc - system-wide bashrc
# Ajuste conforme necessário.
EOF
  fi
}

pre_install() {
  echo "==> [bash-${PKG_VERSION}] Instalando bash no rootfs do profile via adm"
}

post_install() {
  echo "==> [bash-${PKG_VERSION}] Sanity-check pós-instalação"

  local sysroot="${PKG_ROOTFS:-$ADM_CURRENT_ROOTFS}"

  # 1) Binários esperados no rootfs
  if [ ! -x "${sysroot}/usr/bin/bash" ]; then
    echo "ERRO: bash não encontrado em ${sysroot}/usr/bin/bash"
    exit 1
  fi

  if [ ! -e "${sysroot}/bin/bash" ]; then
    echo "ERRO: link /bin/bash não existe no rootfs"
    exit 1
  fi

  if [ ! -e "${sysroot}/bin/sh" ]; then
    echo "ERRO: link /bin/sh não existe no rootfs"
    exit 1
  fi

  # 2) Verifica versão
  if ! "${sysroot}/usr/bin/bash" --version 2>/dev/null | head -n1 | grep -q "bash, version 5\.3"; then
    echo "ERRO: bash --version não indica 5.3"
    "${sysroot}/usr/bin/bash" --version 2>/dev/null | head -n2 || true
    exit 1
  fi

  # 3) Verifica symlinks
  local btarget starget
  if [ -L "${sysroot}/bin/bash" ]; then
    btarget="$(readlink "${sysroot}/bin/bash" || true)"
  else
    btarget=""
  fi
  if [ -L "${sysroot}/bin/sh" ]; then
    starget="$(readlink "${sysroot}/bin/sh" || true)"
  else
    starget=""
  fi

  # Esperado: /bin/bash -> ../usr/bin/bash ; /bin/sh -> bash
  [ -n "$btarget" ] || warn "AVISO: /bin/bash não é symlink (ainda pode funcionar)"
  [ -n "$starget" ] || warn "AVISO: /bin/sh não é symlink (ainda pode funcionar)"

  echo "Sanity-check bash ${PKG_VERSION}: OK."
}
