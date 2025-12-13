###############################################################################
# glibc 2.42 (BASE) - libc do sistema no SYSROOT/rootfs do target
# LFS-style (chapter08) adaptado para adm (DESTDIR stage -> rsync -> SYSROOT)
#
# Importante:
# - Em cross-build você NÃO consegue rodar "make check" nem "localedef" do target no host.
#   Este script mantém os passos do LFS, mas:
#   - pula o test-suite por padrão em cross (pode habilitar se for build nativo)
#   - instala nsswitch.conf e ld.so.conf no stage
###############################################################################

PKG_CATEGORY="base"
PKG_NAME="glibc"
PKG_VERSION="2.42"
PKG_RELEASE="1"
PKG_DESC="GNU C Library ${PKG_VERSION} (base/system libc) instalada no sysroot"
PKG_LICENSE="LGPL-2.1-or-later"
PKG_SITE="https://www.gnu.org/software/libc/"

# Dependências típicas (ajuste conforme seus nomes)
PKG_DEPENDS=(
  "toolchain/binutils-2.45.1-pass1"
  "toolchain/gcc-15.2.0-pass1"
  "toolchain/linux-headers-6.17.9"
  "base/binutils-2.45.1"
)

PKG_URLS=(
  "https://ftp.gnu.org/gnu/glibc/glibc-${PKG_VERSION}.tar.xz"
  "https://ftpmirror.gnu.org/glibc/glibc-${PKG_VERSION}.tar.xz"
)

# MD5 do tarball glibc-2.42.tar.xz (conhecido/publicado)
PKG_MD5="23c6f5a27932b435cae94e087cb8b1f5"  # 

# Patches LFS (development) + MD5 publicados
LFS_PATCH_BASE="https://www.linuxfromscratch.org/patches/lfs/development"
PATCH_UPSTREAM="${LFS_PATCH_BASE}/glibc-2.42-upstream_fixes-1.patch"
PATCH_UPSTREAM_MD5="fb47fb9c2732d3c8029bf6be48cd9ea4"  # 

PATCH_FHS="${LFS_PATCH_BASE}/glibc-2.42-fhs-1.patch"
PATCH_FHS_MD5="9a5997c3452909b1769918c759eff8a2"       # 

# Controle (opcional)
# ADM_GLIBC_RUN_TESTS=1 para tentar make check (somente quando for nativo/executável)
ADM_GLIBC_RUN_TESTS="${ADM_GLIBC_RUN_TESTS:-0}"

###############################################################################
# Helpers
###############################################################################
_need_kernel_headers() {
  [[ -d "$SYSROOT/usr/include" ]] || return 1
  [[ -f "$SYSROOT/usr/include/linux/types.h" || -f "$SYSROOT/usr/include/linux/version.h" ]] || return 1
  return 0
}

_fetch_patch() {
  # $1=url $2=out $3=md5
  command -v curl >/dev/null 2>&1 || { echo "ERRO: curl requerido para baixar patches" >&2; return 1; }
  command -v md5sum >/dev/null 2>&1 || { echo "ERRO: md5sum requerido para validar patches" >&2; return 1; }

  local url="$1" out="$2" md5="$3"
  curl -L --fail --retry 3 --retry-delay 2 -o "$out" "$url"
  echo "${md5}  ${out}" | md5sum -c - >/dev/null 2>&1 || {
    echo "ERRO: MD5 do patch não confere: $url" >&2
    return 1
  }
}

###############################################################################
# Hooks
###############################################################################
pkg_prepare() {
  SRC_DIR="$PKG_WORKDIR/glibc-${PKG_VERSION}"
  [[ -d "$SRC_DIR" ]] || {
    SRC_DIR="$(find "$PKG_WORKDIR" -maxdepth 1 -type d | tail -n +2 | head -n1)"
  }
  export SRC_DIR

  BUILD_DIR="$PKG_BUILDDIR"
  mkdir -p "$BUILD_DIR"

  if ! _need_kernel_headers; then
    echo "ERRO: linux-headers não encontrados em $SYSROOT/usr/include" >&2
    return 1
  fi

  if [[ ! -x "$TOOLSROOT/bin/${CTARGET}-gcc" ]]; then
    echo "ERRO: cross-gcc não encontrado: $TOOLSROOT/bin/${CTARGET}-gcc" >&2
    return 1
  fi

  # Baixa e aplica patches LFS
  local p1="$BUILD_DIR/glibc-2.42-upstream_fixes-1.patch"
  local p2="$BUILD_DIR/glibc-2.42-fhs-1.patch"

  _fetch_patch "$PATCH_UPSTREAM" "$p1" "$PATCH_UPSTREAM_MD5"
  _fetch_patch "$PATCH_FHS"      "$p2" "$PATCH_FHS_MD5"

  cd "$SRC_DIR"
  command -v patch >/dev/null 2>&1 || { echo "ERRO: patch requerido" >&2; return 1; }

  patch -Np1 -i "$p1"
  patch -Np1 -i "$p2"

  # Fix Valgrind issue (LFS sed)
  # 
  sed -e '/unistd.h/i #include <string.h>' \
      -e '/libc_rwlock_init/c\
    __libc_rwlock_define_initialized (, reset_lock);\
    memcpy (&lock, &reset_lock, sizeof (lock));' \
      -i stdlib/abort.c
}

pkg_configure() {
  cd "$BUILD_DIR"

  # LFS recomenda build dir dedicado e rootsbindir=/usr/sbin via configparms 
  echo "rootsbindir=/usr/sbin" > configparms

  # glibc é sensível; evite flags do ambiente
  unset CFLAGS CXXFLAGS LDFLAGS

  export BUILD_CC="${BUILD_CC:-gcc}"
  export BUILD_CXX="${BUILD_CXX:-g++}"

  # Toolchain do target (pass1 em tools)
  export CC="$TOOLSROOT/bin/${CTARGET}-gcc"
  export CXX="$TOOLSROOT/bin/${CTARGET}-g++"
  export AR="$TOOLSROOT/bin/${CTARGET}-ar"
  export RANLIB="$TOOLSROOT/bin/${CTARGET}-ranlib"

  # Sysroot nas includes
  export CPPFLAGS="${CPPFLAGS:-} --sysroot=$SYSROOT"

  # Cache para cross (evita testes impossíveis no host)
  cat >config.cache <<'EOF'
libc_cv_forced_unwind=yes
libc_cv_c_cleanup=yes
EOF

  # LFS config (adaptado ao cross):
  # --disable-nscd, libc_cv_slibdir=/usr/lib, --enable-stack-protector=strong, --enable-kernel=5.4 6
  "$SRC_DIR/configure" \
    --prefix=/usr \
    --host="$CTARGET" \
    --build="$CHOST" \
    --with-headers="$SYSROOT/usr/include" \
    --cache-file="$BUILD_DIR/config.cache" \
    --disable-werror \
    --disable-nscd \
    "libc_cv_slibdir=/usr/lib" \
    --enable-stack-protector=strong \
    --enable-kernel=5.4

  [[ -f config.status ]] || return 1

  # LFS: evitar sanity-check antigo no install 
  sed '/test-installation/s@$(PERL)@echo not running@' -i "$SRC_DIR/Makefile"
}

pkg_build() {
  cd "$BUILD_DIR"
  make $MAKEFLAGS

  # Test-suite:
  # LFS considera crítico em build nativo; em cross não é executável no host. 
  if [[ "$ADM_GLIBC_RUN_TESTS" -eq 1 && "$CTARGET" == "$CHOST" ]]; then
    make check
  else
    echo "INFO: pulando 'make check' (cross/non-native). Para nativo: ADM_GLIBC_RUN_TESTS=1" >&2
  fi
}

pkg_install() {
  cd "$BUILD_DIR"

  # Evita warning de /etc/ld.so.conf ausente no install (LFS) 
  mkdir -p "$PKG_STAGEDIR/etc"
  : >"$PKG_STAGEDIR/etc/ld.so.conf"
  mkdir -p "$PKG_STAGEDIR/etc/ld.so.conf.d"

  # Instala no stage
  make DESTDIR="$PKG_STAGEDIR" install

  # LFS: corrigir path hardcoded do loader no ldd 
  if [[ -f "$PKG_STAGEDIR/usr/bin/ldd" ]]; then
    sed '/RTLDLIST=/s@/usr@@g' -i "$PKG_STAGEDIR/usr/bin/ldd"
  fi

  # LFS: criar /etc/nsswitch.conf (útil para ambiente com rede/dns) 
  cat >"$PKG_STAGEDIR/etc/nsswitch.conf" <<'EOF'
# Begin /etc/nsswitch.conf

passwd: files
group: files
shadow: files

hosts: files dns
networks: files

protocols: files
services: files
ethers: files
rpc: files

# End /etc/nsswitch.conf
EOF

  # Conteúdo default útil do ld.so.conf (include conf.d)
  # (você pode ajustar depois no seu sistema)
  cat >"$PKG_STAGEDIR/etc/ld.so.conf" <<'EOF'
# Begin /etc/ld.so.conf
include /etc/ld.so.conf.d/*.conf
# End /etc/ld.so.conf
EOF

  # Opcional: gerar cache de libs no stage (sem “executar” binários do target; ldconfig roda no host? NÃO.)
  # Aqui o ldconfig instalado é binário do TARGET (canadian/cross), então não executamos.
  # Você deve executar ldconfig quando estiver no ambiente do target (chroot/boot do target).

  # Higiene (opcional)
  rm -rf "$PKG_STAGEDIR/usr/share/info" 2>/dev/null || true
}

pkg_check() {
  local fail=0

  if [[ ! -f "$PKG_STAGEDIR/usr/include/gnu/libc-version.h" ]]; then
    echo "FALTA: /usr/include/gnu/libc-version.h" >&2
    fail=1
  fi

  # libc.so.6
  if ! find "$PKG_STAGEDIR" -type f -name "libc.so.6" | grep -q .; then
    echo "FALTA: libc.so.6 (glibc runtime)" >&2
    fail=1
  fi

  # loader (nome varia por arch)
  if ! find "$PKG_STAGEDIR" -type f -name "ld-linux*.so.*" | grep -q .; then
    echo "WARN: loader ld-linux*.so.* não encontrado (nome varia por arquitetura/layout)" >&2
  fi

  # arquivos de config criados
  [[ -f "$PKG_STAGEDIR/etc/nsswitch.conf" ]] || { echo "FALTA: /etc/nsswitch.conf" >&2; fail=1; }
  [[ -f "$PKG_STAGEDIR/etc/ld.so.conf" ]]     || { echo "FALTA: /etc/ld.so.conf" >&2; fail=1; }

  return "$fail"
}
