#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# ADM - minimal rolling build/install manager (musl/runit friendly)
# Features:
# - recipes in categories (dirs): base/foo.sh, gcc/bar.sh, programa/baz.sh ...
# - dependency resolution + reverse-deps
# - source cache + resume + progress
# - sha256/md5 verification (if provided in recipe)
# - patches directory per recipe, auto-apply
# - hooks for all stages (optional functions in recipe)
# - binary package cache: .tar.zst (fallback .tar.xz)
# - build resume via stamps
# - rebuild when deps signature changes
# - upgrade transactional: build+stage+pack+install, then remove obsolete old files
# - uninstall with manifests and cleanup empty dirs
# - clean commands
# - optional clean chroot per build via overlayfs
# ============================================================

# -------------------------
# Paths / Config
# -------------------------
ADM_ROOT="${ADM_ROOT:-/}"                         # target root (usually / inside chroot, or /mnt/adm/rootfs)
ADM_STATE="${ADM_STATE:-/var/cache/adm}"          # caches/build/pkgs
ADM_DB="${ADM_DB:-/var/lib/adm/db}"               # installed db + stamps
ADM_RECIPES="${ADM_RECIPES:-/var/lib/adm/recipes}"# recipes root (categories are subdirs)
ADM_MANIFESTS="${ADM_MANIFESTS:-/var/lib/adm/manifests}"
ADM_LOGDIR="${ADM_LOGDIR:-/var/log/adm}"
ADM_LOCK="${ADM_LOCK:-/var/lock/adm.lock}"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
DL_JOBS="${DL_JOBS:-4}"
RESUME="${RESUME:-1}"

# chroot/overlay mode
ADM_CHROOT_MODE="${ADM_CHROOT_MODE:-auto}"  # auto|on|off
ADM_OVERLAY_BASE="${ADM_OVERLAY_BASE:-$ADM_STATE/overlays}"  # overlay staging

mkdir -p \
  "$ADM_STATE"/{distfiles,build,pkgs,backups,tmp} \
  "$ADM_DB" "$ADM_RECIPES" "$ADM_MANIFESTS" "$ADM_LOGDIR" \
  "$(dirname "$ADM_LOCK")" "$ADM_OVERLAY_BASE"

# -------------------------
# UI / Logs
# -------------------------
C_RESET=$'\e[0m'; C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[34m'; C_DIM=$'\e[2m'
ts(){ date +"%Y-%m-%d %H:%M:%S"; }
LOG="$ADM_LOGDIR/adm.log"

msg(){ echo "${C_BLU}adm${C_RESET}: $*" | tee -a "$LOG" >&2; }
ok(){  echo "${C_GRN}adm${C_RESET}: $*" | tee -a "$LOG" >&2; }
warn(){echo "${C_YLW}adm${C_RESET}: $*" | tee -a "$LOG" >&2; }
die(){ echo "${C_RED}adm${C_RESET}: $*" | tee -a "$LOG" >&2; exit 1; }

need(){ command -v "$1" >/dev/null 2>&1 || die "falta comando: $1"; }

# -------------------------
# Lock
# -------------------------
lock_or_die(){
  need flock
  exec 9>"$ADM_LOCK"
  flock -n 9 || die "adm já está rodando (lock ativo)"
}

# -------------------------
# Hash / Utils
# -------------------------
sha256_file(){ sha256sum "$1" | awk '{print $1}'; }
md5_file(){ md5sum "$1" | awk '{print $1}'; }

verify_hashes(){
  local file="$1" sha="${2:-}" md5="${3:-}"
  if [[ -n "$sha" ]]; then
    need sha256sum
    echo "$sha  $file" | sha256sum -c - >/dev/null || die "SHA256 inválido: $(basename "$file")"
  fi
  if [[ -n "$md5" ]]; then
    need md5sum
    echo "$md5  $file" | md5sum -c - >/dev/null || die "MD5 inválido: $(basename "$file")"
  fi
}

# -------------------------
# Download (cache + resume + progress)
# -------------------------
fetch(){
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  if [[ -f "$out" ]]; then
    ok "cache: $(basename "$out")"
    return 0
  fi

  msg "download: $url"
  if command -v curl >/dev/null 2>&1; then
    if [[ "$RESUME" == "1" ]]; then
      curl -L --fail --retry 3 -C - --progress-bar -o "$out.part" "$url"
    else
      curl -L --fail --retry 3 --progress-bar -o "$out.part" "$url"
    fi
    mv -f "$out.part" "$out"
  elif command -v wget >/dev/null 2>&1; then
    if [[ "$RESUME" == "1" ]]; then
      wget -c --show-progress -O "$out.part" "$url"
    else
      wget --show-progress -O "$out.part" "$url"
    fi
    mv -f "$out.part" "$out"
  else
    die "nem curl nem wget"
  fi
}

extract(){
  local arc="$1" dir="$2"
  rm -rf "$dir"; mkdir -p "$dir"
  case "$arc" in
    *.tar.gz|*.tgz)  tar -xzf "$arc" -C "$dir" --strip-components=1 ;;
    *.tar.xz)        tar -xJf "$arc" -C "$dir" --strip-components=1 ;;
    *.tar.bz2)       tar -xjf "$arc" -C "$dir" --strip-components=1 ;;
    *.tar.zst)       tar --zstd -xf "$arc" -C "$dir" --strip-components=1 ;;
    *.tar)           tar -xf "$arc" -C "$dir" --strip-components=1 ;;
    *) die "arquivo desconhecido: $arc" ;;
  esac
}

# -------------------------
# Packaging (tar.zst fallback tar.xz)
# -------------------------
pack_dir(){
  local srcdir="$1" outbase="$2"
  mkdir -p "$(dirname "$outbase")"
  if command -v zstd >/dev/null 2>&1 && tar --help 2>/dev/null | grep -qi zstd; then
    # zstd optimization: fast decompression, good ratio
    ZSTD_CLEVEL="${ZSTD_CLEVEL:-19}"
    tar --zstd -cf "${outbase}.tar.zst" -C "$srcdir" .
    echo "${outbase}.tar.zst"
  else
    warn "zstd indisponível; usando xz"
    tar -cJf "${outbase}.tar.xz" -C "$srcdir" .
    echo "${outbase}.tar.xz"
  fi
}

# -------------------------
# DB helpers
# -------------------------
id_of(){ echo "$1-$2"; }

db_installed(){ [[ -f "$ADM_DB/$1.installed" ]]; }
db_mark(){ : >"$ADM_DB/$1.installed"; }
db_unmark(){ rm -f "$ADM_DB/$1.installed"; }

stamp_has(){ [[ -f "$ADM_DB/$1.$2.stamp" ]]; }
stamp_set(){ : >"$ADM_DB/$1.$2.stamp"; }
stamp_clear(){ rm -f "$ADM_DB/$1."*.stamp 2>/dev/null || true; }

# store build signature (to detect dep changes)
sig_get(){ [[ -f "$ADM_DB/$1.sig" ]] && cat "$ADM_DB/$1.sig" || true; }
sig_set(){ echo "$2" >"$ADM_DB/$1.sig"; }

# -------------------------
# Recipe discovery (categories)
# -------------------------
# recipe "name" is path without .sh, e.g. base/musl, programa/sway
list_recipes(){
  ( cd "$ADM_RECIPES" && find . -type f -name '*.sh' | sed 's|^\./||; s|\.sh$||' | sort )
}

recipe_path(){
  local r="$1"
  echo "$ADM_RECIPES/$r.sh"
}

# patch dir convention:
# - same base name with .d/patches:  base/musl.sh -> base/musl.d/patches/*.patch
# - or base/musl/patches/*.patch (alt)
patch_dirs_for(){
  local r="$1"
  local rp="$ADM_RECIPES/$r.sh"
  local base="${rp%.sh}"
  echo "${base}.d/patches"
  echo "${base}/patches"
}

# -------------------------
# Hook runner
# -------------------------
run_hook(){
  local hook="$1"
  if [[ "$(type -t "$hook" || true)" == "function" ]]; then
    msg "hook: $hook"
    "$hook"
  fi
}

# -------------------------
# Recipe load (each load resets variables)
# Required in recipe:
#   pkgname pkgver srcurl
# Optional:
#   srcext sha256 md5 deps=() provides=() description category
# Required funcs:
#   build() install_pkg()
# Optional stage hooks:
#   pre_fetch post_fetch pre_extract post_extract pre_patch post_patch pre_build post_build pre_install post_install pre_pack post_pack
#   pre_upgrade post_upgrade pre_remove post_remove
# -------------------------
reset_recipe_vars(){
  unset pkgname pkgver srcurl srcext sha256 md5 description category
  deps=(); provides=()
  # unset any hook funcs? not possible safely; rely on unique names per load by sourcing in subshell where needed
}

load_recipe(){
  local r="$1"
  local file
  file="$(recipe_path "$r")"
  [[ -f "$file" ]] || die "recipe não encontrado: $r"

  reset_recipe_vars
  # shellcheck disable=SC1090
  source "$file"

  [[ -n "${pkgname:-}" && -n "${pkgver:-}" && -n "${srcurl:-}" ]] || die "metadata incompleto em $r"
  [[ "$(type -t build || true)" == "function" ]] || die "recipe sem build(): $r"
  [[ "$(type -t install_pkg || true)" == "function" ]] || die "recipe sem install_pkg(): $r"
  deps=("${deps[@]:-}")
  provides=("${provides[@]:-}")
}

# -------------------------
# Dep resolution (DFS topo sort) + reverse deps
# -------------------------
declare -A VISITING VISITED
order=()

resolve_deps(){
  local r="$1"
  if [[ "${VISITED[$r]:-0}" == 1 ]]; then return 0; fi
  if [[ "${VISITING[$r]:-0}" == 1 ]]; then die "ciclo de dependências detectado em: $r"; fi
  VISITING["$r"]=1

  load_recipe "$r"
  for d in "${deps[@]:-}"; do
    # allow deps as recipe names (category/name) only
    [[ -n "$d" ]] || continue
    resolve_deps "$d"
  done

  VISITING["$r"]=0
  VISITED["$r"]=1
  order+=("$r")
}

# reverse deps among installed packages (by recipe)
installed_list(){
  find "$ADM_DB" -maxdepth 1 -type f -name '*.installed' -printf '%f\n' 2>/dev/null | sed 's/\.installed$//' | sort
}

# mapping id -> recipe name stored in db:
# we record recipe path in $ADM_DB/<id>.recipe
db_recipe_set(){ echo "$2" >"$ADM_DB/$1.recipe"; }
db_recipe_get(){ [[ -f "$ADM_DB/$1.recipe" ]] && cat "$ADM_DB/$1.recipe" || true; }

reverse_deps(){
  local target_id="$1"
  local out=()
  while read -r iid; do
    [[ -n "$iid" ]] || continue
    local rr
    rr="$(db_recipe_get "$iid")"
    [[ -n "$rr" ]] || continue
    # load in subshell to avoid overwriting globals
    local deps_line
    deps_line="$(bash -c "source \"$(recipe_path "$rr")\"; printf '%s\n' \"\${deps[*]:-}\"" 2>/dev/null || true)"
    for d in $deps_line; do
      # d is recipe name. check its current id
      local did
      did="$(bash -c "source \"$(recipe_path "$d")\"; echo \"\${pkgname}-\${pkgver}\"" 2>/dev/null || true)"
      if [[ "$did" == "$target_id" ]]; then
        out+=("$iid")
      fi
    done
  done < <(installed_list)
  printf '%s\n' "${out[@]:-}" | sort -u
}

# -------------------------
# Build signature (detect dep changes)
# signature = hash(recipe file + patches list hashes + deps' signatures + key env)
# -------------------------
recipe_sig(){
  local r="$1"
  local rp; rp="$(recipe_path "$r")"
  [[ -f "$rp" ]] || die "recipe ausente: $r"

  local tmp="$ADM_STATE/tmp/sig.$$.txt"
  : >"$tmp"
  echo "RECIPE=$(sha256_file "$rp")" >>"$tmp"

  # patches content hashes
  local pd
  while read -r pd; do
    [[ -d "$pd" ]] || continue
    find "$pd" -maxdepth 1 -type f -name '*.patch' | sort | while read -r p; do
      echo "PATCH=$(basename "$p")=$(sha256_file "$p")" >>"$tmp"
    done
  done < <(patch_dirs_for "$r")

  # env inputs that affect ABI/rebuild
  echo "JOBS=$JOBS" >>"$tmp"
  echo "CC=${CC:-}" >>"$tmp"
  echo "CXX=${CXX:-}" >>"$tmp"
  echo "CFLAGS=${CFLAGS:-}" >>"$tmp"
  echo "LDFLAGS=${LDFLAGS:-}" >>"$tmp"

  # deps signatures (by current id)
  local deps_line
  deps_line="$(bash -c "source \"$(recipe_path "$r")\"; printf '%s\n' \"\${deps[*]:-}\"" 2>/dev/null || true)"
  for d in $deps_line; do
    local did ds
    did="$(bash -c "source \"$(recipe_path "$d")\"; echo \"\${pkgname}-\${pkgver}\"" 2>/dev/null || true)"
    ds="$(sig_get "$did")"
    echo "DEP=$did=$ds" >>"$tmp"
  done

  sha256_file "$tmp"
  rm -f "$tmp"
}

# -------------------------
# Patching
# -------------------------
apply_patches(){
  local r="$1" bdir="$2"
  run_hook pre_patch

  local applied=0
  while read -r pd; do
    [[ -d "$pd" ]] || continue
    local p
    while read -r p; do
      msg "patch: $(basename "$p")"
      ( cd "$bdir" && patch -p1 --forward --batch <"$p" ) || die "falha ao aplicar patch: $p"
      applied=1
    done < <(find "$pd" -maxdepth 1 -type f -name '*.patch' | sort)
  done < <(patch_dirs_for "$r")

  if [[ "$applied" -eq 0 ]]; then
    ok "patches: nenhum"
  fi

  run_hook post_patch
}

# -------------------------
# Clean chroot per build via overlayfs (optional)
# - Creates a merged root view where lower = ADM_ROOT, upper = per-build overlay
# - Build runs inside chroot(merged) with env -i.
# - Requires root + overlayfs.
# Fallback: normal build in bdir, but still env -i for cleanliness.
# -------------------------
can_overlay(){
  [[ "$(id -u)" == "0" ]] || return 1
  need mount
  grep -q overlay /proc/filesystems 2>/dev/null || return 1
  return 0
}

overlay_mount(){
  local id="$1"
  local mnt="$ADM_OVERLAY_BASE/$id/mnt"
  local upper="$ADM_OVERLAY_BASE/$id/upper"
  local work="$ADM_OVERLAY_BASE/$id/work"

  mkdir -p "$mnt" "$upper" "$work"
  mount -t overlay overlay -o "lowerdir=$ADM_ROOT,upperdir=$upper,workdir=$work" "$mnt"
  echo "$mnt"
}

overlay_umount(){
  local id="$1"
  local mnt="$ADM_OVERLAY_BASE/$id/mnt"
  mountpoint -q "$mnt" && umount "$mnt"
}

run_in_build_root(){
  local id="$1" bdir="$2" cmdfile="$3"

  local mode="$ADM_CHROOT_MODE"
  if [[ "$mode" == "auto" ]]; then
    if can_overlay; then mode="on"; else mode="off"; fi
  fi

  if [[ "$mode" == "on" ]]; then
    can_overlay || { warn "overlayfs indisponível; fallback sem chroot"; mode="off"; }
  fi

  if [[ "$mode" == "on" ]]; then
    local mnt
    mnt="$(overlay_mount "$id")"
    # Bind build dir into overlay view
    mkdir -p "$mnt/.adm-build"
    mount --bind "$bdir" "$mnt/.adm-build"
    # minimal mounts
    mkdir -p "$mnt/proc" "$mnt/sys" "$mnt/dev"
    mount -t proc proc "$mnt/proc" || true
    mount -t sysfs sys "$mnt/sys" || true
    mount --bind /dev "$mnt/dev" || true

    msg "chroot build: $id"
    chroot "$mnt" /usr/bin/env -i \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      HOME="/root" \
      SHELL="/bin/sh" \
      JOBS="$JOBS" \
      bash "/.adm-build/$cmdfile"

    # cleanup mounts
    mountpoint -q "$mnt/dev" && umount "$mnt/dev" || true
    mountpoint -q "$mnt/sys" && umount "$mnt/sys" || true
    mountpoint -q "$mnt/proc" && umount "$mnt/proc" || true
    umount "$mnt/.adm-build" || true
    overlay_umount "$id"
  else
    warn "build sem chroot (isolamento parcial via env -i)"
    /usr/bin/env -i \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      HOME="/root" \
      SHELL="/bin/sh" \
      JOBS="$JOBS" \
      bash "$bdir/$cmdfile"
  fi
}

# -------------------------
# Install/remove helpers using manifests
# -------------------------
manifest_path(){ echo "$ADM_MANIFESTS/$1.files"; }

record_manifest(){
  local id="$1" staged="$2"
  mkdir -p "$ADM_MANIFESTS"
  ( cd "$staged" && find . \( -type f -o -type l \) -print | sort ) >"$(manifest_path "$id")"
}

remove_files_from_manifest(){
  local id="$1"
  local mp; mp="$(manifest_path "$id")"
  [[ -f "$mp" ]] || die "manifest não encontrado para $id"
  run_hook pre_remove

  # remove files/links
  while read -r rel; do
    [[ -n "$rel" ]] || continue
    local abs="$ADM_ROOT/${rel#./}"
    if [[ -L "$abs" || -f "$abs" ]]; then
      rm -f "$abs"
    fi
  done <"$mp"

  # cleanup empty dirs (bottom-up)
  # derive dirs from manifest list
  awk -F/ 'NF>1{ $NF=""; print }' "$mp" \
    | sed 's|/*$||' | sort -u | awk 'NF' \
    | awk '{print length, $0}' | sort -rn | cut -d' ' -f2- \
    | while read -r d; do
        [[ -n "$d" ]] || continue
        local ad="$ADM_ROOT/${d#./}"
        [[ "$ad" == "$ADM_ROOT" ]] && continue
        rmdir "$ad" 2>/dev/null || true
      done

  run_hook post_remove
}

# compute obsolete files old - new (for upgrade cleanup)
remove_obsolete_after_upgrade(){
  local oldid="$1" newid="$2"
  local oldm newm
  oldm="$(manifest_path "$oldid")"
  newm="$(manifest_path "$newid")"
  [[ -f "$oldm" && -f "$newm" ]] || return 0

  comm -23 "$oldm" "$newm" | while read -r rel; do
    [[ -n "$rel" ]] || continue
    local abs="$ADM_ROOT/${rel#./}"
    if [[ -L "$abs" || -f "$abs" ]]; then
      rm -f "$abs"
    fi
  done
}

backup_id(){
  local id="$1"
  local outbase="$ADM_STATE/backups/${id}-$(date +%Y%m%d-%H%M%S)"
  if command -v zstd >/dev/null 2>&1 && tar --help 2>/dev/null | grep -qi zstd; then
    tar --zstd -cf "${outbase}.tar.zst" -C "$ADM_ROOT" .
    echo "${outbase}.tar.zst"
  else
    tar -cJf "${outbase}.tar.xz" -C "$ADM_ROOT" .
    echo "${outbase}.tar.xz"
  fi
}

restore_backup(){
  local file="$1"
  msg "restaurando backup: $(basename "$file")"
  tar -xf "$file" -C "$ADM_ROOT"
}

# -------------------------
# Core build/install (staging -> pack -> install)
# -------------------------
build_and_install(){
  local r="$1" force="${2:-0}" do_upgrade="${3:-0}"

  # Load in current shell
  load_recipe "$r"
  local id; id="$(id_of "$pkgname" "$pkgver")"
  local pkglog="$ADM_LOGDIR/$id.log"
  local arc="$ADM_STATE/distfiles/${id}.${srcext:-tar.gz}"
  local bdir="$ADM_STATE/build/$id"
  local staged="$ADM_STATE/build/${id}.pkgdir"
  local pkgbase="$ADM_STATE/pkgs/$id"

  # determine previous installed version for same pkgname (rolling)
  local oldid=""
  while read -r iid; do
    [[ -n "$iid" ]] || continue
    if [[ "$iid" == "$pkgname-"* ]]; then
      oldid="$iid"
    fi
  done < <(installed_list)

  # compute new signature
  local newsig
  newsig="$(recipe_sig "$r")"
  local oldsig=""
  [[ -n "$oldid" ]] && oldsig="$(sig_get "$oldid")"

  # rebuild triggers:
  # - not installed at all
  # - force
  # - signature changed (deps/recipe/patch/env)
  if [[ "$force" -eq 0 && -n "$oldid" && "$oldid" == "$id" && "$newsig" == "$oldsig" ]]; then
    ok "up-to-date: $id"
    return 0
  fi

  if [[ -f "${pkgbase}.tar.zst" || -f "${pkgbase}.tar.xz" ]]; then
    # if signature changed, cached package may be stale; we ignore cache in that case
    if [[ "$force" -eq 0 && "$newsig" == "$(sig_get "$id")" && db_installed "$id" ]]; then
      ok "bin-cache ok: $id"
      return 0
    fi
  fi

  run_hook pre_fetch
  fetch "$srcurl" "$arc"
  run_hook post_fetch
  verify_hashes "$arc" "${sha256:-}" "${md5:-}"

  run_hook pre_extract
  if [[ "$RESUME" == "1" && -d "$bdir" && stamp_has "$id" extracted ]]; then
    ok "resume: build dir existente ($id)"
  else
    extract "$arc" "$bdir"
    stamp_set "$id" extracted
  fi
  run_hook post_extract

  apply_patches "$r" "$bdir"

  rm -rf "$staged"; mkdir -p "$staged"

  # build command file for (optional) chroot execution
  local cmdfile=".adm-stage.sh"
  cat >"$bdir/$cmdfile" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "/.adm-build" >/dev/null 2>&1 || cd "$bdir"
export JOBS="${JOBS}"
export MAKEFLAGS="-j${JOBS}"
# Build
$(declare -f build)
build
# Install staging
$(declare -f install_pkg)
export DESTDIR="$staged"
export PREFIX="/usr"
install_pkg
EOF
  chmod +x "$bdir/$cmdfile"

  run_hook pre_build
  msg "build: $id"
  {
    echo "[$(ts)] build $id"
    ( cd "$bdir" && build )  # direct build (kept for log)
  } >>"$pkglog" 2>&1 || die "build falhou: $id (veja $pkglog)"
  stamp_set "$id" built
  run_hook post_build

  run_hook pre_install
  msg "install (staging): $id"
  {
    echo "[$(ts)] install $id"
    ( cd "$bdir" && DESTDIR="$staged" PREFIX="/usr" install_pkg )
  } >>"$pkglog" 2>&1 || die "install staging falhou: $id (veja $pkglog)"
  stamp_set "$id" staged
  run_hook post_install

  record_manifest "$id" "$staged"

  run_hook pre_pack
  msg "pack: $id"
  local pkgfile
  pkgfile="$(pack_dir "$staged" "$pkgbase")"
  run_hook post_pack
  ok "pacote: $(basename "$pkgfile")"

  # transactional upgrade:
  # 1) backup root (optional but safest)
  # 2) install new package
  # 3) if old exists, remove obsolete old files
  # 4) mark DB, signature, recipe mapping
  local backup=""
  if [[ "$do_upgrade" -eq 1 && -n "$oldid" ]]; then
    run_hook pre_upgrade
    msg "backup antes do upgrade: $oldid -> $id"
    backup="$(backup_id "$oldid")"
  fi

  msg "install (root): $id"
  if ! tar -xf "$pkgfile" -C "$ADM_ROOT"; then
    [[ -n "$backup" ]] && restore_backup "$backup"
    die "falha ao instalar pacote: $id"
  fi

  # remove obsolete old files only after success
  if [[ "$do_upgrade" -eq 1 && -n "$oldid" && "$oldid" != "$id" ]]; then
    msg "cleanup obsolete: $oldid -> $id"
    remove_obsolete_after_upgrade "$oldid" "$id"
    db_unmark "$oldid"
  fi

  db_mark "$id"
  db_recipe_set "$id" "$r"
  sig_set "$id" "$newsig"
  run_hook post_upgrade || true

  ok "instalado: $id"
}

# -------------------------
# High-level operations
# -------------------------
install_cmd(){
  local r="$1" force="${2:-0}"
  order=(); VISITING=(); VISITED=()
  resolve_deps "$r"
  for x in "${order[@]}"; do
    load_recipe "$x"
    build_and_install "$x" "$force" 0
  done
}

upgrade_cmd(){
  local r="$1" force="${2:-0}"
  order=(); VISITING=(); VISITED=()
  resolve_deps "$r"
  for x in "${order[@]}"; do
    load_recipe "$x"
    build_and_install "$x" "$force" 1
  done
}

upgrade_all_cmd(){
  # upgrade everything installed, re-sorting deps by recipes
  # collect installed recipe names
  mapfile -t ids < <(installed_list)
  local recs=()
  for id in "${ids[@]:-}"; do
    local rr; rr="$(db_recipe_get "$id")"
    [[ -n "$rr" ]] && recs+=("$rr")
  done
  recs=($(printf '%s\n' "${recs[@]:-}" | sort -u))

  # build a combined topo order by resolving each recipe (merged)
  order=(); VISITING=(); VISITED=()
  for r in "${recs[@]:-}"; do resolve_deps "$r"; done
  # now upgrade in topo order
  for x in "${order[@]}"; do
    load_recipe "$x"
    build_and_install "$x" 0 1
  done
}

rebuild_all_cmd(){
  # Force rebuild of installed packages in topological order
  mapfile -t ids < <(installed_list)
  local recs=()
  for id in "${ids[@]:-}"; do
    local rr; rr="$(db_recipe_get "$id")"
    [[ -n "$rr" ]] && recs+=("$rr")
  done
  recs=($(printf '%s\n' "${recs[@]:-}" | sort -u))

  order=(); VISITING=(); VISITED=()
  for r in "${recs[@]:-}"; do resolve_deps "$r"; done

  for x in "${order[@]}"; do
    load_recipe "$x"
    build_and_install "$x" 1 1
  done
}

uninstall_cmd(){
  local r="$1" force="${2:-0}"
  load_recipe "$r"
  local id; id="$(id_of "$pkgname" "$pkgver")"

  db_installed "$id" || die "não instalado: $id"

  # reverse deps protection
  local rev
  rev="$(reverse_deps "$id" || true)"
  if [[ -n "$rev" && "$force" -eq 0 ]]; then
    die "não removido: $id é dependência de: $(echo "$rev" | tr '\n' ' ') (use --force)"
  fi

  remove_files_from_manifest "$id"
  db_unmark "$id"
  rm -f "$(manifest_path "$id")" "$ADM_DB/$id.recipe" "$ADM_DB/$id.sig" 2>/dev/null || true
  stamp_clear "$id"
  ok "removido: $id"
}

clean_cmd(){
  local mode="${1:-all}"
  case "$mode" in
    dist)  rm -rf "$ADM_STATE/distfiles"/*; ok "limpo: distfiles" ;;
    build) rm -rf "$ADM_STATE/build"/*; ok "limpo: build" ;;
    pkgs)  rm -rf "$ADM_STATE/pkgs"/*; ok "limpo: pkgs cache" ;;
    logs)  rm -rf "$ADM_LOGDIR"/*; ok "limpo: logs" ;;
    all)
      rm -rf "$ADM_STATE"/{distfiles,build,pkgs,tmp}/* "$ADM_LOGDIR"/* 2>/dev/null || true
      ok "limpo: state+logs (não remove rootfs)"
      ;;
    *)
      die "clean inválido: use dist|build|pkgs|logs|all"
      ;;
  esac
}

sync_cmd(){
  # sync recipes via git pull (if ADM_RECIPES is a git repo)
  need git
  [[ -d "$ADM_RECIPES/.git" ]] || die "recipes não é repo git: $ADM_RECIPES"
  msg "sync: git pull em $ADM_RECIPES"
  ( cd "$ADM_RECIPES" && git pull --rebase )
  ok "sync concluído"
}

search_cmd(){
  local q="${1:-}"
  [[ -n "$q" ]] || die "use: adm search <termo>"
  while read -r r; do
    # load in subshell to avoid globals
    local meta
    meta="$(bash -c "source \"$(recipe_path "$r")\"; echo \"\${pkgname}-\${pkgver}\"" 2>/dev/null || true)"
    [[ -n "$meta" ]] || continue
    if echo "$r $meta" | grep -qi -- "$q"; then
      local mark="[ ]"
      db_installed "$meta" && mark="[✔]"
      printf '%s %s (%s)\n' "$mark" "$r" "$meta"
    fi
  done < <(list_recipes)
}

info_cmd(){
  local r="$1"
  load_recipe "$r"
  local id; id="$(id_of "$pkgname" "$pkgver")"
  local inst="no"
  db_installed "$id" && inst="yes"
  local sig=""; sig="$(sig_get "$id")"
  cat <<EOF
Recipe:        $r
ID:            $id
Installed:     $inst
Version:       $pkgver
Source:        $srcurl
Checksums:     sha256=${sha256:-<none>} md5=${md5:-<none>}
Deps:          ${deps[*]:-<none>}
Provides:      ${provides[*]:-<none>}
Description:   ${description:-<none>}
Category:      ${category:-$(dirname "$r")}
Signature:     ${sig:-<none>}
Manifest:      $(manifest_path "$id")
EOF
}

status_cmd(){
  installed_list | sed 's/^/- /'
}

list_cmd(){
  list_recipes
}

# -------------------------
# CLI
# -------------------------
usage(){
  cat <<'EOU'
Uso:
  adm sync
  adm list
  adm status
  adm search <termo>              (mostra [✔] se instalado)
  adm info <recipe>

  adm install <recipe> [--force]
  adm upgrade <recipe> [--force]  (upgrade transacional)
  adm upgrade-all                 (upgrade de tudo instalado)
  adm rebuild-all                 (rebuild de tudo instalado reordenando deps)

  adm uninstall <recipe> [--force]
  adm clean [dist|build|pkgs|logs|all]

Notas:
- recipe é o caminho relativo em recipes sem .sh (ex.: base/musl, programa/sway)
- deps devem referenciar recipes (ex.: deps=(base/musl gcc/clang ...))
- patches automáticos:
    base/musl.d/patches/*.patch  ou  base/musl/patches/*.patch
EOU
}

main(){
  lock_or_die

  local cmd="${1:-help}"
  case "$cmd" in
    help) usage ;;
    sync) sync_cmd ;;
    list) list_cmd ;;
    status) status_cmd ;;
    search) shift; search_cmd "${1:-}" ;;
    info) shift; [[ -n "${1:-}" ]] || die "use: adm info <recipe>"; info_cmd "$1" ;;

    install)
      shift
      local force=0 r=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --force) force=1 ;;
          *) r="$1" ;;
        esac
        shift
      done
      [[ -n "$r" ]] || die "use: adm install <recipe>"
      install_cmd "$r" "$force"
      ;;
    upgrade)
      shift
      local force=0 r=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --force) force=1 ;;
          *) r="$1" ;;
        esac
        shift
      done
      [[ -n "$r" ]] || die "use: adm upgrade <recipe>"
      upgrade_cmd "$r" "$force"
      ;;
    upgrade-all) upgrade_all_cmd ;;
    rebuild-all) rebuild_all_cmd ;;

    uninstall)
      shift
      local force=0 r=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --force) force=1 ;;
          *) r="$1" ;;
        esac
        shift
      done
      [[ -n "$r" ]] || die "use: adm uninstall <recipe>"
      uninstall_cmd "$r" "$force"
      ;;

    clean)
      shift
      clean_cmd "${1:-all}"
      ;;
    *)
      die "comando inválido: $cmd (use: adm help)"
      ;;
  esac
}

main "$@"
