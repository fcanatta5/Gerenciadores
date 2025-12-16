#!/bin/sh
set -euo pipefail

# ===== Configuração =====
ARCH="x86_64"
TARGET="${ARCH}-linux-musl"

# Diretórios (ajuste se quiser)
TOP="${TOP:-$PWD}"
ROOTFS="${ROOTFS:-$TOP/rootfs}"
WORK="${WORK:-$TOP/work}"
DIST="${DIST:-$TOP/distfiles}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

# Versões (fixe e mantenha estável)
ZIG_VER="${ZIG_VER:-0.12.0}"
BUSYBOX_VER="${BUSYBOX_VER:-1.36.1}"
MUSL_VER="${MUSL_VER:-1.2.5}"
RUNIT_VER="${RUNIT_VER:-2.1.2}"

# Fontes (substitua por seus mirrors preferidos)
ZIG_URL="${ZIG_URL:-https://ziglang.org/download/${ZIG_VER}/zig-linux-x86_64-${ZIG_VER}.tar.xz}"
BUSYBOX_URL="${BUSYBOX_URL:-https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2}"
MUSL_URL="${MUSL_URL:-https://musl.libc.org/releases/musl-${MUSL_VER}.tar.gz}"
RUNIT_URL="${RUNIT_URL:-https://smarden.org/runit/runit-${RUNIT_VER}.tar.gz}"

# ===== Utilitários =====
msg() { printf '%s\n' "==> $*"; }
die() { printf '%s\n' "ERRO: $*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "Falta dependência no host: $1"
}

fetch() {
  url="$1"; out="$2"
  [ -f "$out" ] && return 0
  msg "Baixando: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 3 -o "$out" "$url"
  else
    wget -O "$out" "$url"
  fi
}

extract() {
  arc="$1"; dir="$2"
  rm -rf "$dir"
  mkdir -p "$dir"
  case "$arc" in
    *.tar.gz|*.tgz)  tar -xzf "$arc" -C "$dir" --strip-components=1 ;;
    *.tar.xz)        tar -xJf "$arc" -C "$dir" --strip-components=1 ;;
    *.tar.bz2)       tar -xjf "$arc" -C "$dir" --strip-components=1 ;;
    *.tar)           tar -xf "$arc" -C "$dir" --strip-components=1 ;;
    *) die "Formato desconhecido: $arc" ;;
  esac
}

# ===== Pré-checagens =====
need tar
need make
need patch || true
need sed
need awk

mkdir -p "$ROOTFS" "$WORK" "$DIST"

# ===== 1) Zig (helper) =====
msg "Preparando Zig (helper de compilação)"
ZIG_ARC="$DIST/zig-${ZIG_VER}.tar.xz"
fetch "$ZIG_URL" "$ZIG_ARC"
ZIG_DIR="$WORK/zig"
extract "$ZIG_ARC" "$ZIG_DIR"
ZIG="$ZIG_DIR/zig"
[ -x "$ZIG" ] || die "Zig não encontrado em: $ZIG"

# Wrapper de CC/CXX usando musl target
export CC="$ZIG cc -target $TARGET"
export CXX="$ZIG c++ -target $TARGET"
export AR="$ZIG ar"
export RANLIB="$ZIG ranlib"
export STRIP="$ZIG strip"

# ===== 2) Layout do rootfs =====
msg "Criando estrutura mínima do rootfs"
mkdir -p \
  "$ROOTFS"/{bin,sbin,etc,proc,sys,dev,run,tmp,root,home} \
  "$ROOTFS"/usr/{bin,sbin,lib} \
  "$ROOTFS"/var/{log,cache,lib} \
  "$ROOTFS"/var/cache/adm/{distfiles,build} \
  "$ROOTFS"/var/lib/adm/{db,recipes}

chmod 1777 "$ROOTFS/tmp"

# ===== 3) musl =====
msg "Compilando musl ${MUSL_VER} (instala no rootfs)"
MUSL_ARC="$DIST/musl-${MUSL_VER}.tar.gz"
fetch "$MUSL_URL" "$MUSL_ARC"
MUSL_SRC="$WORK/musl"
extract "$MUSL_ARC" "$MUSL_SRC"
(
  cd "$MUSL_SRC"
  # Instala em /usr (padrão limpo)
  ./configure --prefix=/usr --target="$TARGET"
  make -j"$JOBS"
  DESTDIR="$ROOTFS" make install
)

# ===== 4) busybox =====
msg "Compilando busybox ${BUSYBOX_VER}"
BUSYBOX_ARC="$DIST/busybox-${BUSYBOX_VER}.tar.bz2"
fetch "$BUSYBOX_URL" "$BUSYBOX_ARC"
BUSYBOX_SRC="$WORK/busybox"
extract "$BUSYBOX_ARC" "$BUSYBOX_SRC"
(
  cd "$BUSYBOX_SRC"
  make defconfig
  # Ajustes: sem “coisas demais”, com utilitários essenciais
  # (você pode editar mais tarde via adm recipes)
  sed -i \
    -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
    -e 's/^CONFIG_FEATURE_SH_STANDALONE=.*/CONFIG_FEATURE_SH_STANDALONE=y/' \
    .config || true

  make -j"$JOBS" CC="$CC" AR="$AR" RANLIB="$RANLIB"
  make CONFIG_PREFIX="$ROOTFS" install

  # Link /bin/sh
  ln -sf busybox "$ROOTFS/bin/sh"
)

# ===== 5) runit =====
msg "Compilando runit ${RUNIT_VER}"
RUNIT_ARC="$DIST/runit-${RUNIT_VER}.tar.gz"
fetch "$RUNIT_URL" "$RUNIT_ARC"
RUNIT_SRC="$WORK/runit"
extract "$RUNIT_ARC" "$RUNIT_SRC"
(
  cd "$RUNIT_SRC"
  # runit compila simples; vamos forçar o CC do zig
  # Alguns tarballs usam ./package/compile; mantemos padrão do upstream
  export CC="$CC"
  export CFLAGS="-O2 -pipe"
  package/compile
  # Instala “à mão” em locais padrões
  install -Dm755 command/* "$ROOTFS/usr/bin/" 2>/dev/null || true
  # Alguns tarballs entregam binários em src/
  find . -maxdepth 3 -type f -perm -111 -name runsvdir -o -name runsv -o -name sv -o -name chpst -o -name runit -o -name runsvchdir 2>/dev/null \
    | while read -r f; do
        install -Dm755 "$f" "$ROOTFS/usr/bin/$(basename "$f")" || true
      done
)

# ===== 6) Configuração mínima do runit =====
msg "Configurando runit (scripts 1/2/3 e serviços básicos)"
mkdir -p "$ROOTFS/etc/runit" "$ROOTFS/etc/service"

cat >"$ROOTFS/etc/runit/1" <<'EOF'
#!/bin/sh
# Stage 1: prepara mounts e ambiente mínimo
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sys /sys 2>/dev/null || true
mount -t devtmpfs dev /dev 2>/dev/null || true
mkdir -p /run /tmp
chmod 1777 /tmp
# hostname opcional
[ -f /etc/hostname ] && hostname "$(cat /etc/hostname)" 2>/dev/null || true
exec /usr/bin/runsvdir -P /etc/service
EOF
chmod +x "$ROOTFS/etc/runit/1"

cat >"$ROOTFS/etc/runit/2" <<'EOF'
#!/bin/sh
# Stage 2: rodando serviços (controlado por runsvdir)
exit 0
EOF
chmod +x "$ROOTFS/etc/runit/2"

cat >"$ROOTFS/etc/runit/3" <<'EOF'
#!/bin/sh
# Stage 3: shutdown básico
sync
umount -a -r 2>/dev/null || true
EOF
chmod +x "$ROOTFS/etc/runit/3"

# Serviço: syslog simples via busybox (opcional; mas útil)
mkdir -p "$ROOTFS/etc/service/syslog"
cat >"$ROOTFS/etc/service/syslog/run" <<'EOF'
#!/bin/sh
exec /bin/busybox syslogd -n
EOF
chmod +x "$ROOTFS/etc/service/syslog/run"

# ===== 7) Instala o adm =====
msg "Instalando adm no rootfs"
cat >"$ROOTFS/usr/sbin/adm" <<'EOF'
#!/bin/sh
set -euo pipefail

ADM_ROOT="${ADM_ROOT:-/}"
ADM_DB="${ADM_DB:-/var/lib/adm/db}"
ADM_RECIPES="${ADM_RECIPES:-/var/lib/adm/recipes}"
ADM_DIST="${ADM_DIST:-/var/cache/adm/distfiles}"
ADM_BUILD="${ADM_BUILD:-/var/cache/adm/build}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

msg(){ printf '%s\n' "adm: $*"; }
die(){ printf '%s\n' "adm: ERRO: $*" >&2; exit 1; }

need(){
  command -v "$1" >/dev/null 2>&1 || die "falta comando: $1"
}

fetch(){
  url="$1"; out="$2"
  [ -f "$out" ] && return 0
  msg "download: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 3 -o "$out" "$url"
  else
    wget -O "$out" "$url"
  fi
}

extract(){
  arc="$1"; dir="$2"
  rm -rf "$dir"; mkdir -p "$dir"
  case "$arc" in
    *.tar.gz|*.tgz) tar -xzf "$arc" -C "$dir" --strip-components=1 ;;
    *.tar.xz)       tar -xJf "$arc" -C "$dir" --strip-components=1 ;;
    *.tar.bz2)      tar -xjf "$arc" -C "$dir" --strip-components=1 ;;
    *.tar)          tar -xf "$arc" -C "$dir" --strip-components=1 ;;
    *) die "arquivo desconhecido: $arc" ;;
  esac
}

db_has(){ [ -f "$ADM_DB/$1.installed" ]; }
db_mark(){ mkdir -p "$ADM_DB"; : >"$ADM_DB/$1.installed"; }

run_recipe(){
  pkg="$1"
  r="$ADM_RECIPES/$pkg.sh"
  [ -f "$r" ] || die "recipe não encontrado: $pkg ($r)"
  # shellcheck disable=SC1090
  . "$r"
  : "${pkgname:?}" "${pkgver:?}" "${srcurl:?}"

  mkdir -p "$ADM_DIST" "$ADM_BUILD" "$ADM_DB"
  arc="$ADM_DIST/${pkgname}-${pkgver}.${srcext:-tar.gz}"
  src="$ADM_BUILD/${pkgname}-${pkgver}"

  need tar
  need make

  fetch "$srcurl" "$arc"
  extract "$arc" "$src"

  msg "build: $pkgname-$pkgver"
  ( cd "$src"; build )
  msg "install: $pkgname-$pkgver"
  ( cd "$src"; install_pkg )
  db_mark "$pkgname"
  msg "ok: $pkgname"
}

cmd="${1:-help}"
case "$cmd" in
  help)
    cat <<EOH
Uso:
  adm list
  adm status
  adm build <pkg>
  adm install <pkg>     (alias de build)
  adm shell             (abre um shell no sistema atual)
EOH
    ;;
  list)
    ls -1 "$ADM_RECIPES" 2>/dev/null | sed 's/\.sh$//' || true
    ;;
  status)
    ls -1 "$ADM_DB" 2>/dev/null | sed 's/\.installed$//' || true
    ;;
  build|install)
    pkg="${2:-}"; [ -n "$pkg" ] || die "informe o pacote"
    run_recipe "$pkg"
    ;;
  shell)
    exec /bin/sh
    ;;
  *)
    die "comando inválido: $cmd"
    ;;
esac
EOF
chmod +x "$ROOTFS/usr/sbin/adm"

# ===== 8) Recipes mínimas iniciais (exemplos) =====
msg "Criando recipes básicas (exemplos)"
cat >"$ROOTFS/var/lib/adm/recipes/wayland.sh" <<'EOF'
pkgname=wayland
pkgver=1.23.0
srcext=tar.xz
srcurl="https://gitlab.freedesktop.org/wayland/wayland/-/releases/${pkgver}/downloads/${pkgname}-${pkgver}.tar.xz"

build() {
  # Exemplo: você vai precisar de meson/ninja; mantenha isso como “meta” depois
  echo "Este recipe é um placeholder. Instale meson/ninja e ajuste aqui."
  exit 1
}
install_pkg() { exit 1; }
EOF

cat >"$ROOTFS/var/lib/adm/recipes/seatd.sh" <<'EOF'
pkgname=seatd
pkgver=0.9.1
srcext=tar.gz
srcurl="https://git.sr.ht/~kennylevinsen/seatd/archive/${pkgver}.tar.gz"

build() { echo "Placeholder: seatd normalmente usa meson."; exit 1; }
install_pkg() { exit 1; }
EOF

# ===== 9) Arquivos mínimos =====
msg "Criando arquivos mínimos de /etc"
cat >"$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF

cat >"$ROOTFS/etc/group" <<'EOF'
root:x:0:
EOF

cat >"$ROOTFS/etc/hostname" <<'EOF'
muslbox
EOF

# ===== 10) Dicas de chroot =====
msg "Concluído."
cat <<EOF

Próximos passos (host):
  sudo mount --bind /dev  "$ROOTFS/dev"
  sudo mount --bind /proc "$ROOTFS/proc"
  sudo mount --bind /sys  "$ROOTFS/sys"

Entrar no chroot:
  sudo chroot "$ROOTFS" /bin/sh

Dentro do chroot:
  /usr/sbin/adm list
  /usr/sbin/adm status

Observação:
  Esta base é propositalmente mínima. Você vai evoluir via recipes no /var/lib/adm/recipes.
EOF
