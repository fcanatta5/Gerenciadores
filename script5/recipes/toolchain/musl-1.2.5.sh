# /opt/adm/packages/toolchain/musl-1.2.5.sh
#
# musl 1.2.5 + 2 patches de segurança (CVE-2025-26519 / iconv)
# 100% compatível com adm.sh:
# - build() instala em DESTDIR=$PKG_BUILD_ROOT (adm empacota e extrai em $PKG_ROOTFS)
# - hooks pre/post install
# - alinhado a profiles: usa $PKG_ROOTFS como sysroot e /tools/bin do profile no PATH
#
# Patches (upstream commits):
# - e5adcd97b5196e29991b524237381a0202a60659  (iconv: EUC-KR bounds check)
# - c47ad25ea3b484e10326f933e927c0bc8cded3da  (iconv: harden UTF-8 output path)
#
# Observação: esta receita instala musl de forma "base":
#   prefix=/usr, syslibdir=/lib
# e cria /etc/ld-musl-<arch>.path (library search path do loader).

PKG_NAME="musl"
PKG_VERSION="1.2.5"
PKG_DESC="musl libc (with security patches for iconv)"
PKG_DEPENDS="linux-headers binutils-bootstrap gcc-bootstrap"
PKG_CATEGORY="toolchain"
PKG_LIBC="musl"

# Mapear a arquitetura do loader do musl (nome do arquivo ld-musl-*.so.1)
_musl_arch() {
  case "$(uname -m)" in
    x86_64)   echo "x86_64" ;;
    i?86)     echo "i386" ;;
    aarch64)  echo "aarch64" ;;
    armv7l|armv7*) echo "arm" ;;
    armv6l|armv6*) echo "arm" ;;
    riscv64)  echo "riscv64" ;;
    ppc64le)  echo "ppc64le" ;;
    s390x)    echo "s390x" ;;
    loongarch64) echo "loongarch64" ;;
    *)        echo "$(uname -m)" ;;
  esac
}

build() {
  local url="https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"
  local tar="musl-${PKG_VERSION}.tar.gz"
  local src

  src="$(fetch_source "$url" "$tar")"

  mkdir -p "$PKG_BUILD_WORK"
  cd "$PKG_BUILD_WORK"
  rm -rf "musl-${PKG_VERSION}"
  tar xf "$src"
  cd "musl-${PKG_VERSION}"

  # ---------------------------------------------------------------------------
  # Patches de segurança (CVE-2025-26519)
  # ---------------------------------------------------------------------------

  # Patch 1: e5adcd97... (iconv: fix erroneous input validation in EUC-KR decoder)
  patch -p1 <<'EOF'
diff --git a/src/locale/iconv.c b/src/locale/iconv.c
index 9605c8e9..008c93f0 100644
--- a/src/locale/iconv.c
+++ b/src/locale/iconv.c
@@ -502,7 +502,7 @@ size_t iconv(iconv_t cd, char **restrict in, size_t *restrict inb, char **restri

        if (c >= 93 || d >= 94) {
                c += (0xa1-0x81);
                d += 0xa1;
-               if (c >= 93 || c>=0xc6-0x81 && d>0x52)
+               if (c > 0xc6-0x81 || c==0xc6-0x81 && d>0x52)
                        goto ilseq;
                if (d-'A'<26) d = d-'A';
                else if (d-'a'<26) d = d-'a'+26;
EOF

  # Patch 2: c47ad25e... (iconv: harden UTF-8 output code path against input decoder bugs)
  patch -p1 <<'EOF'
diff --git a/src/locale/iconv.c b/src/locale/iconv.c
index 008c93f0..52178950 100644
--- a/src/locale/iconv.c
+++ b/src/locale/iconv.c
@@ -545,6 +545,10 @@ size_t iconv(iconv_t cd, char **restrict in, size_t *restrict inb, char **restri
                        memcpy(*out, tmp, k);
                } else k = wctomb_utf8(*out, c);
+               /* This failure condition should be unreachable, but
+                * is included to prevent decoder bugs from translating
+                * into advancement outside the output buffer range. */
+               if (k>4) goto ilseq;
                *out += k;
                *outb -= k;
                break;
EOF

  # ---------------------------------------------------------------------------
  # Build/install
  # ---------------------------------------------------------------------------

  local sysroot="$PKG_ROOTFS"
  export PATH="${sysroot}/tools/bin:${PATH:-}"

  # Preferir CC do profile musl (normalmente MUSL_TGT-gcc), senão usar gcc.
  # (No profile musl/env.sh sugerido, CC só é exportado quando existe de fato.)
  local cc="${CC:-gcc}"
  export CC="$cc"

  # musl: prefix=/usr e libs essenciais em /lib
  ./configure \
    --prefix=/usr \
    --syslibdir=/lib

  make

  make DESTDIR="$PKG_BUILD_ROOT" install

  # Library search path do loader do musl
  local march
  march="$(_musl_arch)"
  mkdir -p "$PKG_BUILD_ROOT/etc"
  cat > "$PKG_BUILD_ROOT/etc/ld-musl-${march}.path" <<'EOF'
/lib
/usr/lib
/usr/local/lib
EOF
}

pre_install() {
  echo "==> [musl-${PKG_VERSION}] Instalando musl no rootfs do profile via adm"
}

post_install() {
  echo "==> [musl-${PKG_VERSION}] Sanity-check pós-instalação (loader + headers + linkedição)"

  local sysroot="${PKG_ROOTFS:-$ADM_CURRENT_ROOTFS}"
  local march
  march="$(_musl_arch)"

  # 1) Loader do musl (dinâmico) deve existir
  local loader="${sysroot}/lib/ld-musl-${march}.so.1"
  if [ ! -f "$loader" ]; then
    # fallback (algumas variantes podem acabar em /lib64, mas o normal é /lib)
    local alt
    alt="$(find "${sysroot}/lib" "${sysroot}/lib64" -maxdepth 1 -type f -name 'ld-musl-*.so.1' 2>/dev/null | head -n1 || true)"
    if [ -z "$alt" ]; then
      echo "ERRO: loader do musl não encontrado (esperado: $loader)."
      exit 1
    fi
    loader="$alt"
  fi

  # 2) Headers essenciais da libc
  for f in stdio.h stdlib.h unistd.h errno.h; do
    if [ ! -f "${sysroot}/usr/include/${f}" ]; then
      echo "ERRO: header libc ausente: ${sysroot}/usr/include/${f}"
      exit 1
    fi
  done

  # 3) Arquivo de path do loader do musl
  if [ ! -f "${sysroot}/etc/ld-musl-${march}.path" ]; then
    echo "ERRO: ${sysroot}/etc/ld-musl-${march}.path não encontrado."
    exit 1
  fi

  # 4) Teste de linkedição: compila e linka um binário simples contra o sysroot musl
  # Preferimos ${MUSL_TGT}-gcc se existir (profile musl), senão CC/gcc.
  local cc=""
  if [ -n "${MUSL_TGT:-}" ] && command -v "${MUSL_TGT}-gcc" >/dev/null 2>&1; then
    cc="${MUSL_TGT}-gcc"
  elif command -v "${CC:-}" >/dev/null 2>&1; then
    cc="${CC}"
  elif command -v gcc >/dev/null 2>&1; then
    cc="gcc"
  else
    echo "ERRO: nenhum compilador encontrado para sanity-check (MUSL_TGT-gcc/CC/gcc)."
    exit 1
  fi

  local tdir
  tdir="$(mktemp -d)"
  local test_c="${tdir}/t.c"
  local test_bin="${tdir}/t"

  cat > "$test_c" <<'EOF'
#include <stdio.h>
#include <errno.h>
int main(void) {
    puts("musl-ok");
    return 0;
}
EOF

  if ! "$cc" --sysroot="$sysroot" "$test_c" -o "$test_bin" >/dev/null 2>&1; then
    echo "ERRO: falha ao compilar/linkar programa de teste com sysroot=${sysroot}."
    rm -rf "$tdir"
    exit 1
  fi

  # 5) Verifica interpreter do binário (deve apontar para ld-musl)
  if command -v readelf >/dev/null 2>&1; then
    local interp
    interp="$(readelf -l "$test_bin" 2>/dev/null | awk '/Requesting program interpreter/ {print $NF}' | tr -d '[]')"
    if [ -z "$interp" ]; then
      echo "ERRO: não foi possível extrair interpreter do binário de teste (readelf)."
      rm -rf "$tdir"
      exit 1
    fi
    case "$interp" in
      /lib/ld-musl-*.so.1|/lib64/ld-musl-*.so.1) : ;;
      *)
        echo "ERRO: interpreter inesperado no binário de teste: $interp"
        rm -rf "$tdir"
        exit 1
        ;;
    esac
  fi

  rm -rf "$tdir"

  echo "Sanity-check musl ${PKG_VERSION}: OK (loader + headers + linkedição via sysroot)."
}
