#!/usr/bin/env bash
# adm_chroot.sh — prepara um chroot completo para uso do adm.sh dentro do rootfs do profile
#
# Comandos:
#   adm_chroot.sh mount  <profile>     # monta /proc /sys /dev /dev/pts /run /tmp e bind de /opt/adm
#   adm_chroot.sh enter  <profile>     # entra no chroot com ambiente adequado
#   adm_chroot.sh umount <profile>     # desmonta em ordem segura
#   adm_chroot.sh status <profile>     # mostra status de mounts e pré-requisitos
#   adm_chroot.sh fix    <profile>     # cria arquivos mínimos /etc e /bin/sh quando faltarem
#
# Variáveis:
#   ADM_ROOT=/opt/adm                  # base do adm no host
#   CHROOT_ADM_BIND=1                  # 1: bind-mount /opt/adm host->chroot; 0: copia (uma vez)
#   CHROOT_COPY_NET=1                  # 1: copia resolv.conf; 0: não
#   CHROOT_TMPFS=1                     # 1: monta tmpfs em /tmp
#   CHROOT_RUN_BIND=1                  # 1: bind-mount /run
#
set -euo pipefail
set -o errtrace

ADM_ROOT="${ADM_ROOT:-/opt/adm}"
ADM_PROFILE_DIR="${ADM_ROOT}/profiles"
CHROOT_ADM_BIND="${CHROOT_ADM_BIND:-1}"
CHROOT_COPY_NET="${CHROOT_COPY_NET:-1}"
CHROOT_TMPFS="${CHROOT_TMPFS:-1}"
CHROOT_RUN_BIND="${CHROOT_RUN_BIND:-1}"

# Mount table markers
MOUNTPOINTS=(proc sys dev dev/pts)
[ "$CHROOT_RUN_BIND" = "1" ] && MOUNTPOINTS+=(run)
[ "$CHROOT_TMPFS" = "1" ] && MOUNTPOINTS+=(tmp)

RED="\033[31m"; YELLOW="\033[33m"; GREEN="\033[32m"; BLUE="\033[34m"; RESET="\033[0m"
if [ ! -t 1 ]; then RED=""; YELLOW=""; GREEN=""; BLUE=""; RESET=""; fi

die() { echo -e "${RED}[FAIL]${RESET} $*" >&2; exit 1; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*" >&2; }
info(){ echo -e "${BLUE}[INFO]${RESET} $*" >&2; }
ok()  { echo -e "${GREEN}[ OK ]${RESET} $*" >&2; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Execute como root."
}

rootfs_of() {
  local profile="$1"
  echo "${ADM_PROFILE_DIR}/${profile}/rootfs"
}

ensure_dir() {
  local d="$1"
  [ -d "$d" ] || mkdir -p "$d"
}

is_mounted() {
  local mnt="$1"
  mountpoint -q "$mnt"
}

bind_mount() {
  local src="$1" dst="$2"
  ensure_dir "$dst"
  if is_mounted "$dst"; then
    ok "Já montado: $dst"
  else
    mount --bind "$src" "$dst"
    ok "Bind mount: $src -> $dst"
  fi
}

mount_proc_sys_dev() {
  local rootfs="$1"

  ensure_dir "$rootfs/proc" "$rootfs/sys" "$rootfs/dev" "$rootfs/dev/pts" "$rootfs/run" "$rootfs/tmp"

  if ! is_mounted "$rootfs/proc"; then
    mount -t proc proc "$rootfs/proc"
    ok "Montado proc"
  else ok "proc já montado"; fi

  if ! is_mounted "$rootfs/sys"; then
    mount -t sysfs sysfs "$rootfs/sys"
    ok "Montado sysfs"
  else ok "sys já montado"; fi

  if ! is_mounted "$rootfs/dev"; then
    mount --rbind /dev "$rootfs/dev"
    mount --make-rslave "$rootfs/dev" || true
    ok "Montado /dev (rbind)"
  else ok "dev já montado"; fi

  if ! is_mounted "$rootfs/dev/pts"; then
    mount -t devpts devpts "$rootfs/dev/pts" -o gid=5,mode=620
    ok "Montado devpts"
  else ok "dev/pts já montado"; fi

  if [ "$CHROOT_RUN_BIND" = "1" ]; then
    if ! is_mounted "$rootfs/run"; then
      mount --bind /run "$rootfs/run"
      ok "Montado /run (bind)"
    else ok "run já montado"; fi
  fi

  if [ "$CHROOT_TMPFS" = "1" ]; then
    if ! is_mounted "$rootfs/tmp"; then
      mount -t tmpfs tmpfs "$rootfs/tmp" -o nosuid,nodev,mode=1777
      ok "Montado tmpfs em /tmp"
    else ok "tmp já montado"; fi
  else
    chmod 1777 "$rootfs/tmp" 2>/dev/null || true
  fi
}

umount_safe() {
  local rootfs="$1"

  # ordem reversa e lazy umount se necessário
  local targets=()

  [ "$CHROOT_TMPFS" = "1" ] && targets+=("$rootfs/tmp")
  [ "$CHROOT_RUN_BIND" = "1" ] && targets+=("$rootfs/run")
  targets+=("$rootfs/dev/pts" "$rootfs/dev" "$rootfs/sys" "$rootfs/proc")

  local t
  for t in "${targets[@]}"; do
    if is_mounted "$t"; then
      umount "$t" 2>/dev/null || umount -l "$t" 2>/dev/null || warn "Não consegui desmontar: $t"
      ok "Desmontado: $t"
    else
      info "Não montado: $t"
    fi
  done
}

fix_minimal_etc() {
  local rootfs="$1"
  ensure_dir "$rootfs/etc" "$rootfs/root" "$rootfs/home" "$rootfs/var" "$rootfs/usr" "$rootfs/bin" "$rootfs/sbin"

  # passwd/group mínimos (chroot precisa para ferramentas e shells)
  if [ ! -f "$rootfs/etc/passwd" ]; then
    cat > "$rootfs/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
EOF
    ok "Criado /etc/passwd"
  fi

  if [ ! -f "$rootfs/etc/group" ]; then
    cat > "$rootfs/etc/group" <<'EOF'
root:x:0:
tty:x:5:
EOF
    ok "Criado /etc/group"
  fi

  # hosts/resolv.conf (rede dentro do chroot)
  if [ "$CHROOT_COPY_NET" = "1" ]; then
    if [ -f /etc/resolv.conf ]; then
      cp -L /etc/resolv.conf "$rootfs/etc/resolv.conf"
      ok "Copiado resolv.conf"
    else
      warn "Host sem /etc/resolv.conf; rede pode não funcionar dentro do chroot."
    fi
  fi

  if [ ! -f "$rootfs/etc/hosts" ]; then
    cat > "$rootfs/etc/hosts" <<'EOF'
127.0.0.1 localhost
::1       localhost
EOF
    ok "Criado /etc/hosts"
  fi

  # nsswitch.conf (para glibc costuma ajudar; para musl não atrapalha)
  if [ ! -f "$rootfs/etc/nsswitch.conf" ]; then
    cat > "$rootfs/etc/nsswitch.conf" <<'EOF'
passwd: files
group:  files
shadow: files
hosts:  files dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
EOF
    ok "Criado /etc/nsswitch.conf"
  fi

  # profile e profile.d para facilitar uso do adm dentro do chroot
  ensure_dir "$rootfs/etc/profile.d"
  if [ ! -f "$rootfs/etc/profile" ]; then
    cat > "$rootfs/etc/profile" <<'EOF'
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/tools/bin
export PS1="(adm-chroot) \u:\w\$ "
EOF
    ok "Criado /etc/profile"
  fi

  if [ ! -f "$rootfs/etc/profile.d/adm.sh" ]; then
    cat > "$rootfs/etc/profile.d/adm.sh" <<'EOF'
# Integração com ADM dentro do chroot
export ADM_ROOT="${ADM_ROOT:-/opt/adm}"

# Se o adm.sh existir, deixe PATH e profile prontos.
if [ -f "$ADM_ROOT/current_profile" ]; then
  export ADM_CURRENT_PROFILE="$(cat "$ADM_ROOT/current_profile" 2>/dev/null || true)"
fi

# Não força nada aqui; o adm.sh é quem aplica env do profile.
EOF
    ok "Criado /etc/profile.d/adm.sh"
  fi

  # /bin/sh (muitos builds assumem existir)
  if [ ! -e "$rootfs/bin/sh" ]; then
    if [ -e "$rootfs/bin/bash" ]; then
      ln -s bash "$rootfs/bin/sh"
      ok "Criado /bin/sh -> bash"
    elif [ -e "$rootfs/usr/bin/bash" ]; then
      ln -s ../usr/bin/bash "$rootfs/bin/bash" || true
      ln -s bash "$rootfs/bin/sh"
      ok "Criado /bin/sh -> bash (via /usr/bin/bash)"
    else
      warn "Não encontrei bash no rootfs. Instale bash no rootfs antes de entrar no chroot."
    fi
  fi
}

prepare_adm_inside_chroot() {
  local rootfs="$1"

  ensure_dir "$rootfs/opt"
  if [ "$CHROOT_ADM_BIND" = "1" ]; then
    bind_mount "$ADM_ROOT" "$rootfs/opt/adm"
  else
    # copia (não atualiza automaticamente). Só copia se não existir.
    if [ ! -d "$rootfs/opt/adm" ]; then
      mkdir -p "$rootfs/opt/adm"
      cp -a "$ADM_ROOT/." "$rootfs/opt/adm/"
      ok "Copiado $ADM_ROOT -> $rootfs/opt/adm (modo cópia)"
    else
      info "Já existe $rootfs/opt/adm (modo cópia)."
    fi
  fi

  # garante caches e dirs do adm no chroot (quando bind, já existe; quando cópia, criamos)
  ensure_dir "$rootfs/opt/adm" \
             "$rootfs/opt/adm/sources" \
             "$rootfs/opt/adm/binaries" \
             "$rootfs/opt/adm/build" \
             "$rootfs/opt/adm/log" \
             "$rootfs/opt/adm/db" \
             "$rootfs/opt/adm/profiles" \
             "$rootfs/opt/adm/packages"
}

status() {
  local profile="$1"
  local rootfs
  rootfs="$(rootfs_of "$profile")"

  echo "ADM_ROOT   : $ADM_ROOT"
  echo "PROFILE    : $profile"
  echo "ROOTFS     : $rootfs"
  echo

  [ -d "$rootfs" ] || { echo "ROOTFS inexistente"; return 1; }

  echo "Montagens:"
  local m
  for m in proc sys dev dev/pts run tmp; do
    if [ -d "$rootfs/$m" ] && is_mounted "$rootfs/$m"; then
      echo "  [M] $rootfs/$m"
    else
      echo "  [ ] $rootfs/$m"
    fi
  done

  echo
  echo "Checagens mínimas:"
  [ -x "$rootfs/bin/bash" ] || [ -x "$rootfs/usr/bin/bash" ] || warn "bash não encontrado no rootfs"
  [ -x "$rootfs/usr/bin/env" ] || warn "env não encontrado (coreutils incompleto?)"
  [ -f "$rootfs/etc/passwd" ] || warn "/etc/passwd ausente"
  [ -d "$rootfs/opt/adm" ] || warn "/opt/adm ausente dentro do rootfs (bind/copy não feito)"
}

enter_chroot() {
  local profile="$1"
  local rootfs
  rootfs="$(rootfs_of "$profile")"

  [ -d "$rootfs" ] || die "Rootfs não existe: $rootfs"
  fix_minimal_etc "$rootfs"
  prepare_adm_inside_chroot "$rootfs"
  mount_proc_sys_dev "$rootfs"

  # Preferência por bash no rootfs
  local shell="/bin/bash"
  [ -x "$rootfs/bin/bash" ] || shell="/usr/bin/bash"

  # Define ambiente básico do chroot:
  # - PATH inclui /tools/bin para bootstrap
  # - HOME=/root
  # - TERM preserva para usabilidade
  info "Entrando no chroot: $rootfs (profile=$profile)"
  chroot "$rootfs" /usr/bin/env -i \
    HOME=/root \
    TERM="${TERM:-linux}" \
    PS1="(adm-chroot:${profile}) \u:\w\$ " \
    PATH="/tools/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    ADM_ROOT="/opt/adm" \
    bash --login
}

mount_only() {
  local profile="$1"
  local rootfs
  rootfs="$(rootfs_of "$profile")"
  [ -d "$rootfs" ] || die "Rootfs não existe: $rootfs"

  fix_minimal_etc "$rootfs"
  prepare_adm_inside_chroot "$rootfs"
  mount_proc_sys_dev "$rootfs"
  ok "Chroot preparado e montado para profile '$profile'"
}

umount_only() {
  local profile="$1"
  local rootfs
  rootfs="$(rootfs_of "$profile")"
  [ -d "$rootfs" ] || die "Rootfs não existe: $rootfs"

  # desmonta também /opt/adm se bind-mounted
  if [ -d "$rootfs/opt/adm" ] && is_mounted "$rootfs/opt/adm"; then
    umount "$rootfs/opt/adm" 2>/dev/null || umount -l "$rootfs/opt/adm" 2>/dev/null || true
    ok "Desmontado bind /opt/adm"
  fi

  umount_safe "$rootfs"
  ok "Chroot desmontado para profile '$profile'"
}

fix_only() {
  local profile="$1"
  local rootfs
  rootfs="$(rootfs_of "$profile")"
  [ -d "$rootfs" ] || die "Rootfs não existe: $rootfs"
  fix_minimal_etc "$rootfs"
  prepare_adm_inside_chroot "$rootfs"
  ok "Fix aplicado para profile '$profile'"
}

usage() {
  cat <<EOF
Uso:
  adm_chroot.sh mount  <profile>
  adm_chroot.sh enter  <profile>
  adm_chroot.sh umount <profile>
  adm_chroot.sh status <profile>
  adm_chroot.sh fix    <profile>

Exemplos:
  adm_chroot.sh mount glibc
  adm_chroot.sh enter glibc
  adm_chroot.sh umount glibc

Variáveis:
  ADM_ROOT=/opt/adm
  CHROOT_ADM_BIND=1     # bind /opt/adm host->chroot (recomendado)
  CHROOT_COPY_NET=1     # copia /etc/resolv.conf para o chroot
  CHROOT_TMPFS=1        # monta tmpfs em /tmp
  CHROOT_RUN_BIND=1     # bind-mount /run
EOF
}

main() {
  local cmd="${1:-}"
  local profile="${2:-}"

  case "$cmd" in
    mount|enter|umount|status|fix) : ;;
    ""|-h|--help|help) usage; exit 0 ;;
    *) die "Comando inválido: $cmd" ;;
  esac

  [ -n "$profile" ] || die "Informe o profile: $cmd <profile>"
  need_root

  [ -d "${ADM_PROFILE_DIR}/${profile}" ] || warn "Profile '${profile}' não existe em ${ADM_PROFILE_DIR} (criando diretórios mínimos com fix)"
  ensure_dir "${ADM_PROFILE_DIR}/${profile}/rootfs"

  case "$cmd" in
    mount)  mount_only "$profile" ;;
    enter)  enter_chroot "$profile" ;;
    umount) umount_only "$profile" ;;
    status) status "$profile" ;;
    fix)    fix_only "$profile" ;;
  esac
}

main "$@"
