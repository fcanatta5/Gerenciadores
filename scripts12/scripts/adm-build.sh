#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# adm-build.sh
# Cross-toolchain temporário + chroot seguro + validação gcc dentro do chroot
###############################################################################

# =========================
# CONFIGURÁVEIS NO TOPO
# =========================
ROOT="/mnt/adm"
TOOLS="$ROOT/tools"
BUILD="$ROOT/build"
SRC="$ROOT/sources"

TARGET="x86_64-linux-musl"

BINUTILS_VER="2.42"
GCC_VER="13.2.0"
MUSL_VER="1.2.5"
LINUX_HEADERS_VER="6.6.8"

MAKEFLAGS="-j$(nproc)"

HOST_RESOLV="/etc/resolv.conf"
CHROOT_SHELL="/bin/bash"

# Mounts esperados no chroot (ordem importa)
MOUNTS=( "dev" "dev/pts" "proc" "sys" "run" )

# Ambiente ao entrar no chroot (PATH inclui /tools/bin)
CHROOT_ENV_VARS=(
  "HOME=/root"
  "TERM=${TERM:-xterm-256color}"
  "PS1=(adm) \\u:\\w\\$ "
  "PATH=/usr/bin:/usr/sbin:/bin:/sbin:/tools/bin"
  "LANG=C"
  "LC_ALL=C"
)

###############################################################################
# UTILITÁRIOS
###############################################################################
msg()  { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33mAVISO: %s\033[0m\n" "$*"; }
die()  { printf "\n\033[1;31mERRO: %s\033[0m\n" "$*"; exit 1; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Execute como root."; }

ensure_dir() { mkdir -p "$1"; }

mounted() { mountpoint -q "$1"; }

cleanup_build_dir() {
  rm -rf "$BUILD"
  mkdir -p "$BUILD"
}

require_tarball() {
  local f="$1"
  [[ -r "$SRC/$f" ]] || die "Tarball ausente: $SRC/$f"
}

host_prereq_check() {
  command -v gcc >/dev/null || die "gcc do host não encontrado"
  command -v g++ >/dev/null || warn "g++ não encontrado (pode ser necessário para alguns fluxos do GCC)"
  command -v make >/dev/null || die "make não encontrado"
  command -v bison >/dev/null || warn "bison não encontrado (pode ser necessário)"
  command -v flex  >/dev/null || warn "flex não encontrado (pode ser necessário)"
  command -v awk   >/dev/null || die "awk não encontrado"
  command -v tar   >/dev/null || die "tar não encontrado"
  command -v xz    >/dev/null || warn "xz não encontrado (tar.xz pode falhar)"
  command -v readelf >/dev/null || die "readelf não encontrado (binutils no host requerido para validar)"
}

###############################################################################
# CHROOT: SETUP / CLEANUP
###############################################################################
assert_rootfs_minimum() {
  ensure_dir "$ROOT"/{dev,proc,sys,run,etc,root,tmp,var,usr}
  chmod 1777 "$ROOT/tmp" || true
}

copy_resolv() {
  ensure_dir "$ROOT/etc"
  if [[ -r "$HOST_RESOLV" ]]; then
    cp -L "$HOST_RESOLV" "$ROOT/etc/resolv.conf"
  else
    warn "Não foi possível ler $HOST_RESOLV; DNS no chroot pode falhar."
  fi
}

mount_dev() {
  ensure_dir "$ROOT/dev"
  mounted "$ROOT/dev" || mount --bind /dev "$ROOT/dev"
}
mount_dev_pts() {
  ensure_dir "$ROOT/dev/pts"
  mounted "$ROOT/dev/pts" || mount -t devpts devpts "$ROOT/dev/pts" -o gid=5,mode=620
}
mount_proc() {
  ensure_dir "$ROOT/proc"
  mounted "$ROOT/proc" || mount -t proc proc "$ROOT/proc"
}
mount_sys() {
  ensure_dir "$ROOT/sys"
  mounted "$ROOT/sys" || mount -t sysfs sysfs "$ROOT/sys"
}
mount_run() {
  ensure_dir "$ROOT/run"
  mounted "$ROOT/run" || mount --bind /run "$ROOT/run"
}

umount_one() {
  local p="$1"
  if mounted "$p"; then
    umount "$p" || umount -l "$p" || die "Falha ao desmontar: $p"
  fi
}

umount_all() {
  local i
  for (( i=${#MOUNTS[@]}-1; i>=0; i-- )); do
    umount_one "$ROOT/${MOUNTS[$i]}"
  done
}

ensure_tools_in_chroot() {
  # Garante /tools dentro do rootfs e /tools/bin no PATH dentro do chroot
  ensure_dir "$TOOLS"
  ensure_dir "$ROOT/tools"
  # Preferimos bind-mount real para evitar edge cases com symlink
  if ! mounted "$ROOT/tools"; then
    mount --bind "$TOOLS" "$ROOT/tools"
  fi
  [[ -d "$ROOT/tools/bin" ]] || die "/tools/bin não existe dentro do chroot (bind de tools falhou?)"
}

chroot_setup() {
  need_root
  assert_rootfs_minimum
  copy_resolv
  mount_dev
  mount_dev_pts
  mount_proc
  mount_sys
  mount_run
  ensure_tools_in_chroot
}

chroot_enter() {
  need_root
  chroot_setup >/dev/null

  # Escolhe shell
  local sh="$CHROOT_SHELL"
  if [[ ! -x "$ROOT/$sh" ]]; then
    [[ -x "$ROOT/bin/sh" ]] && sh="/bin/sh" || die "Nenhum shell encontrado em $ROOT (bash/sh)."
    warn "bash não encontrado; usando /bin/sh."
  fi

  local env_args=()
  local kv
  for kv in "${CHROOT_ENV_VARS[@]}"; do env_args+=( "$kv" ); done

  exec chroot "$ROOT" /usr/bin/env -i "${env_args[@]}" "$sh" -l
}

chroot_exit() {
  need_root
  # desmonta tools bind primeiro
  if mounted "$ROOT/tools"; then umount_one "$ROOT/tools"; fi
  umount_all
}

###############################################################################
# CROSS TOOLCHAIN TEMPORÁRIO
###############################################################################
export_tool_env() {
  export PATH="$TOOLS/bin:$PATH"
  export LC_ALL=POSIX
  export CONFIG_SITE=/dev/null
}

binutils_build() {
  msg "Binutils ${BINUTILS_VER}"
  require_tarball "binutils-${BINUTILS_VER}.tar.xz"
  cleanup_build_dir
  tar -xf "$SRC/binutils-${BINUTILS_VER}.tar.xz" -C "$BUILD"
  mkdir -p "$BUILD/binutils-build"
  cd "$BUILD/binutils-build"

  "$BUILD/binutils-${BINUTILS_VER}/configure" \
    --prefix="$TOOLS" \
    --target="$TARGET" \
    --with-sysroot \
    --disable-nls \
    --disable-werror

  make $MAKEFLAGS
  make install
}

linux_headers_install() {
  msg "Linux Headers ${LINUX_HEADERS_VER}"
  require_tarball "linux-${LINUX_HEADERS_VER}.tar.xz"
  cleanup_build_dir
  tar -xf "$SRC/linux-${LINUX_HEADERS_VER}.tar.xz" -C "$BUILD"
  cd "$BUILD/linux-${LINUX_HEADERS_VER}"

  make mrproper
  make headers
  find usr/include -type f ! -name '*.h' -delete

  # instala em sysroot do target
  mkdir -p "$TOOLS/$TARGET"
  cp -rv usr/include "$TOOLS/$TARGET"
}

musl_headers_crt_install() {
  msg "musl headers+crt ${MUSL_VER}"
  require_tarball "musl-${MUSL_VER}.tar.gz"
  cleanup_build_dir
  tar -xf "$SRC/musl-${MUSL_VER}.tar.gz" -C "$BUILD"
  cd "$BUILD/musl-${MUSL_VER}"

  ./configure --prefix="/usr" --target="$TARGET"
  make install-headers DESTDIR="$TOOLS/$TARGET"
  make install-crt DESTDIR="$TOOLS/$TARGET"
}

gcc_step1_build() {
  msg "GCC ${GCC_VER} (step1: c + libgcc)"
  require_tarball "gcc-${GCC_VER}.tar.xz"
  cleanup_build_dir
  tar -xf "$SRC/gcc-${GCC_VER}.tar.xz" -C "$BUILD"
  cd "$BUILD/gcc-${GCC_VER}"

  ./contrib/download_prerequisites

  mkdir -p "$BUILD/gcc-build"
  cd "$BUILD/gcc-build"

  "$BUILD/gcc-${GCC_VER}/configure" \
    --target="$TARGET" \
    --prefix="$TOOLS" \
    --with-sysroot="$TOOLS/$TARGET" \
    --disable-nls \
    --disable-multilib \
    --disable-libsanitizer \
    --disable-libquadmath \
    --disable-libssp \
    --disable-libvtv \
    --enable-languages=c

  make $MAKEFLAGS all-gcc
  make $MAKEFLAGS all-target-libgcc
  make install-gcc
  make install-target-libgcc
}

musl_full_build() {
  msg "musl completo ${MUSL_VER}"
  require_tarball "musl-${MUSL_VER}.tar.gz"
  cleanup_build_dir
  tar -xf "$SRC/musl-${MUSL_VER}.tar.gz" -C "$BUILD"
  cd "$BUILD/musl-${MUSL_VER}"

  CC="$TARGET-gcc" ./configure --prefix="/usr"
  make $MAKEFLAGS
  make install DESTDIR="$TOOLS/$TARGET"
}

toolchain_verify_host() {
  msg "Validando toolchain no host (fora do chroot)"
  command -v "$TARGET-gcc" >/dev/null || die "$TARGET-gcc não encontrado em PATH (TOOLS/bin)."
  "$TARGET-gcc" -v >/dev/null 2>&1 || die "Falha ao executar $TARGET-gcc."

  cat > "$BUILD/test-host.c" <<'EOF'
int main(void){return 0;}
EOF
  "$TARGET-gcc" "$BUILD/test-host.c" -o "$BUILD/test-host"
  readelf -h "$BUILD/test-host" >/dev/null || die "ELF inválido (readelf falhou)."
  msg "OK: compilação fora do chroot funcional."
}

###############################################################################
# VALIDAÇÃO DENTRO DO CHROOT
###############################################################################
toolchain_verify_in_chroot() {
  msg "Validando $TARGET-gcc dentro do chroot"

  chroot_setup >/dev/null

  # script de teste executado dentro do chroot
  cat > "$ROOT/root/.toolchain-test.sh" <<EOF
#!/bin/sh
set -eu

# PATH deve conter /tools/bin primeiro (forçado via env -i)
command -v ${TARGET}-gcc >/dev/null 2>&1 || { echo "NOK: ${TARGET}-gcc não no PATH"; exit 1; }

# Compila um binário simples
cat > /tmp/t.c <<'EOT'
int main(void){return 0;}
EOT

${TARGET}-gcc /tmp/t.c -o /tmp/t

# valida ELF e interpreter (se for dinâmico)
if command -v readelf >/dev/null 2>&1; then
  readelf -h /tmp/t >/dev/null
  # musl normalmente usa interpreter /lib/ld-musl-x86_64.so.1 (dentro do sysroot/target)
  # Aqui apenas confirmamos que existe um interpreter no ELF (quando dinâmico).
  if readelf -l /tmp/t | grep -q 'interpreter'; then
    readelf -l /tmp/t | grep interpreter >/dev/null
  fi
fi

echo "OK: ${TARGET}-gcc funcionou dentro do chroot."
exit 0
EOF
  chmod +x "$ROOT/root/.toolchain-test.sh"

  # executa no chroot com ambiente controlado
  local env_args=()
  local kv
  for kv in "${CHROOT_ENV_VARS[@]}"; do env_args+=( "$kv" ); done

  chroot "$ROOT" /usr/bin/env -i "${env_args[@]}" /bin/sh -lc "/root/.toolchain-test.sh" \
    || { chroot_exit >/dev/null || true; die "Falha no teste do toolchain dentro do chroot."; }

  rm -f "$ROOT/root/.toolchain-test.sh" || true

  msg "Validação dentro do chroot: OK."
}

###############################################################################
# COMANDOS
###############################################################################
build_toolchain() {
  need_root
  host_prereq_check
  ensure_dir "$ROOT" "$TOOLS" "$BUILD" "$SRC"
  export_tool_env

  binutils_build
  linux_headers_install
  musl_headers_crt_install
  gcc_step1_build
  musl_full_build

  toolchain_verify_host
}

chroot_status() {
  msg "Status de mounts em $ROOT"
  for m in "${MOUNTS[@]}"; do
    if mounted "$ROOT/$m"; then echo "MONTADO : $ROOT/$m"; else echo "NÃO     : $ROOT/$m"; fi
  done
  if mounted "$ROOT/tools"; then echo "MONTADO : $ROOT/tools"; else echo "NÃO     : $ROOT/tools"; fi
  echo
  [[ -d "$ROOT/tools/bin" ]] && echo "OK  : /tools/bin existe no rootfs" || echo "NOK : /tools/bin ausente no rootfs"
  command -v "$TARGET-gcc" >/dev/null 2>&1 && echo "OK  : $TARGET-gcc no host PATH" || echo "NOK : $TARGET-gcc não no host PATH"
}

cleanup_all() {
  need_root
  chroot_exit || true
  msg "Cleanup finalizado."
}

usage() {
  cat <<EOF
Uso:
  $0 toolchain-build    -> constrói cross-toolchain temporário em $TOOLS
  $0 chroot-setup       -> prepara mounts + garante /tools bind no chroot
  $0 chroot-enter       -> entra no chroot com PATH incluindo /tools/bin
  $0 chroot-exit        -> desmonta tudo (saída limpa)
  $0 verify-host        -> valida ${TARGET}-gcc fora do chroot
  $0 verify-chroot      -> valida ${TARGET}-gcc dentro do chroot
  $0 status             -> status de mounts e checagens rápidas
  $0 cleanup            -> desmonta o que estiver montado

Pré-requisito: tarballs em $SRC com nomes padrão.
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    toolchain-build) build_toolchain ;;
    chroot-setup)    need_root; chroot_setup; msg "Setup do chroot OK."; chroot_status ;;
    chroot-enter)    chroot_enter ;;
    chroot-exit)     chroot_exit; msg "Chroot desmontado com sucesso."; chroot_status ;;
    verify-host)     need_root; export_tool_env; toolchain_verify_host ;;
    verify-chroot)   toolchain_verify_in_chroot; cleanup_all ;;
    status)          chroot_status ;;
    cleanup)         cleanup_all ;;
    ""|help|-h|--help) usage ;;
    *) die "Comando inválido: $cmd (use: $0 help)" ;;
  esac
}

main "$@"
