#!/usr/bin/env bash
# mkrootfs-post-bootstrap.sh
# Cria um rootfs completo (mínimo porém “pronto para continuar”), aplica permissões corretas,
# copia BusyBox do staging do bootstrap, cria /etc base, prepara runit skeleton,
# faz mounts seguros e entra em chroot (com ambiente limpo).
#
# Compatível com bootstrap em /mnt/adm/tools (como seu script), com BusyBox em:
#   /mnt/adm/tools/busybox-rootfs
#
# Uso:
#   sudo ./mkrootfs-post-bootstrap.sh /mnt/adm/rootfs
#
# Depois, dentro do chroot, você já pode iniciar o adm e seguir com "adm world".

set -Eeuo pipefail

############################################
# Config padrão (ajuste se quiser)
############################################
ROOTFS="${1:-}"
TOOLS_DIR="${TOOLS_DIR:-/mnt/adm/tools}"
BUSYBOX_STAGE="${BUSYBOX_STAGE:-${TOOLS_DIR}/busybox-rootfs}"
TARGET="${TARGET:-x86_64-linux-musl}"

HOSTNAME_DEFAULT="${HOSTNAME_DEFAULT:-admhost}"
TZ_DEFAULT="${TZ_DEFAULT:-UTC}"

# Montagens
MOUNT_PROC=1
MOUNT_SYS=1
MOUNT_DEV=1
MOUNT_RUN=1
MOUNT_TMP=1

# Dispositivos mínimos (quando não houver devtmpfs/udev)
MAKE_DEV_NODES=1

# Segurança do chroot
CLEAN_ENV=1

############################################
# UI
############################################
ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ echo "[$(ts)] $*"; }
warn(){ echo "[$(ts)] WARN: $*" >&2; }
die(){ echo "[$(ts)] ERRO: $*" >&2; exit 1; }

need(){ command -v "$1" >/dev/null 2>&1 || die "Comando ausente: $1"; }

is_root(){
  [[ "$(id -u)" -eq 0 ]] || die "Execute como root (sudo)."
}

abspath(){
  python3 - <<'PY' "$1"
import os,sys
print(os.path.abspath(sys.argv[1]))
PY
}

############################################
# Sanity checks
############################################
checks(){
  is_root
  need mkdir
  need chmod
  need chown
  need cp
  need rm
  need ln
  need mount
  need umount
  need awk
  need sed
  need tar

  [[ -n "$ROOTFS" ]] || die "Uso: $0 /caminho/para/rootfs"
  ROOTFS="$(abspath "$ROOTFS")"

  [[ -d "$TOOLS_DIR" ]] || die "TOOLS_DIR não existe: $TOOLS_DIR"
  [[ -d "$BUSYBOX_STAGE" ]] || die "BusyBox stage não existe: $BUSYBOX_STAGE"
  [[ -x "${TOOLS_DIR}/bin/${TARGET}-gcc" ]] || warn "Compilador target não encontrado em ${TOOLS_DIR}/bin/${TARGET}-gcc (ok se ainda não copiou toolchain para dentro do rootfs)."
}

############################################
# Rootfs layout + perms
############################################
create_layout(){
  log "Criando layout base do rootfs em: $ROOTFS"
  mkdir -p "$ROOTFS"

  # Diretórios fundamentais
  mkdir -p "$ROOTFS"/{bin,sbin,etc,lib,lib64,usr,var,run,tmp,root,home,proc,sys,dev,mnt,opt}
  mkdir -p "$ROOTFS"/usr/{bin,sbin,lib,lib64,share}
  mkdir -p "$ROOTFS"/var/{log,lib,cache,spool,tmp}
  mkdir -p "$ROOTFS"/etc/{init.d,profile.d,ssl}
  mkdir -p "$ROOTFS"/etc/ssl/certs
  mkdir -p "$ROOTFS"/etc/adm
  mkdir -p "$ROOTFS"/var/lib/adm/{packages,cache,db,logs,conf,work}
  mkdir -p "$ROOTFS"/var/lib/adm/cache/{sources,git,binpkgs}

  # Runit skeleton
  mkdir -p "$ROOTFS"/etc/runit
  mkdir -p "$ROOTFS"/etc/service

  # Permissões seguras
  chmod 0755 "$ROOTFS"
  chmod 0700 "$ROOTFS/root"
  chmod 1777 "$ROOTFS/tmp"
  chmod 1777 "$ROOTFS/var/tmp" || true

  # /run normalmente tmpfs, mas diretório deve existir
  chmod 0755 "$ROOTFS/run"
}

############################################
# Copia BusyBox do staging do bootstrap
############################################
install_busybox_tree(){
  log "Copiando BusyBox stage: $BUSYBOX_STAGE -> $ROOTFS"
  # Copia preservando perms/links
  ( cd "$BUSYBOX_STAGE" && tar -cpf - . ) | ( cd "$ROOTFS" && tar -xpf - )

  # Garante que /bin/sh exista
  if [[ ! -e "$ROOTFS/bin/sh" ]]; then
    if [[ -e "$ROOTFS/bin/busybox" ]]; then
      ln -sf busybox "$ROOTFS/bin/sh"
    else
      warn "Não encontrei /bin/busybox no rootfs; seu stage pode não conter busybox corretamente."
    fi
  fi
}

############################################
# /etc base (fstab, passwd, group, hosts, resolv, profile)
############################################
write_etc_base(){
  log "Criando arquivos base em /etc"

  # fstab mínimo
  cat > "$ROOTFS/etc/fstab" <<'EOF'
# <fs>        <mountpoint> <type>  <opts>                  <dump> <pass>
proc          /proc        proc    nosuid,noexec,nodev     0      0
sysfs         /sys         sysfs   nosuid,noexec,nodev     0      0
devtmpfs      /dev         devtmpfs mode=0755,nosuid       0      0
tmpfs         /run         tmpfs   mode=0755,nosuid,nodev  0      0
tmpfs         /tmp         tmpfs   mode=1777,nosuid,nodev  0      0
EOF
  chmod 0644 "$ROOTFS/etc/fstab"

  # hostname
  echo "$HOSTNAME_DEFAULT" > "$ROOTFS/etc/hostname"
  chmod 0644 "$ROOTFS/etc/hostname"

  # hosts
  cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME_DEFAULT}
::1         localhost ip6-localhost ip6-loopback
EOF
  chmod 0644 "$ROOTFS/etc/hosts"

  # resolv.conf (você pode sobrescrever depois)
  if [[ ! -f "$ROOTFS/etc/resolv.conf" ]]; then
    cat > "$ROOTFS/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    chmod 0644 "$ROOTFS/etc/resolv.conf"
  fi

  # passwd/group mínimos
  if [[ ! -f "$ROOTFS/etc/passwd" ]]; then
    cat > "$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
    chmod 0644 "$ROOTFS/etc/passwd"
  fi

  if [[ ! -f "$ROOTFS/etc/group" ]]; then
    cat > "$ROOTFS/etc/group" <<'EOF'
root:x:0:
EOF
    chmod 0644 "$ROOTFS/etc/group"
  fi

  # profile básico
  cat > "$ROOTFS/etc/profile" <<'EOF'
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
export HOME=/root
export TERM=${TERM:-linux}
umask 022
EOF
  chmod 0644 "$ROOTFS/etc/profile"

  # inittab (se você usar busybox init algum dia; runit não usa)
  if [[ ! -f "$ROOTFS/etc/inittab" ]]; then
    cat > "$ROOTFS/etc/inittab" <<'EOF'
# placeholder (runit será PID1)
EOF
    chmod 0644 "$ROOTFS/etc/inittab"
  fi

  # timezone (placeholder simples)
  mkdir -p "$ROOTFS/etc"
  echo "$TZ_DEFAULT" > "$ROOTFS/etc/timezone"
  chmod 0644 "$ROOTFS/etc/timezone"
}

############################################
# Runit scripts mínimos
############################################
write_runit_skeleton(){
  log "Criando skeleton do runit (scripts 1/2/3)"

  # /etc/runit/1: boot stage
  cat > "$ROOTFS/etc/runit/1" <<'EOF'
#!/bin/sh
PATH=/usr/bin:/usr/sbin:/bin:/sbin
export PATH

mount -a 2>/dev/null || true

# Se devtmpfs não estiver montado (boot diferente), tente montar
mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mountpoint -q /proc || mount -t proc proc /proc 2>/dev/null || true
mountpoint -q /sys  || mount -t sysfs sysfs /sys 2>/dev/null || true
mountpoint -q /run  || mount -t tmpfs tmpfs /run 2>/dev/null || true

# Garante /tmp
chmod 1777 /tmp 2>/dev/null || true

echo "runit stage 1 complete."
EOF
  chmod 0755 "$ROOTFS/etc/runit/1"

  # /etc/runit/2: services stage
  cat > "$ROOTFS/etc/runit/2" <<'EOF'
#!/bin/sh
PATH=/usr/bin:/usr/sbin:/bin:/sbin
export PATH
echo "runit stage 2 (services) starting."
exec runsvdir -P /etc/service
EOF
  chmod 0755 "$ROOTFS/etc/runit/2"

  # /etc/runit/3: shutdown stage
  cat > "$ROOTFS/etc/runit/3" <<'EOF'
#!/bin/sh
PATH=/usr/bin:/usr/sbin:/bin:/sbin
export PATH
echo "runit stage 3 (shutdown)."
umount -a -r 2>/dev/null || true
EOF
  chmod 0755 "$ROOTFS/etc/runit/3"

  # place-holder service: getty (somente exemplo; você pode remover)
  mkdir -p "$ROOTFS/etc/service/getty-tty1"
  cat > "$ROOTFS/etc/service/getty-tty1/run" <<'EOF'
#!/bin/sh
exec getty 38400 tty1 linux
EOF
  chmod 0755 "$ROOTFS/etc/service/getty-tty1/run"

  # Importante: o binário getty pode vir do util-linux ou busybox, dependendo do seu build.
}

############################################
# Dispositivos mínimos (se necessário)
############################################
make_dev_nodes(){
  [[ "$MAKE_DEV_NODES" == "1" ]] || return 0
  log "Criando device nodes mínimos em /dev (caso devtmpfs não esteja disponível)"
  mkdir -p "$ROOTFS/dev"
  # Use mknod se disponível (busybox pode ter)
  if command -v mknod >/dev/null 2>&1; then
    [[ -e "$ROOTFS/dev/console" ]] || mknod -m 600 "$ROOTFS/dev/console" c 5 1 || true
    [[ -e "$ROOTFS/dev/null"    ]] || mknod -m 666 "$ROOTFS/dev/null"    c 1 3 || true
    [[ -e "$ROOTFS/dev/zero"    ]] || mknod -m 666 "$ROOTFS/dev/zero"    c 1 5 || true
    [[ -e "$ROOTFS/dev/tty"     ]] || mknod -m 666 "$ROOTFS/dev/tty"     c 5 0 || true
    [[ -e "$ROOTFS/dev/random"  ]] || mknod -m 444 "$ROOTFS/dev/random"  c 1 8 || true
    [[ -e "$ROOTFS/dev/urandom" ]] || mknod -m 444 "$ROOTFS/dev/urandom" c 1 9 || true
  else
    warn "mknod não disponível; pulei criação de device nodes."
  fi
}

############################################
# Montagens seguras para chroot
############################################
mount_bind(){
  local src="$1" dst="$2"
  mkdir -p "$dst"
  if mountpoint -q "$dst"; then return 0; fi
  mount --bind "$src" "$dst"
  mount -o remount,bind,ro "$dst" 2>/dev/null || true
}

mounts_for_chroot(){
  log "Montando pseudo-filesystems para chroot"
  mkdir -p "$ROOTFS"/{proc,sys,dev,run,tmp}

  # /proc
  if [[ "$MOUNT_PROC" == "1" ]]; then
    mountpoint -q "$ROOTFS/proc" || mount -t proc proc "$ROOTFS/proc"
  fi

  # /sys
  if [[ "$MOUNT_SYS" == "1" ]]; then
    mountpoint -q "$ROOTFS/sys" || mount -t sysfs sysfs "$ROOTFS/sys"
  fi

  # /dev
  if [[ "$MOUNT_DEV" == "1" ]]; then
    mountpoint -q "$ROOTFS/dev" || mount -t devtmpfs devtmpfs "$ROOTFS/dev" 2>/dev/null || true
    # fallback: bind host /dev
    if ! mountpoint -q "$ROOTFS/dev"; then
      mount --bind /dev "$ROOTFS/dev"
    fi
  fi

  # /run
  if [[ "$MOUNT_RUN" == "1" ]]; then
    mountpoint -q "$ROOTFS/run" || mount -t tmpfs tmpfs "$ROOTFS/run" -o mode=0755,nosuid,nodev
  fi

  # /tmp (tmpfs recomendado)
  if [[ "$MOUNT_TMP" == "1" ]]; then
    mountpoint -q "$ROOTFS/tmp" || mount -t tmpfs tmpfs "$ROOTFS/tmp" -o mode=1777,nosuid,nodev
  fi
}

umount_chroot_mounts(){
  log "Desmontando mounts do chroot (best-effort)"
  local m
  for m in "$ROOTFS/tmp" "$ROOTFS/run" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/proc"; do
    if mountpoint -q "$m"; then
      umount -l "$m" 2>/dev/null || true
    fi
  done
}

############################################
# Copiar resolv.conf do host (opcional)
############################################
copy_host_resolv(){
  if [[ -f /etc/resolv.conf ]]; then
    cp -f /etc/resolv.conf "$ROOTFS/etc/resolv.conf" || true
    chmod 0644 "$ROOTFS/etc/resolv.conf" || true
  fi
}

############################################
# Entrar em chroot (seguro)
############################################
enter_chroot(){
  log "Entrando no chroot: $ROOTFS"
  local cmd=("/bin/sh" "-l")

  # Ambiente limpo
  if [[ "$CLEAN_ENV" == "1" ]]; then
    env -i \
      HOME=/root \
      TERM="${TERM:-linux}" \
      PATH=/usr/bin:/usr/sbin:/bin:/sbin \
      SHELL=/bin/sh \
      chroot "$ROOTFS" "${cmd[@]}"
  else
    chroot "$ROOTFS" "${cmd[@]}"
  fi
}

############################################
# Main
############################################
main(){
  checks

  trap 'warn "Saindo... desmontando mounts (best-effort)"; umount_chroot_mounts' EXIT

  create_layout
  install_busybox_tree
  write_etc_base
  write_runit_skeleton
  make_dev_nodes
  copy_host_resolv
  mounts_for_chroot

  log "Rootfs preparado."
  log "Dica: se você ainda não copiou seu adm para dentro do rootfs, coloque em /usr/bin/adm (ou /bin/adm) e /var/lib/adm/..."
  log "Dentro do chroot, você pode seguir com: adm sync ; adm world"

  enter_chroot
}

main "$@"
```0
