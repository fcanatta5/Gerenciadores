#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuração básica (coerente com adm.sh)
# ---------------------------------------------------------------------------

ADM_ROOT_DEFAULT="/opt/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"

ROOTFS_GLIBC="${ADM_ROOT}/glibc-rootfs"
ROOTFS_MUSL="${ADM_ROOT}/musl-rootfs"

# Lista de mounts para desmontar na saída
MOUNTS=()

log() {
    printf '[adm-chroot] %s\n' "$*" >&2
}

require_root() {
    local uid
    uid="$(id -u)"
    if [ "$uid" -ne 0 ]; then
        log "Este wrapper precisa ser executado como root."
        exit 1
    fi
}

add_mount() {
    MOUNTS+=("$1")
}

cleanup() {
    # desmonta em ordem reversa
    for (( i=${#MOUNTS[@]}-1; i>=0; i-- )); do
        local m="${MOUNTS[i]}"
        if mountpoint -q "$m"; then
            umount -lf "$m" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preparar rootfs (diretórios básicos, resolv.conf)
# ---------------------------------------------------------------------------

prepare_rootfs_layout() {
    local rootfs="$1"

    mkdir -pv \
        "${rootfs}/"{bin,boot,dev,etc,home,lib,lib64,media,mnt,opt,proc,root,run,sbin,sys,tmp,usr,var} \
        "${rootfs}/usr/"{bin,lib,lib64,sbin} \
        "${rootfs}/var/"{log,cache,lib,tmp}

    chmod 1777 "${rootfs}/tmp" "${rootfs}/var/tmp"

    # /etc básico
    mkdir -pv "${rootfs}/etc"

    # resolv.conf (DNS) do host para dentro do chroot
    if [ -f /etc/resolv.conf ]; then
        cp -L /etc/resolv.conf "${rootfs}/etc/resolv.conf"
    fi

    # opcional: hosts e localtime (se quiser)
    if [ -f /etc/hosts ] && [ ! -f "${rootfs}/etc/hosts" ]; then
        cp /etc/hosts "${rootfs}/etc/hosts"
    fi
}

# ---------------------------------------------------------------------------
# Montagens necessárias para um chroot "vivo"
# ---------------------------------------------------------------------------

mount_pseudo_filesystems() {
    local rootfs="$1"

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
    mount -t tmpfs tmpfs "${rootfs}/dev/shm" -o mode=1777
    add_mount "${rootfs}/dev/shm"

    # /proc
    mkdir -pv "${rootfs}/proc"
    mount -t proc proc "${rootfs}/proc" -o nosuid,noexec,nodev
    add_mount "${rootfs}/proc"

    # /sys
    mkdir -pv "${rootfs}/sys"
    mount -t sysfs sysfs "${rootfs}/sys" -o nosuid,noexec,nodev
    add_mount "${rootfs}/sys"

    # /run
    mkdir -pv "${rootfs}/run"
    mount -t tmpfs tmpfs "${rootfs}/run" -o mode=755
    add_mount "${rootfs}/run"
}

mount_adm_tree() {
    local rootfs="$1"

    # garantir /opt/adm dentro do chroot apontando para o mesmo /opt/adm do host
    mkdir -pv "${rootfs}/opt"
    if ! mountpoint -q "${rootfs}/opt/adm"; then
        mkdir -pv "${rootfs}/opt/adm"
        mount --bind "${ADM_ROOT}" "${rootfs}/opt/adm"
        add_mount "${rootfs}/opt/adm"
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
        log "Nenhum comando do adm foi passado. Ex: adm-chroot.sh -P glibc build coreutils-9.9"
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
  adm-chroot.sh [-P glibc|musl] [--shell]
  adm-chroot.sh [-P glibc|musl] comando_adm [args...]

Exemplos:
  # entrar em shell dentro do chroot glibc-rootfs
  adm-chroot.sh -P glibc --shell

  # construir pacote dentro do chroot glibc
  adm-chroot.sh -P glibc build coreutils-9.9

  # construir pacote dentro do chroot musl
  adm-chroot.sh -P musl build busybox-1.36.1
EOF
}

main() {
    require_root

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
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
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

    if [ ! -d "$rootfs" ]; then
        log "Rootfs do profile ${profile} não existe: ${rootfs}"
        log "Certifique-se que o adm já instalou alguma coisa em ${rootfs}."
        exit 1
    fi

    prepare_rootfs_layout "$rootfs"
    mount_pseudo_filesystems "$rootfs"
    mount_adm_tree "$rootfs"

    if [ "$mode" = "shell" ]; then
        run_shell_in_chroot "$rootfs"
    else
        run_adm_in_chroot "$rootfs" "$profile" "$@"
    fi
}

main "$@"
