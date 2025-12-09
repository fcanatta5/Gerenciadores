#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuração básica (coerente com adm.sh)
# ---------------------------------------------------------------------------

ADM_ROOT_DEFAULT="/opt/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"

ROOTFS_GLIBC="${ADM_ROOT}/glibc-rootfs"
ROOTFS_MUSL="${ADM_ROOT}/musl-rootfs"

MOUNTS=()
BIND_RO=()
BIND_RW=()
DEBUG=0

log() {
    printf '[adm-chroot] %s\n' "$*" >&2
}

log_debug() {
    if [ "$DEBUG" -eq 1 ]; then
        log "DEBUG: $*"
    fi
}

require_root() {
    local uid
    uid="$(id -u)"
    if [ "$uid" -ne 0 ]; then
        log "Este wrapper precisa ser executado como root."
        exit 1
    fi
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "Comando obrigatório não encontrado no host: $cmd"
        exit 1
    fi
}

add_mount() {
    MOUNTS+=("$1")
    log_debug "Registrado mount: $1"
}

cleanup() {
    log_debug "Iniciando limpeza (umount reverso)..."
    for (( i=${#MOUNTS[@]}-1; i>=0; i-- )); do
        local m="${MOUNTS[i]}"
        if mountpoint -q "$m"; then
            log_debug "Umount $m"
            umount -lf "$m" 2>/dev/null || log "Aviso: falha ao desmontar $m"
        fi
    done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preparar rootfs (diretórios básicos, resolv.conf, etc.)
# ---------------------------------------------------------------------------

prepare_rootfs_layout() {
    local rootfs="$1"

    log_debug "Preparando layout básico em $rootfs"

    mkdir -pv \
        "${rootfs}/"{bin,boot,dev,etc,home,lib,lib64,media,mnt,opt,proc,root,run,sbin,sys,tmp,usr,var} \
        "${rootfs}/usr/"{bin,lib,lib64,sbin} \
        "${rootfs}/var/"{log,cache,lib,tmp}

    chmod 1777 "${rootfs}/tmp" "${rootfs}/var/tmp"

    mkdir -pv "${rootfs}/etc"

    # resolv.conf (DNS) do host para dentro do chroot
    if [ -f /etc/resolv.conf ]; then
        cp -L /etc/resolv.conf "${rootfs}/etc/resolv.conf"
    fi

    # hosts opcional
    if [ -f /etc/hosts ] && [ ! -f "${rootfs}/etc/hosts" ]; then
        cp /etc/hosts "${rootfs}/etc/hosts"
    fi
}

# ---------------------------------------------------------------------------
# Montagens de pseudo-filesystems e binds
# ---------------------------------------------------------------------------

mount_pseudo_filesystems() {
    local rootfs="$1"

    log_debug "Montando pseudo-filesystems em $rootfs"

    # /dev
    mkdir -pv "${rootfs}/dev"
    mount --bind /dev "${rootfs}/dev"
    add_mount "${rootfs}/dev"

    # /dev/pts
    mkdir -pv "${rootfs}/dev/pts"
    mount -t devpts devpts "${rootfs}/dev/pts" -o gid=5,mode=620
    add_mount "${rootfs}/dev/pts"

    # /dev/shm
    mkdir -pv "${rootfs}/dev/shm"
    mount -t tmpfs tmpfs "${rootfs}/dev/shm" -o mode=1777,nosuid,nodev
    add_mount "${rootfs}/dev/shm"

    # /proc
    mkdir -pv "${rootfs}/proc"
    mount -t proc proc "${rootfs}/proc" -o nosuid,noexec,nodev
    add_mount "${rootfs}/proc"

    # /sys
    mkdir -pv "${rootfs}/sys"
    mount -t sysfs sysfs "${rootfs}/sys" -o nosuid,noexec,nodev,ro
    add_mount "${rootfs}/sys"

    # /run
    mkdir -pv "${rootfs}/run"
    mount -t tmpfs tmpfs "${rootfs}/run" -o mode=755,nosuid,nodev
    add_mount "${rootfs}/run"
}

mount_adm_tree() {
    local rootfs="$1"

    log_debug "Montando /opt/adm dentro de $rootfs"

    mkdir -pv "${rootfs}/opt"
    if ! mountpoint -q "${rootfs}/opt/adm"; then
        mkdir -pv "${rootfs}/opt/adm"
        mount --bind "${ADM_ROOT}" "${rootfs}/opt/adm"
        add_mount "${rootfs}/opt/adm"
    fi
}

mount_extra_binds() {
    local rootfs="$1"

    local src dst

    # Bind read-only
    for src in "${BIND_RO[@]}"; do
        [ -z "$src" ] && continue
        if [ ! -d "$src" ]; then
            log "Aviso: diretório para bind-ro não existe: $src (ignorando)"
            continue
        fi
        dst="${rootfs}${src}"
        mkdir -pv "$dst"
        log_debug "Bind RO: $src -> $dst"
        mount --bind "$src" "$dst"
        add_mount "$dst"
        mount -o remount,bind,ro "$dst"
    done

    # Bind read-write
    for src in "${BIND_RW[@]}"; do
        [ -z "$src" ] && continue
        if [ ! -d "$src" ]; then
            log "Aviso: diretório para bind-rw não existe: $src (ignorando)"
            continue
        fi
        dst="${rootfs}${src}"
        mkdir -pv "$dst"
        log_debug "Bind RW: $src -> $dst"
        mount --bind "$src" "$dst"
        add_mount "$dst"
    done
}

# ---------------------------------------------------------------------------
# Verificações de sanidade do rootfs
# ---------------------------------------------------------------------------

check_rootfs_ready() {
    local rootfs="$1"

    if [ ! -d "$rootfs" ]; then
        log "Rootfs ${rootfs} não existe. Certifique-se que o adm já instalou algo nele."
        exit 1
    fi

    # Bash dentro do rootfs (para shell e adm)
    if [ ! -x "${rootfs}/bin/bash" ] && [ ! -x "${rootfs}/usr/bin/bash" ]; then
        log "Aviso: não encontrei /bin/bash nem /usr/bin/bash dentro de ${rootfs}."
        log "O chroot ainda está muito vazio. O shell pode não funcionar como esperado."
    fi

    # adm.sh dentro do rootfs? (via bind /opt/adm) – checado apenas depois do mount
}

check_adm_inside_chroot() {
    local rootfs="$1"

    if [ ! -x "${rootfs}/opt/adm/adm.sh" ]; then
        log "Erro: /opt/adm/adm.sh não encontrado dentro do chroot (${rootfs}/opt/adm/adm.sh)."
        log "Verifique se ADM_ROOT está correto e se o diretório /opt/adm foi montado."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Execução no chroot
# ---------------------------------------------------------------------------

run_shell_in_chroot() {
    local rootfs="$1"

    log "Entrando em shell dentro do chroot: ${rootfs}"

    chroot "${rootfs}" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/adm" \
        ADM_ROOT="/opt/adm" \
        ADM_IN_CHROOT=1 \
        /bin/bash -l
}

run_adm_in_chroot() {
    local rootfs="$1"
    local profile="$2"
    shift 2
    local adm_args=( "$@" )

    if [ "${#adm_args[@]}" -eq 0 ]; then
        log "Nenhum comando do adm foi passado. Exemplo:"
        log "  adm-chroot.sh -P glibc build coreutils-9.9"
        exit 1
    fi

    log "Executando adm dentro do chroot ${rootfs} com profile ${profile}: adm ${adm_args[*]}"

    chroot "${rootfs}" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/adm" \
        ADM_ROOT="/opt/adm" \
        ADM_IN_CHROOT=1 \
        /opt/adm/adm.sh -P "${profile}" "${adm_args[@]}"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Uso:
  adm-chroot.sh [-P glibc|musl|glibc-opt|musl-opt] [--shell] [opções] [--] [comando_adm args...]

Modos:
  1) Shell interativo dentro do chroot:
       adm-chroot.sh -P glibc --shell

  2) Executar o adm dentro do chroot:
       adm-chroot.sh -P glibc build coreutils-9.9
       adm-chroot.sh -P musl  build bash-5.3

Opções:
  -P, --profile   Profile do adm (glibc, musl, glibc-opt, musl-opt). Padrão: glibc
  --shell         Entrar em shell interativo dentro do chroot do profile
  --bind-ro DIR   Faz bind read-only de DIR do host para o mesmo caminho dentro do chroot (pode repetir)
  --bind-rw DIR   Faz bind read-write de DIR do host para o mesmo caminho dentro do chroot (pode repetir)
  --debug         Verbose de debug do wrapper
  -h, --help      Mostra esta mensagem

Exemplos:
  # Entrar em shell no chroot glibc, com /home do host em read-only:
  adm-chroot.sh -P glibc --bind-ro /home --shell

  # Construir coreutils dentro do chroot glibc:
  adm-chroot.sh -P glibc build coreutils-9.9

  # Construir bash dentro do chroot musl:
  adm-chroot.sh -P musl build bash-5.3
EOF
}

main() {
    require_root
    require_cmd chroot
    require_cmd mount

    local profile="glibc"
    local mode="adm"   # "adm" ou "shell"

    # parse opções
    while [ $# -gt 0 ]; do
        case "$1" in
            -P|--profile)
                profile="$2"
                shift 2
                ;;
            --shell)
                mode="shell"
                shift
                ;;
            --bind-ro)
                BIND_RO+=("$2")
                shift 2
                ;;
            --bind-rw)
                BIND_RW+=("$2")
                shift 2
                ;;
            --debug)
                DEBUG=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
                # o restante são argumentos para o adm (no modo "adm")
                break
                ;;
        esac
    done

    local rootfs=""
    case "$profile" in
        glibc|glibc-opt)
            rootfs="$ROOTFS_GLIBC"
            ;;
        musl|musl-opt)
            rootfs="$ROOTFS_MUSL"
            ;;
        *)
            log "Profile desconhecido: $profile (use glibc, musl, glibc-opt, musl-opt)"
            exit 1
            ;;
    esac

    check_rootfs_ready "$rootfs"
    prepare_rootfs_layout "$rootfs"
    mount_pseudo_filesystems "$rootfs"
    mount_adm_tree "$rootfs"
    mount_extra_binds "$rootfs"
    check_adm_inside_chroot "$rootfs"

    if [ "$mode" = "shell" ]; then
        run_shell_in_chroot "$rootfs"
    else
        run_adm_in_chroot "$rootfs" "$profile" "$@"
    fi
}

main "$@"
