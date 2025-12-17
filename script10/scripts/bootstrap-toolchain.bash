#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# bootstrap-toolchain.bash
# Host -> prepara /mnt/adm/rootfs e toolchain cross em /mnt/adm/tools/cross
# Target: x86_64-linux-musl
# Trust base: GCC do host
# ============================================================

# -------------------------
# Config
# -------------------------
TOP="${TOP:-/mnt/adm}"
ROOTFS="${ROOTFS:-$TOP/rootfs}"
TOOLS="${TOOLS:-$TOP/tools}"
CROSS_PREFIX="${CROSS_PREFIX:-$TOOLS/cross}"

STATE="${STATE:-$TOP/state}"
DIST="${DIST:-$STATE/distfiles}"
BUILD="${BUILD:-$STATE/build}"
LOGDIR="${LOGDIR:-$STATE/logs}"
LOCKDIR="${LOCKDIR:-$STATE/locks}"

TARGET="${TARGET:-x86_64-linux-musl}"
ARCH="${ARCH:-x86_64}"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
RESUME="${RESUME:-1}"
CHECKSUM_STRICT="${CHECKSUM_STRICT:-0}"  # 1 = exige sha256 em tudo

# Versões (ajuste quando quiser)
BINUTILS_VER="${BINUTILS_VER:-2.42}"
GCC_VER="${GCC_VER:-14.2.0}"
MUSL_VER="${MUSL_VER:-1.2.5}"
LINUX_VER="${LINUX_VER:-6.6.8}"         # headers kernel (LTS; ajuste se preferir)
BUSYBOX_VER="${BUSYBOX_VER:-1.36.1}"
RUNIT_VER="${RUNIT_VER:-2.1.2}"

# GCC deps (in-tree, evita depender de libs dev do host)
GMP_VER="${GMP_VER:-6.3.0}"
MPFR_VER="${MPFR_VER:-4.2.1}"
MPC_VER="${MPC_VER:-1.3.1}"
ISL_VER="${ISL_VER:-0.26}"

# URLs
BINUTILS_URL="https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz"
GCC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz"
MUSL_URL="https://musl.libc.org/releases/musl-${MUSL_VER}.tar.gz"
LINUX_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VER}.tar.xz"
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2"
RUNIT_URL="https://smarden.org/runit/runit-${RUNIT_VER}.tar.gz"

GMP_URL="https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz"
MPFR_URL="https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VER}.tar.xz"
MPC_URL="https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.gz"
ISL_URL="https://libisl.sourceforge.io/isl-${ISL_VER}.tar.xz"

# musl security patches (CVE-2025-26519) - você já levantou isso.
# Recomendação: manter esses patches no seu repo de recipes também.
MUSL_PATCH1_URL="https://git.musl-libc.org/cgit/musl/patch/?id=e5adcd97b5196e29991b524237381a0202a60659"
MUSL_PATCH2_URL="https://git.musl-libc.org/cgit/musl/patch/?id=c47ad25ea3b484e10326f933e927c0bc8cded3da"

# -------------------------
# UI / Logs
# -------------------------
C_RESET=$'\e[0m'; C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[34m'
ts(){ date +"%Y-%m-%d %H:%M:%S"; }

mkdir -p "$DIST" "$BUILD" "$LOGDIR" "$LOCKDIR"
LOG="$LOGDIR/bootstrap-toolchain.log"

msg(){ echo "${C_BLU}==>${C_RESET} $*" | tee -a "$LOG" >&2; }
ok(){  echo "${C_GRN}OK${C_RESET}  $*" | tee -a "$LOG" >&2; }
warn(){echo "${C_YLW}WARN${C_RESET} $*" | tee -a "$LOG" >&2; }
die(){ echo "${C_RED}ERRO${C_RESET} $*" | tee -a "$LOG" >&2; exit 1; }

need(){ command -v "$1" >/dev/null 2>&1 || die "Dependência ausente no host: $1"; }

lock_or_die(){
  need flock
  exec 9>"$LOCKDIR/bootstrap-toolchain.lock"
  flock -n 9 || die "bootstrap já está rodando (lock ativo)"
}

# download com resume + progresso
fetch(){
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  if [[ -f "$out" ]]; then
    ok "cache hit: $(basename "$out")"
    return 0
  fi
  msg "download: $url"
  if command -v curl >/dev/null 2>&1; then
    if [[ "$RESUME" == "1" ]]; then
      curl -L --fail --retry 3 -C - --progress-bar -o "$out.part" "$url"
    else
      curl -L --fail --retry 3 --progress-bar -o "$out.part" "$url"
    fi
    mv -f "$out.part" "$out"
  elif command -v wget >/dev/null 2>&1; then
    if [[ "$RESUME" == "1" ]]; then
      wget -c --show-progress -O "$out.part" "$url"
    else
      wget --show-progress -O "$out.part" "$url"
    fi
    mv -f "$out.part" "$out"
  else
    die "nem curl nem wget"
  fi
}

sha256_file(){ sha256sum "$1" | awk '{print $1}'; }

verify_sha256(){
  local file="$1" sha="${2:-}"
  if [[ -z "$sha" ]]; then
    if [[ "$CHECKSUM_STRICT" == "1" ]]; then
      die "sha256 obrigatório e não fornecido para: $(basename "$file")"
    fi
    warn "sha256 não fornecido para $(basename "$file") (CHECKSUM_STRICT=0)"
    return 0
  fi
  need sha256sum
  echo "$sha  $file" | sha256sum -c - >/dev/null || die "SHA256 inválido: $(basename "$file")"
}

extract(){
  local arc="$1" dir="$2"
  rm -rf "$dir"; mkdir -p "$dir"
  case "$arc" in
    *.tar.gz|*.tgz)  tar -xzf "$arc" -C "$dir" --strip-components=1 ;;
    *.tar.xz)        tar -xJf "$arc" -C "$dir" --strip-components=1 ;;
    *.tar.bz2)       tar -xjf "$arc" -C "$dir" --strip-components=1 ;;
    *.tar)           tar -xf "$arc" -C "$dir" --strip-components=1 ;;
    *) die "arquivo desconhecido: $arc" ;;
  esac
}

run_logged(){
  local name="$1"; shift
  local lf="$LOGDIR/${name}.log"
  msg "log: $lf"
  "$@" >"$lf" 2>&1 || die "falha em '$name' (veja $lf)"
}

# -------------------------
# Preparação de dirs
# -------------------------
prepare_layout(){
  msg "criando layout em $ROOTFS e $CROSS_PREFIX"
  mkdir -p \
    "$ROOTFS"/{bin,sbin,etc,proc,sys,dev,run,tmp,root,home} \
    "$ROOTFS"/usr/{bin,sbin,lib,include} \
    "$ROOTFS"/var/{log,cache,lib} \
    "$ROOTFS"/etc/{service,runit} \
    "$ROOTFS"/var/cache/adm/{distfiles,build,pkgs} \
    "$ROOTFS"/var/lib/adm/{db,recipes,manifests} \
    "$TOOLS" "$CROSS_PREFIX"

  chmod 1777 "$ROOTFS/tmp"
  ok "layout pronto"
}

# -------------------------
# Build helpers
# -------------------------
export PATH="$CROSS_PREFIX/bin:$PATH"

host_prereqs(){
  msg "checando dependências do host"
  need bash
  need make
  need tar
  need xz
  need bzip2
  need gzip
  need patch
  need sed
  need awk
  need find
  need install
  need gcc
  need g++
  ok "host ok"
}

# -------------------------
# 1) Binutils (cross)
# -------------------------
build_binutils(){
  msg "binutils ${BINUTILS_VER}"
  local arc="$DIST/binutils-${BINUTILS_VER}.tar.xz"
  local src="$BUILD/binutils-${BINUTILS_VER}.src"
  local bld="$BUILD/binutils-${BINUTILS_VER}.build"

  fetch "$BINUTILS_URL" "$arc"
  extract "$arc" "$src"
  rm -rf "$bld"; mkdir -p "$bld"

  run_logged "binutils-configure" bash -c "
    cd '$bld'
    '$src/configure' \
      --prefix='$CROSS_PREFIX' \
      --target='$TARGET' \
      --with-sysroot='$ROOTFS' \
      --disable-nls \
      --disable-werror
  "
  run_logged "binutils-make" bash -c "cd '$bld' && make -j'$JOBS'"
  run_logged "binutils-install" bash -c "cd '$bld' && make install"

  ok "binutils instalado em $CROSS_PREFIX"
}

# -------------------------
# 2) Linux headers (sysroot)
# -------------------------
install_linux_headers(){
  msg "linux headers ${LINUX_VER}"
  local arc="$DIST/linux-${LINUX_VER}.tar.xz"
  local src="$BUILD/linux-${LINUX_VER}.src"

  fetch "$LINUX_URL" "$arc"
  extract "$arc" "$src"

  run_logged "linux-headers" bash -c "
    cd '$src'
    make mrproper
    make ARCH='x86_64' headers_check
    make ARCH='x86_64' INSTALL_HDR_PATH='$ROOTFS/usr' headers_install
  "
  ok "headers instalados em $ROOTFS/usr/include"
}

# -------------------------
# 3) GCC deps (in-tree) + GCC stage1
# -------------------------
prepare_gcc_deps_in_tree(){
  msg "GCC deps in-tree"
  local gcc_arc="$DIST/gcc-${GCC_VER}.tar.xz"
  local gcc_src="$BUILD/gcc-${GCC_VER}.src"

  fetch "$GCC_URL" "$gcc_arc"
  extract "$gcc_arc" "$gcc_src"

  # baixar deps
  fetch "$GMP_URL"  "$DIST/gmp-${GMP_VER}.tar.xz"
  fetch "$MPFR_URL" "$DIST/mpfr-${MPFR_VER}.tar.xz"
  fetch "$MPC_URL"  "$DIST/mpc-${MPC_VER}.tar.gz"
  fetch "$ISL_URL"  "$DIST/isl-${ISL_VER}.tar.xz"

  # extrair dentro da tree do gcc (método comum)
  rm -rf "$gcc_src"/{gmp,mpfr,mpc,isl}
  mkdir -p "$gcc_src/_deps"

  extract "$DIST/gmp-${GMP_VER}.tar.xz"  "$gcc_src/_deps/gmp"
  extract "$DIST/mpfr-${MPFR_VER}.tar.xz" "$gcc_src/_deps/mpfr"
  extract "$DIST/mpc-${MPC_VER}.tar.gz"  "$gcc_src/_deps/mpc"
  extract "$DIST/isl-${ISL_VER}.tar.xz"  "$gcc_src/_deps/isl"

  mv "$gcc_src/_deps/gmp"  "$gcc_src/gmp"
  mv "$gcc_src/_deps/mpfr" "$gcc_src/mpfr"
  mv "$gcc_src/_deps/mpc"  "$gcc_src/mpc"
  mv "$gcc_src/_deps/isl"  "$gcc_src/isl"
  rm -rf "$gcc_src/_deps"

  ok "deps embutidas no gcc-${GCC_VER}.src"
}

build_gcc_stage1(){
  msg "GCC stage1 ${GCC_VER}"
  local src="$BUILD/gcc-${GCC_VER}.src"
  local bld="$BUILD/gcc-${GCC_VER}.stage1.build"

  rm -rf "$bld"; mkdir -p "$bld"

  run_logged "gcc1-configure" bash -c "
    cd '$bld'
    '$src/configure' \
      --prefix='$CROSS_PREFIX' \
      --target='$TARGET' \
      --with-sysroot='$ROOTFS' \
      --disable-nls \
      --enable-languages=c \
      --without-headers \
      --disable-shared \
      --disable-threads \
      --disable-libatomic \
      --disable-libgomp \
      --disable-libquadmath \
      --disable-libssp \
      --disable-libvtv \
      --disable-libstdcxx
  "
  run_logged "gcc1-make" bash -c "cd '$bld' && make -j'$JOBS' all-gcc"
  run_logged "gcc1-install" bash -c "cd '$bld' && make install-gcc"

  ok "gcc stage1 instalado"
}

# -------------------------
# 4) musl (sysroot) + security patches
# -------------------------
fetch_musl_patches(){
  mkdir -p "$DIST/musl-patches"
  fetch "$MUSL_PATCH1_URL" "$DIST/musl-patches/0001-iconv-euckr-validation.patch"
  fetch "$MUSL_PATCH2_URL" "$DIST/musl-patches/0002-iconv-utf8-harden.patch"
}

build_musl(){
  msg "musl ${MUSL_VER} (sysroot)"
  local arc="$DIST/musl-${MUSL_VER}.tar.gz"
  local src="$BUILD/musl-${MUSL_VER}.src"
  local bld="$BUILD/musl-${MUSL_VER}.build"

  fetch "$MUSL_URL" "$arc"
  extract "$arc" "$src"
  rm -rf "$bld"; mkdir -p "$bld"

  fetch_musl_patches
  # aplica patches no src
  run_logged "musl-patch" bash -c "
    cd '$src'
    patch -p1 --forward --batch <'$DIST/musl-patches/0001-iconv-euckr-validation.patch'
    patch -p1 --forward --batch <'$DIST/musl-patches/0002-iconv-utf8-harden.patch'
  "

  # compila com cross gcc stage1
  local cc="$CROSS_PREFIX/bin/$TARGET-gcc"
  [[ -x "$cc" ]] || die "cross gcc não encontrado: $cc"

  run_logged "musl-configure" bash -c "
    cd '$src'
    CC='$cc' ./configure --prefix=/usr --syslibdir=/lib --disable-gcc-wrapper
  "
  run_logged "musl-make" bash -c "cd '$src' && make -j'$JOBS'"
  run_logged "musl-install" bash -c "cd '$src' && DESTDIR='$ROOTFS' make install"

  # garante ld-musl path
  mkdir -p "$ROOTFS/etc"
  printf "%s\n" "/usr/lib" "/lib" >"$ROOTFS/etc/ld-musl-x86_64.path"

  ok "musl instalado em $ROOTFS"
}

# -------------------------
# 5) GCC final (C/C++)
# -------------------------
build_gcc_final(){
  msg "GCC final ${GCC_VER}"
  local src="$BUILD/gcc-${GCC_VER}.src"
  local bld="$BUILD/gcc-${GCC_VER}.final.build"

  rm -rf "$bld"; mkdir -p "$bld"

  run_logged "gccf-configure" bash -c "
    cd '$bld'
    '$src/configure' \
      --prefix='$CROSS_PREFIX' \
      --target='$TARGET' \
      --with-sysroot='$ROOTFS' \
      --disable-nls \
      --enable-languages=c,c++ \
      --disable-multilib
  "
  run_logged "gccf-make" bash -c "cd '$bld' && make -j'$JOBS'"
  run_logged "gccf-install" bash -c "cd '$bld' && make install"

  ok "gcc final instalado"
}

# -------------------------
# 6) BusyBox (rootfs base)
# -------------------------
build_busybox(){
  msg "busybox ${BUSYBOX_VER} (estático para bootstrap)"
  local arc="$DIST/busybox-${BUSYBOX_VER}.tar.bz2"
  local src="$BUILD/busybox-${BUSYBOX_VER}.src"

  fetch "$BUSYBOX_URL" "$arc"
  extract "$arc" "$src"

  local cc="$CROSS_PREFIX/bin/$TARGET-gcc"
  [[ -x "$cc" ]] || die "cross gcc não encontrado: $cc"

  run_logged "busybox-build" bash -c "
    cd '$src'
    make distclean
    make defconfig
    sed -i \
      -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
      -e 's/^# CONFIG_FEATURE_SH_STANDALONE is not set/CONFIG_FEATURE_SH_STANDALONE=y/' \
      .config || true
    make -j'$JOBS' CC='$cc' AR='$CROSS_PREFIX/bin/$TARGET-ar' RANLIB='$CROSS_PREFIX/bin/$TARGET-ranlib'
    make CONFIG_PREFIX='$ROOTFS' install
  "
  ln -sf busybox "$ROOTFS/bin/sh"
  ok "busybox instalado"
}

# -------------------------
# 7) runit (rootfs)
# -------------------------
build_runit(){
  msg "runit ${RUNIT_VER}"
  local arc="$DIST/runit-${RUNIT_VER}.tar.gz"
  local src="$BUILD/runit-${RUNIT_VER}.src"

  fetch "$RUNIT_URL" "$arc"
  extract "$arc" "$src"

  local cc="$CROSS_PREFIX/bin/$TARGET-gcc"
  [[ -x "$cc" ]] || die "cross gcc não encontrado: $cc"

  # runit usa conf-cc; forçamos
  run_logged "runit-build" bash -c "
    cd '$src'
    printf '%s\n' '$cc' > src/conf-cc
    printf '%s\n' '$CROSS_PREFIX/bin/$TARGET-ar' > src/conf-ar
    package/compile
    install -Dm755 -t '$ROOTFS/usr/bin' command/{runsvdir,runsv,sv,chpst,runit,runsvchdir}
  "
  [[ -x "$ROOTFS/usr/bin/runsvdir" ]] || die "runit não instalou runsvdir"
  ok "runit instalado"
}

configure_runit_stages(){
  msg "configurando runit stages"
  mkdir -p "$ROOTFS/etc/runit" "$ROOTFS/etc/service" "$ROOTFS/var/log"

  cat >"$ROOTFS/etc/runit/1" <<'EOF'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sys /sys 2>/dev/null || true
mount -t devtmpfs dev /dev 2>/dev/null || true
mkdir -p /run /tmp
chmod 1777 /tmp
[ -f /etc/hostname ] && hostname "$(cat /etc/hostname)" 2>/dev/null || true
exec /usr/bin/runsvdir -P /etc/service
EOF
  chmod +x "$ROOTFS/etc/runit/1"

  cat >"$ROOTFS/etc/runit/2" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$ROOTFS/etc/runit/2"

  cat >"$ROOTFS/etc/runit/3" <<'EOF'
#!/bin/sh
sync
umount -a -r 2>/dev/null || true
EOF
  chmod +x "$ROOTFS/etc/runit/3"

  mkdir -p "$ROOTFS/etc/service/syslog"
  cat >"$ROOTFS/etc/service/syslog/run" <<'EOF'
#!/bin/sh
exec /bin/busybox syslogd -n
EOF
  chmod +x "$ROOTFS/etc/service/syslog/run"
  ok "runit stages prontos"
}

# -------------------------
# 8) /etc mínimo + (placeholder) adm install
# -------------------------
seed_etc(){
  msg "criando /etc mínimo"
  cat >"$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
  cat >"$ROOTFS/etc/group" <<'EOF'
root:x:0:
EOF
  echo "adm-musl" >"$ROOTFS/etc/hostname"
  ok "/etc pronto"
}

install_adm_placeholder(){
  msg "instalando placeholder do adm (você substituirá pelo seu adm final)"
  mkdir -p "$ROOTFS/usr/sbin" "$ROOTFS/var/lib/adm/recipes"
  cat >"$ROOTFS/usr/sbin/adm" <<'EOF'
#!/bin/sh
echo "adm ainda não foi instalado neste rootfs."
echo "Substitua /usr/sbin/adm pelo seu script final e adicione recipes em /var/lib/adm/recipes."
exit 1
EOF
  chmod +x "$ROOTFS/usr/sbin/adm"
  ok "placeholder instalado"
}

# -------------------------
# Sanity checks (alvo pronto p/ adm)
# -------------------------
sanity(){
  msg "sanity checks"
  [[ -x "$CROSS_PREFIX/bin/$TARGET-gcc" ]] || die "toolchain incompleto: $TARGET-gcc"
  [[ -x "$CROSS_PREFIX/bin/$TARGET-ld" ]] || die "toolchain incompleto: $TARGET-ld"
  [[ -f "$ROOTFS/lib/ld-musl-x86_64.so.1" ]] || die "musl loader ausente em $ROOTFS/lib"
  [[ -x "$ROOTFS/bin/busybox" ]] || die "busybox ausente"
  [[ -x "$ROOTFS/usr/bin/runsvdir" ]] || die "runit ausente"
  ok "sanity ok"
}

# -------------------------
# Main
# -------------------------
main(){
  lock_or_die
  host_prereqs
  prepare_layout

  build_binutils
  install_linux_headers
  prepare_gcc_deps_in_tree
  build_gcc_stage1
  build_musl
  build_gcc_final

  build_busybox
  build_runit
  configure_runit_stages
  seed_etc
  install_adm_placeholder

  sanity

  cat <<EOF

============================================================
Bootstrap concluído.

Toolchain cross:
  $CROSS_PREFIX/bin/$TARGET-gcc
  $CROSS_PREFIX/bin/$TARGET-ld

Rootfs alvo:
  $ROOTFS

Próximos passos (host):
  sudo mount --bind /dev  "$ROOTFS/dev"
  sudo mount --bind /proc "$ROOTFS/proc"
  sudo mount --bind /sys  "$ROOTFS/sys"

Entrar no chroot:
  sudo chroot "$ROOTFS" /bin/sh

Dentro do chroot:
  - Substitua /usr/sbin/adm pelo seu adm final (o avançado).
  - Coloque seu repo git de recipes em /var/lib/adm/recipes e rode:
      adm sync
      adm upgrade-all

Observação:
  Este bootstrap NÃO instala eudev/sway/llvm.
  Ele deixa o toolchain e a base (musl+busybox+runit) prontos para o adm assumir.
============================================================

EOF
}

main "$@"
