#!/bin/sh
set -eu

BB_URL="https://busybox.net/downloads/busybox-${PKGVER}.tar.bz2"
BB_TARBALL="${WORKDIR}/busybox-${PKGVER}.tar.bz2"
BB_SHA256="b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314"

# Para sistema final, eu recomendo dinâmico (musl) por padrão.
# Se você quiser estático mesmo no sistema final: export BUSYBOX_STATIC=1
: "${BUSYBOX_STATIC:=0}"

have() { command -v "$1" >/dev/null 2>&1; }

fetch_file() {
  url=$1 out=$2
  if have wget; then
    wget -O "$out.tmp" "$url"
  elif have curl; then
    curl -L -o "$out.tmp" "$url"
  else
    echo "ERRO: precisa de wget ou curl para baixar fontes." >&2
    exit 1
  fi
  mv -f "$out.tmp" "$out"
}

sha256_check() {
  file=$1 expected=$2
  got=$(sha256sum "$file" | awk '{print $1}')
  if [ "$got" != "$expected" ]; then
    echo "ERRO: SHA256 inválido para $(basename "$file")" >&2
    echo "Esperado: $expected" >&2
    echo "Obtido:   $got" >&2
    exit 1
  fi
}

# sed -i não é POSIX, então fazemos em arquivo temporário
cfg_set() {
  k=$1 v=$2 f=.config
  if [ -f "$f" ]; then
    awk -v K="$k" -v V="$v" '
      BEGIN{done=0}
      $0 ~ "^"K"=" {print K"="V; done=1; next}
      $0 ~ "^# "K" is not set" {print K"="V; done=1; next}
      {print}
      END{if(!done) print K"="V}
    ' "$f" >"$f.tmp"
    mv -f "$f.tmp" "$f"
  else
    printf "%s=%s\n" "$k" "$v" >"$f"
  fi
}

cfg_unset() {
  k=$1 f=.config
  if [ -f "$f" ]; then
    awk -v K="$k" '
      $0 ~ "^"K"=" {print "# "K" is not set"; done=1; next}
      $0 ~ "^# "K" is not set" {print; done=1; next}
      {print}
      END{if(!done) print "# "K" is not set"}
    ' "$f" >"$f.tmp"
    mv -f "$f.tmp" "$f"
  else
    printf "# %s is not set\n" "$k" >"$f"
  fi
}

hook_pre_install() { :; }
hook_post_install() { :; }
hook_pre_remove() { :; }
hook_post_remove() { :; }

pkg_fetch() {
  mkdir -p "$WORKDIR"
  if [ -f "$BB_TARBALL" ]; then
    sha256_check "$BB_TARBALL" "$BB_SHA256"
    return 0
  fi
  fetch_file "$BB_URL" "$BB_TARBALL"
  sha256_check "$BB_TARBALL" "$BB_SHA256"
}

pkg_unpack() {
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"

  # Extração robusta de .tar.bz2:
  # 1) tenta tar -xjf
  # 2) fallback: bzcat/bunzip2 | tar -xf -
  if tar -C "$SRCDIR" --strip-components=1 -xjf "$BB_TARBALL" >/dev/null 2>&1; then
    :
  else
    if have bzcat; then
      bzcat "$BB_TARBALL" | tar -C "$SRCDIR" --strip-components=1 -xf -
    elif have bunzip2; then
      bunzip2 -c "$BB_TARBALL" | tar -C "$SRCDIR" --strip-components=1 -xf -
    else
      echo "ERRO: não foi possível extrair .tar.bz2 (precisa tar -j ou bzcat/bunzip2)." >&2
      exit 1
    fi
  fi
}

pkg_build() {
  cd "$SRCDIR"

  # Build limpo
  make distclean >/dev/null 2>&1 || true
  make defconfig

  # Shell e /bin/sh
  cfg_set CONFIG_ASH y
  cfg_set CONFIG_SH_IS_ASH y

  # Instala applets como symlinks (tradicional)
  cfg_set CONFIG_INSTALL_APPLET_SYMLINKS y

  # Útil em sistema mínimo
  cfg_set CONFIG_FEATURE_SH_STANDALONE y

  # Sem NLS
  cfg_unset CONFIG_FEATURE_NLS

  # Static opcional
  if [ "$BUSYBOX_STATIC" = "1" ]; then
    cfg_set CONFIG_STATIC y
  else
    cfg_unset CONFIG_STATIC
  fi

  # Aceita defaults para opções novas (não-interativo)
  yes "" | make oldconfig >/dev/null

  make -j"$PM_JOBS"
}

pkg_install() {
  cd "$SRCDIR"

  # LAYOUT TRADICIONAL:
  # instalar na raiz do sistema, não em ${PM_PREFIX}.
  # Isso coloca busybox e links em /bin, /sbin, /usr/bin etc conforme config do BusyBox.
  make CONFIG_PREFIX="$DESTDIR" install

  # Garantir busybox em /bin (algumas configs podem colocar em /usr/bin)
  if [ ! -x "$DESTDIR/bin/busybox" ] && [ -x "$DESTDIR/usr/bin/busybox" ]; then
    mkdir -p "$DESTDIR/bin"
    mv -f "$DESTDIR/usr/bin/busybox" "$DESTDIR/bin/busybox"
    # se existirem links em /usr/bin apontando para busybox, manter tudo coerente:
    # (na prática, o install do busybox cria links relativos; vamos só garantir /bin/sh)
  fi

  # Garantir /bin/sh apontando para busybox
  if [ ! -e "$DESTDIR/bin/sh" ]; then
    ln -s busybox "$DESTDIR/bin/sh" 2>/dev/null || true
  fi
}
