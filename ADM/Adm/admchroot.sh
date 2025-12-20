#!/bin/sh
# admchroot — gerenciador POSIX de chroot (seguro, limpo, idempotente)
# Uso:
#   admchroot --root /caminho/do/root setup
#   admchroot --root /caminho/do/root exec -- <comando> [args...]
#   admchroot --root /caminho/do/root shell
#   admchroot --root /caminho/do/root adm -- <args do adm...>
#   admchroot --root /caminho/do/root teardown
#
# Integração típica no adm:
#   admchroot --root "$CHROOT" adm -- build binutils
#
set -eu

ROOT=""
NO_NET=0
BIND_RUN=1
LOCKDIR_BASE="/var/lock/admchroot"

say() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }
die() { err "ERRO: $*"; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "precisa ser root"
}

is_abs_path() {
  case "$1" in /*) return 0 ;; *) return 1 ;; esac
}

# recusa symlink no root: evita chroot apontar para local inesperado
is_symlink() { [ -L "$1" ]; }

ensure_dir() {
  [ -d "$1" ] || mkdir -p "$1"
}

# /proc/mounts é a forma mais portável em busybox/musl
is_mounted() {
  # $1 = alvo (ex: /chroot/proc)
  tgt="$1"
  [ -r /proc/mounts ] || return 1
  # segundo campo é o mountpoint
  awk -v t="$tgt" '$2==t{found=1} END{exit found?0:1}' /proc/mounts
}

# "mount --bind" costuma existir em util-linux e busybox mount
bind_mount() {
  src="$1"; dst="$2"
  ensure_dir "$dst"
  if is_mounted "$dst"; then
    return 0
  fi
  mount --bind "$src" "$dst"
}

# alguns sistemas exigem remount para readonly
bind_mount_ro() {
  src="$1"; dst="$2"
  bind_mount "$src" "$dst"
  # tenta read-only (se suportado)
  mount -o remount,ro,bind "$dst" 2>/dev/null || true
}

umount_if_mounted() {
  m="$1"
  if is_mounted "$m"; then
    umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
  fi
}

validate_root() {
  [ -n "$ROOT" ] || die "use --root /caminho"
  is_abs_path "$ROOT" || die "--root deve ser caminho absoluto"
  [ "$ROOT" != "/" ] || die "root '/' é proibido"
  [ -d "$ROOT" ] || die "root inexistente: $ROOT"
  is_symlink "$ROOT" && die "root não pode ser symlink: $ROOT"

  # garantias mínimas de chroot
  [ -x "$ROOT/bin/sh" ] || [ -x "$ROOT/usr/bin/sh" ] || die "chroot sem /bin/sh"
  ensure_dir "$ROOT/proc"
  ensure_dir "$ROOT/sys"
  ensure_dir "$ROOT/dev"
  ensure_dir "$ROOT/dev/pts"
  ensure_dir "$ROOT/tmp"
  ensure_dir "$ROOT/run"
}

lock_acquire() {
  ensure_dir "$LOCKDIR_BASE"
  lk="$LOCKDIR_BASE/$(printf '%s' "$ROOT" | sed 's#[^A-Za-z0-9._-]#_#g').lock"
  # lockdir POSIX
  i=0
  while :; do
    if mkdir "$lk" 2>/dev/null; then
      printf '%s\n' "$$" >"$lk/pid" 2>/dev/null || true
      break
    fi
    i=$((i+1))
    [ "$i" -le 120 ] || die "timeout aguardando lock: $lk"
    sleep 1
  done
  echo "$lk"
}

lock_release() {
  lk="$1"
  rm -f "$lk/pid" 2>/dev/null || true
  rmdir "$lk" 2>/dev/null || true
}

setup_mounts() {
  need_root
  validate_root

  # mounts “essenciais” para um sistema moderno funcionar no chroot
  # proc
  if ! is_mounted "$ROOT/proc"; then
    mount -t proc proc "$ROOT/proc"
  fi
  # sysfs
  if ! is_mounted "$ROOT/sys"; then
    mount -t sysfs sys "$ROOT/sys" 2>/dev/null || mount -t sysfs sysfs "$ROOT/sys" 2>/dev/null || true
  fi
  # dev e pts
  bind_mount /dev "$ROOT/dev"
  if ! is_mounted "$ROOT/dev/pts"; then
    mount -t devpts devpts "$ROOT/dev/pts" 2>/dev/null || true
  fi

  # /run pode ajudar (dbus, etc.) — opcional
  if [ "$BIND_RUN" -eq 1 ]; then
    bind_mount /run "$ROOT/run" 2>/dev/null || true
  fi

  # rede (DNS) opcional e seguro (RO)
  if [ "$NO_NET" -eq 0 ]; then
    if [ -f /etc/resolv.conf ]; then
      ensure_dir "$ROOT/etc"
      bind_mount_ro /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || {
        # fallback: copia (menos “dinâmico”, mas funciona)
        cp -f /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true
      }
    fi
    if [ -f /etc/hosts ]; then
      ensure_dir "$ROOT/etc"
      bind_mount_ro /etc/hosts "$ROOT/etc/hosts" 2>/dev/null || {
        cp -f /etc/hosts "$ROOT/etc/hosts" 2>/dev/null || true
      }
    fi
  fi
}

teardown_mounts() {
  need_root
  validate_root

  # desmontar de dentro para fora
  umount_if_mounted "$ROOT/dev/pts"
  umount_if_mounted "$ROOT/dev"
  umount_if_mounted "$ROOT/run"
  umount_if_mounted "$ROOT/sys"
  umount_if_mounted "$ROOT/proc"

  # se resolv/hosts estiverem bind-mounted
  umount_if_mounted "$ROOT/etc/resolv.conf"
  umount_if_mounted "$ROOT/etc/hosts"
}

chroot_exec() {
  need_root
  validate_root

  # ambiente mínimo e previsível
  # PATH prioriza /usr/local dentro do chroot se existir
  CHROOT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  CHROOT_HOME="/root"
  CHROOT_TERM="${TERM:-linux}"

  # usamos env -i (se existir) para evitar vazamento; fallback sem env -i
  if command -v env >/dev/null 2>&1; then
    chroot "$ROOT" /usr/bin/env -i \
      PATH="$CHROOT_PATH" \
      HOME="$CHROOT_HOME" \
      TERM="$CHROOT_TERM" \
      SHELL="/bin/sh" \
      "$@"
  else
    chroot "$ROOT" /bin/sh -c '
      PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      HOME="/root"
      TERM="${TERM:-linux}"
      export PATH HOME TERM
      exec "$@"
    ' sh "$@"
  fi
}

usage() {
  cat <<EOF
admchroot — POSIX chroot manager

Uso:
  admchroot --root /caminho setup
  admchroot --root /caminho teardown
  admchroot --root /caminho exec -- <cmd> [args...]
  admchroot --root /caminho shell
  admchroot --root /caminho adm -- <args do adm...>

Opções:
  --root PATH        (obrigatório)
  --no-net           não bind-monta resolv.conf/hosts
  --no-run           não bind-monta /run
EOF
}

main() {
  # parse simples POSIX
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) shift; ROOT="${1:-}"; shift ;;
      --no-net) NO_NET=1; shift ;;
      --no-run) BIND_RUN=0; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  cmd="${1:-}"
  [ -n "$cmd" ] || { usage; exit 1; }
  shift

  # lock por root (evita corrida entre setup/teardown/exec simultâneos)
  validate_root
  lk=$(lock_acquire)
  trap 'lock_release "$lk"' INT TERM EXIT

  case "$cmd" in
    setup)
      setup_mounts
      ok_msg="chroot pronto: $ROOT"
      say "$ok_msg"
      ;;
    teardown)
      teardown_mounts
      say "chroot desmontado: $ROOT"
      ;;
    exec)
      [ "${1:-}" = "--" ] || die "use: exec -- <cmd> ..."
      shift
      [ $# -gt 0 ] || die "exec precisa de comando"
      setup_mounts
      # teardown garantido ao sair
      trap 'teardown_mounts >/dev/null 2>&1 || true; lock_release "$lk"' INT TERM EXIT
      chroot_exec "$@"
      ;;
    shell)
      setup_mounts
      trap 'teardown_mounts >/dev/null 2>&1 || true; lock_release "$lk"' INT TERM EXIT
      chroot_exec /bin/sh -l
      ;;
    adm)
      [ "${1:-}" = "--" ] || die "use: adm -- <args>"
      shift
      [ $# -gt 0 ] || die "adm precisa de args (ex: build pkg)"
      setup_mounts
      trap 'teardown_mounts >/dev/null 2>&1 || true; lock_release "$lk"' INT TERM EXIT
      # tenta /usr/bin/adm, depois /bin/adm
      if [ -x "$ROOT/usr/bin/adm" ]; then
        chroot_exec /usr/bin/adm "$@"
      elif [ -x "$ROOT/bin/adm" ]; then
        chroot_exec /bin/adm "$@"
      else
        die "adm não encontrado dentro do chroot (/usr/bin/adm ou /bin/adm)"
      fi
      ;;
    *)
      die "comando desconhecido: $cmd"
      ;;
  esac

  lock_release "$lk"
  trap - INT TERM EXIT
}

main "$@"
