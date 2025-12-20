========================================================
CONSTRUÇÃO DE UM SISTEMA LINUX COMPLETO (MUSL + RUNIT)
========================================================

Objetivo:
  Criar um sistema Linux moderno, minimalista, seguro e
  totalmente controlado pelo adm, sem systemd, sem glibc,
  sem bloat.

Stack final:
  - libc: musl
  - init: runit
  - shell/base: busybox
  - display: Wayland
  - browser: Firefox
  - editor: Vim
  - áudio: PipeWire
  - rede: iproute2 + dhcpcd
  - gráficos: mesa
  - compiladores: gcc + binutils
  - logs: runit + logfiles simples
  - gerenciador: adm

========================================================
1. BOOTSTRAP (HOST → CROSS TOOLCHAIN)
========================================================

Usar bootstrap-cross.sh (já criado):

  ./bootstrap-cross.sh all

Resultado:
  TOOLCHAIN: /var/tmp/bootstrap-cross/tools
  SYSROOT:   /var/tmp/bootstrap-cross/sysroot

Esse toolchain é TEMPORÁRIO.

========================================================
2. ROOTFS BASE
========================================================

Criar rootfs a partir do sysroot:

  ROOTFS=/var/tmp/rootfs
  mkdir -p "$ROOTFS"

  (cd /var/tmp/bootstrap-cross/sysroot && tar -cf - .) | \
    (cd "$ROOTFS" && tar -xf -)

Diretórios obrigatórios:

  mkdir -p "$ROOTFS"/{proc,sys,dev,run,tmp}
  mkdir -p "$ROOTFS"/{etc,root,home}
  mkdir -p "$ROOTFS"/usr/{bin,sbin,lib,share}
  mkdir -p "$ROOTFS"/var/{log,lib,cache}

Shell:

  ln -sf busybox "$ROOTFS/bin/sh"

========================================================
3. INIT: RUNIT (OBRIGATÓRIO)
========================================================

Dentro do chroot:

  adm build runit
  adm install runit

Links essenciais:

  ln -sf /usr/bin/runit-init /sbin/init
  mkdir -p /etc/runit/{runsvdir,sv}

Serviços básicos obrigatórios:
  - agetty
  - dhcpcd
  - pipewire (futuro)
  - seatd
  - dbus

Logs:
  Cada serviço runit deve ter ./log/run com svlogd
  Logs em: /var/log/*

========================================================
4. SISTEMA BASE (ESSENCIAL)
========================================================

Ordem correta:

  adm install linux-headers
  adm install musl
  adm install binutils
  adm install gcc
  adm install busybox
  adm install xz
  adm install make
  adm install pkgconf
  adm install sed
  adm install grep
  adm install awk
  adm install findutils
  adm install coreutils (opcional)

Editor:

  adm install vim

========================================================
5. REDE (SEM BLOAT)
========================================================

Pacotes:

  adm install iproute2
  adm install dhcpcd
  adm install ethtool
  adm install iw (wifi)

Serviço runit:

  /etc/runit/sv/dhcpcd/run

    #!/bin/sh
    exec dhcpcd -B

========================================================
6. ÁUDIO (PIPEWIRE LEVE)
========================================================

Pacotes mínimos:

  adm install pipewire
  adm install wireplumber
  adm install alsa-lib
  adm install alsa-utils

Serviços runit:
  - pipewire
  - wireplumber

ALSA continua funcionando sem PulseAudio.

========================================================
7. GRÁFICOS / VÍDEO (WAYLAND)
========================================================

Kernel (obrigatório):

  CONFIG_DRM
  CONFIG_DRM_SIMPLEDRM
  CONFIG_FB
  CONFIG_INPUT_EVDEV

Pacotes gráficos:

  adm install mesa
  adm install libdrm
  adm install wayland
  adm install wayland-protocols
  adm install seatd
  adm install libinput

Compositor (escolha UM):

  adm install sway        (wlroots)
  OU
  adm install wayfire

Serviço runit:

  seatd (antes do compositor)

========================================================
8. FIREFOX (SEM SYSTEMD)
========================================================

Dependências:

  adm install dbus
  adm install fontconfig
  adm install freetype
  adm install harfbuzz
  adm install cairo
  adm install pango
  adm install gtk3
  adm install nss
  adm install nspr

Browser:

  adm install firefox

OBS:
  Firefox funciona em Wayland nativo:
    MOZ_ENABLE_WAYLAND=1

========================================================
9. FONTES
========================================================

Pacotes mínimos:

  adm install fontconfig
  adm install dejavu-fonts
  adm install noto-fonts-basic

========================================================
10. COMPILADORES NO SISTEMA FINAL
========================================================

Agora o sistema é autosuficiente:

  adm install gcc
  adm install binutils
  adm install musl
  adm install make

O cross-toolchain NÃO é mais usado.

========================================================
11. USUÁRIOS E LOGIN
========================================================

Criar usuário:

  adduser user

Permissões de vídeo/som:

  addgroup user video
  addgroup user audio
  addgroup user input

========================================================
12. BOOT
========================================================

Kernel:
  Compilar kernel com:
    - musl toolchain
    - init=/sbin/init

Bootloader:
  - syslinux OU grub (sem systemd)

fstab mínimo:

  proc /proc proc defaults 0 0
  sys  /sys  sysfs defaults 0 0
  tmpfs /tmp tmpfs defaults 0 0

========================================================
13. O QUE NÃO INSTALAR (BLOAT)
========================================================

NÃO instalar:
  - systemd
  - elogind
  - pulseaudio
  - NetworkManager
  - polkit
  - avahi
  - snap/flatpak

========================================================
14. MODELO MENTAL FINAL
========================================================

bootstrap-cross.sh
   ↓
rootfs mínimo
   ↓
adm assume controle
   ↓
runit gerencia serviços
   ↓
wayland + firefox
   ↓
sistema completo, simples e sob controle

========================================================
FIM
========================================================
