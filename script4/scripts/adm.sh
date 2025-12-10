#!/usr/bin/env bash
# Gerenciador de builds / pacotes para um sistema Linux From Scratch
# com perfis glibc/musl, cache de fontes e binários, resolução de
# dependências por Kahn, hooks por pacote, empacotamento, dry-run etc.

set -euo pipefail

###############################################################################
# CONFIGURAÇÃO BASE
###############################################################################

ADM_BASE_DIR="${ADM_BASE_DIR:-/opt/adm}"
ADM_PKG_DIR="${ADM_PKG_DIR:-${ADM_BASE_DIR}/packages}"
ADM_ROOTFS_DIR="${ADM_ROOTFS_DIR:-${ADM_BASE_DIR}/rootfs}"
ADM_CACHE_DIR="${ADM_CACHE_DIR:-${ADM_BASE_DIR}/cache}"
ADM_SRC_CACHE="${ADM_SRC_CACHE:-${ADM_CACHE_DIR}/sources}"
ADM_BIN_CACHE="${ADM_BIN_CACHE:-${ADM_CACHE_DIR}/bin}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_BASE_DIR}/db}"
ADM_DB_PKG_DIR="${ADM_DB_PKG_DIR:-${ADM_DB_DIR}/packages}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_DB_DIR}/states}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_BASE_DIR}/logs}"
ADM_REPO_URL="${ADM_REPO_URL:-}"
ADM_REPO_BRANCH="${ADM_REPO_BRANCH:-main}"

mkdir -p \
  "${ADM_PKG_DIR}" "${ADM_ROOTFS_DIR}" "${ADM_SRC_CACHE}" \
  "${ADM_BIN_CACHE}" "${ADM_DB_PKG_DIR}" "${ADM_STATE_DIR}" \
  "${ADM_LOG_DIR}"

ADM_DRY_RUN=0
ADM_VERBOSE=0
ADM_PROFILE="glibc"
ADM_ROOTFS=""

###############################################################################
# CORES / LOG
###############################################################################

if [ -t 1 ]; then
  C_RESET='\033[0m'
  C_INFO='\033[1;34m'
  C_WARN='\033[1;33m'
  C_ERR='\033[1;31m'
  C_OK='\033[1;32m'
  C_HI='\033[1;35m'
else
  C_RESET=''; C_INFO=''; C_WARN=''; C_ERR=''; C_OK=''; C_HI=''
fi

log() {
  local level="$1"; shift
  local color="$1"; shift
  local msg="$*"
  printf "%b[%s]%b %s\n" "${color}" "${level}" "${C_RESET}" "${msg}" >&2
}

log_info()  { log INFO  "${C_INFO}" "$*"; }
log_warn()  { log WARN  "${C_WARN}" "$*"; }
log_err()   { log ERROR "${C_ERR}" "$*"; }
log_ok()    { log OK    "${C_OK}" "$*"; }

die() {
  log_err "$*"
  exit 1
}

run_cmd() {
  if (( ADM_DRY_RUN )); then
    printf "%b[DRY]%b %s\n" "${C_HI}" "${C_RESET}" "$*" >&2
    return 0
  fi
  if (( ADM_VERBOSE )); then
    printf "%b[RUN]%b %s\n" "${C_HI}" "${C_RESET}" "$*" >&2
  fi
  eval "$@"
}

have_prog() { command -v "$1" >/dev/null 2>&1; }

###############################################################################
# PERFIS / ROOTFS
###############################################################################

set_profile() {
  local p="$1"
  case "$p" in
    glibc|musl)
      ADM_PROFILE="$p"
      ;;
    *)
      die "Perfil inválido: $p (use glibc ou musl)"
      ;;
  esac
}

rootfs_for_profile() {
  if [ -n "${ADM_ROOTFS:-}" ]; then
    printf '%s\n' "${ADM_ROOTFS}"
    return 0
  fi
  local dir="${ADM_ROOTFS_DIR}/${ADM_PROFILE}"
  mkdir -p "${dir}"
  printf '%s\n' "${dir}"
}

###############################################################################
# FUNÇÕES DE CAMINHO
###############################################################################

pkg_script_path() {
  local pkg="$1"
  printf '%s/%s.sh\n' "${ADM_PKG_DIR}" "${pkg}"
}

pkg_meta_path() {
  local pkg="$1" profile="$2"
  printf '%s/%s/%s.meta\n' "${ADM_DB_PKG_DIR}" "${profile}" "${pkg}"
}

pkg_manifest_path() {
  local pkg="$1" profile="$2"
  printf '%s/%s/%s.files\n' "${ADM_DB_PKG_DIR}" "${profile}" "${pkg}"
}

pkg_state_path() {
  local pkg="$1" profile="$2"
  printf '%s/%s/%s.state\n' "${ADM_STATE_DIR}" "${profile}" "${pkg}"
}

pkg_bin_zst_path() {
  local pkg="$1" ver="$2" profile="$3"
  printf '%s/%s/%s-%s.tar.zst\n' "${ADM_BIN_CACHE}" "${profile}" "${pkg}" "${ver}"
}

pkg_bin_xz_path() {
  local pkg="$1" ver="$2" profile="$3"
  printf '%s/%s/%s-%s.tar.xz\n' "${ADM_BIN_CACHE}" "${profile}" "${pkg}" "${ver}"
}

log_file_for() {
  local what="$1" pkg="$2"
  printf '%s/%s__%s.log\n' "${ADM_LOG_DIR}" "${what}" "${pkg//\//__}"
}

###############################################################################
# CARREGAR SCRIPT DE PACOTE
###############################################################################

load_package_script() {
  local pkg="$1"
  local path
  path="$(pkg_script_path "${pkg}")"
  [ -f "${path}" ] || die "Script de pacote não encontrado: ${path}"

  unset PKG_NAME PKG_CATEGORY PKG_VERSION PKG_TRIPLET PKG_PROFILE_DEFAULT
  unset PKG_SOURCES PKG_DEPENDS PKG_SHA256S PKG_MD5S
  unset -f pkg_prepare pkg_build pkg_install pkg_post_install pkg_pre_uninstall pkg_post_uninstall 2>/dev/null || true

  # shellcheck disable=SC1090
  . "${path}"

  : "${PKG_NAME:?PKG_NAME não definido em ${path}}"
  : "${PKG_VERSION:?PKG_VERSION não definido em ${path}}"

  return 0
}

###############################################################################
# DOWNLOAD / CACHE / CHECKSUM
###############################################################################

download_one_url() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname "${dest}")"

  if [[ "${url}" =~ \.git$ || "${url}" =~ ^git:// || "${url}" =~ ^ssh://.*\.git$ ]]; then
    local tmp
    tmp="$(mktemp -d)"
    log_info "Clonando git ${url}"
    run_cmd "git clone --depth=1 '${url}' '${tmp}/repo'"
    (cd "${tmp}/repo" && run_cmd "tar -cf '${dest%.tar.*}.tar' .")
    rm -rf "${tmp}"
    return 0
  fi

  if have_prog curl; then
    run_cmd "curl -L -o '${dest}' '${url}'"
  elif have_prog wget; then
    run_cmd "wget -O '${dest}' '${url}'"
  else
    die "Nem curl nem wget encontrados para download."
  fi
}

verify_checksum() {
  local file="$1" sha256="$2" md5="$3"
  if [ -n "${sha256}" ]; then
    local s
    s="$(sha256sum "${file}" | awk '{print $1}')"
    [ "${s}" = "${sha256}" ] || die "SHA256 incorreto para ${file}"
  fi
  if [ -n "${md5}" ]; then
    local m
    m="$(md5sum "${file}" | awk '{print $1}')"
    [ "${m}" = "${md5}" ] || die "MD5 incorreto para ${file}"
  fi
}

fetch_sources_for_pkg() {
  local pkg="$1"
  load_package_script "${pkg}"

  mkdir -p "${ADM_SRC_CACHE}"

  local -a urls=("${PKG_SOURCES[@]:-}")
  local -a shas=("${PKG_SHA256S[@]:-}")
  local -a md5s=("${PKG_MD5S[@]:-}")

  local i
  for (( i=0; i<${#urls[@]}; i++ )); do
    local url="${urls[i]}"
    local sha="${shas[i]:-}"
    local md5="${md5s[i]:-}"
    local fname="${url##*/}"
    [ -n "${fname}" ] || fname="${PKG_NAME}-${PKG_VERSION}-${i}.src"
    local dest="${ADM_SRC_CACHE}/${fname}"

    if [ -f "${dest}" ]; then
      log_info "Usando cache para ${url}"
      verify_checksum "${dest}" "${sha}" "${md5}"
    else
      log_info "Baixando ${url}"
      download_one_url "${url}" "${dest}"
      verify_checksum "${dest}" "${sha}" "${md5}"
    fi
  done
}

###############################################################################
# PATCHES AUTOMÁTICOS
###############################################################################

apply_patches_for_pkg() {
  local pkg="$1" srcdir="$2"
  load_package_script "${pkg}"
  local pattern="${PKG_NAME}-${PKG_VERSION}"*.patch
  shopt -s nullglob
  local p
  for p in "${ADM_SRC_CACHE}"/${pattern}; do
    [ -f "${p}" ] || continue
    log_info "Aplicando patch ${p}"
    run_cmd "patch -p1 -d '${srcdir}' < '${p}'"
  done
  shopt -u nullglob
}

###############################################################################
# DEPENDÊNCIAS (KAHN)
###############################################################################

declare -A ADM_DEPS ADM_INDEGREE ADM_VISITED

collect_deps_recursive() {
  local pkg="$1"
  if [[ -n "${ADM_VISITED[${pkg}]:-}" ]]; then
    return 0
  fi
  ADM_VISITED["${pkg}"]=1

  load_package_script "${pkg}"
  local -a deps=("${PKG_DEPENDS[@]:-}")
  ADM_DEPS["${pkg}"]="${deps[*]:-}"

  local d
  for d in "${deps[@]:-}"; do
    collect_deps_recursive "${d}"
  done
}

toposort_kahn() {
  local -a roots=("$@")
  ADM_DEPS=()
  ADM_INDEGREE=()
  ADM_VISITED=()

  local r
  for r in "${roots[@]}"; do
    collect_deps_recursive "${r}"
  done

  local n
  for n in "${!ADM_DEPS[@]}"; do
    ADM_INDEGREE["${n}"]=0
  done

  local deps d
  for n in "${!ADM_DEPS[@]}"; do
    deps="${ADM_DEPS[${n}]}"
    for d in ${deps}; do
      ADM_INDEGREE["${d}"]=$(( ${ADM_INDEGREE[${d}]:-0} + 1 ))
    done
  done

  local -a queue=()
  for n in "${!ADM_INDEGREE[@]}"; do
    if [ "${ADM_INDEGREE[${n}]}" -eq 0 ]; then
      queue+=("${n}")
    fi
  done

  local -a order=()
  while ((${#queue[@]} > 0)); do
    local x="${queue[0]}"
    queue=("${queue[@]:1}")
    order+=("${x}")
    local deps_x="${ADM_DEPS[${x}]}"
    for d in ${deps_x}; do
      ADM_INDEGREE["${d}"]=$(( ${ADM_INDEGREE[${d}]:-0} - 1 ))
      if [ "${ADM_INDEGREE[${d}]}" -eq 0 ]; then
        queue+=("${d}")
      fi
    done
  done

  local total=0
  for n in "${!ADM_INDEGREE[@]}"; do
    ((total++))
  done
  if [ "${#order[@]}" -ne "${total}" ]; then
    log_err "Ciclo de dependências detectado!"
    die "Falha na ordenação topológica"
  fi

  printf '%s\n' "${order[@]}"
}

###############################################################################
# CACHE BINÁRIO / METADADOS
###############################################################################

is_pkg_installed() {
  local pkg="$1" profile="$2"
  local meta
  meta="$(pkg_meta_path "${pkg}" "${profile}")"
  [ -f "${meta}" ]
}

install_binary_if_cached() {
  local pkg="$1" profile="$2" rootfs="$3"
  load_package_script "${pkg}"
  local zst xz
  zst="$(pkg_bin_zst_path "${pkg}" "${PKG_VERSION}" "${profile}")"
  xz="$(pkg_bin_xz_path "${pkg}" "${PKG_VERSION}" "${profile}")"

  if [ -f "${zst}" ]; then
    log_info "Instalando ${pkg} de cache binário (.zst)"
    run_cmd "zstd -d -q -c '${zst}' | tar -C '${rootfs}' -xf -"
    return 0
  fi
  if [ -f "${xz}" ]; then
    log_info "Instalando ${pkg} de cache binário (.xz)"
    run_cmd "tar -C '${rootfs}' -xJf '${xz}'"
    return 0
  fi
  return 1
}

binary_cache_exists_for() {
  local pkg="$1" profile="$2"
  load_package_script "${pkg}"
  local zst xz
  zst="$(pkg_bin_zst_path "${pkg}" "${PKG_VERSION}" "${profile}")"
  xz="$(pkg_bin_xz_path "${pkg}" "${PKG_VERSION}" "${profile}")"
  if [ -f "${zst}" ] || [ -f "${xz}" ]; then
    return 0
  fi
  return 1
}

snapshot_rootfs() {
  local rootfs="$1" out="$2"
  find "${rootfs}" -xdev -print | sort > "${out}"
}

compute_manifest_from_snapshots() {
  local before="$1" after="$2" out="$3"
  comm -13 "${before}" "${after}" > "${out}"
}

pkg_register_meta_and_manifest() {
  local pkg="$1" profile="$2" rootfs="$3" before="$4" after="$5"
  load_package_script "${pkg}"

  local meta manifest
  meta="$(pkg_meta_path "${pkg}" "${profile}")"
  manifest="$(pkg_manifest_path "${pkg}" "${profile}")"

  mkdir -p "$(dirname "${meta}")"

  compute_manifest_from_snapshots "${before}" "${after}" "${manifest}"

  {
    echo "PKG=${pkg}"
    echo "NAME=${PKG_NAME}"
    echo "VERSION=${PKG_VERSION}"
    echo "PROFILE=${profile}"
    echo "ROOTFS=${rootfs}"
    echo "INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo -n "DEPENDS="
    printf '%s ' "${PKG_DEPENDS[@]:-}"
    echo
  } > "${meta}"
}

package_rootfs_diff() {
  local pkg="$1" profile="$2"
  load_package_script "${pkg}"
  local rootfs
  rootfs="$(rootfs_for_profile)"
  local zst xz manifest tmp_list
  zst="$(pkg_bin_zst_path "${pkg}" "${PKG_VERSION}" "${profile}")"
  xz="$(pkg_bin_xz_path "${pkg}" "${PKG_VERSION}" "${profile}")"
  manifest="$(pkg_manifest_path "${pkg}" "${profile}")"

  if [ ! -s "${manifest}" ]; then
    log_warn "Manifesto vazio para ${pkg}; pacote binário não será gerado."
    return 0
  fi

  mkdir -p "$(dirname "${zst}")" "$(dirname "${xz}")"

  tmp_list="$(mktemp)"
  awk -v root="${rootfs}" '
    {
      gsub("^" root "/?", "", $0);
      if (length($0) > 0) print $0;
    }
  ' "${manifest}" > "${tmp_list}"

  if [ ! -s "${tmp_list}" ]; then
    log_warn "Lista de arquivos vazia para empacotar ${pkg}."
    rm -f "${tmp_list}"
    return 0
  fi

  if have_prog zstd; then
    log_info "Gerando pacote binário .tar.zst para ${pkg}"
    run_cmd "tar -C '${rootfs}' -cf - -T '${tmp_list}' | zstd -q -o '${zst}'"
  else
    log_info "Gerando pacote binário .tar.xz para ${pkg}"
    run_cmd "tar -C '${rootfs}' -cJf '${xz}' -T '${tmp_list}'"
  fi

  rm -f "${tmp_list}"
}

###############################################################################
# BUILD / INSTALAÇÃO
###############################################################################

build_one_pkg() {
  local pkg="$1" profile="$2"

  local rootfs
  rootfs="$(rootfs_for_profile)"

  local state
  state="$(pkg_state_path "${pkg}" "${profile}")"
  mkdir -p "$(dirname "${state}")"
  touch "${state}"

  local fetched=0 unpacked=0 patched=0 built=0 installed=0 packaged=0
  # shellcheck disable=SC1090
  . "${state}" 2>/dev/null || true

  load_package_script "${pkg}"

  local log_file
  log_file="$(log_file_for build "${pkg}")"

  log_info "=== Build ${pkg} (${PKG_NAME}-${PKG_VERSION}) perfil ${profile}"

  if (( ADM_DRY_RUN )); then
    log_info " [DRY] construiria ${pkg} em $(rootfs_for_profile) para perfil ${profile}"
    return 0
  fi

  local builddir
  builddir="$(mktemp -d -p /tmp adm-build-${PKG_NAME}-${PKG_VERSION}-XXXXXX)"

  if [ "${fetched}" -eq 0 ]; then
    fetch_sources_for_pkg "${pkg}" >> "${log_file}" 2>&1
    echo "fetched=1" >> "${state}"
  fi

  local main_src=""
  if [ "${#PKG_SOURCES[@]:-}" -gt 0 ]; then
    main_src="${PKG_SOURCES[0]##*/}"
    main_src="${ADM_SRC_CACHE}/${main_src}"
  fi

  local srcdir="${builddir}"

  if [ "${unpacked}" -eq 0 ]; then
    if [ -n "${main_src}" ] && [ -f "${main_src}" ]; then
      log_info "Extraindo ${main_src}"
      (cd "${builddir}" && run_cmd "tar xf '${main_src}'") >> "${log_file}" 2>&1
    fi
    echo "unpacked=1" >> "${state}"
  fi

  local subcount
  subcount="$(find "${builddir}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  if [ "${subcount}" -eq 1 ]; then
    srcdir="$(find "${builddir}" -mindepth 1 -maxdepth 1 -type d)"
  fi

  if [ "${patched}" -eq 0 ]; then
    apply_patches_for_pkg "${pkg}" "${srcdir}" >> "${log_file}" 2>&1 || die "Falha em patch"
    echo "patched=1" >> "${state}"
  fi

  local triplet
  case "${ADM_PROFILE}" in
    glibc) triplet="x86_64-lfs-linux-gnu" ;;
    musl)  triplet="x86_64-lfs-linux-musl" ;;
    *)     triplet="unknown-triplet" ;;
  esac
  if [ -n "${PKG_TRIPLET:-}" ]; then
    triplet="${PKG_TRIPLET}"
  fi

  export ADM_PROFILE ADM_ROOTFS ADM_TRIPLET
  export ADM_DESTDIR="${rootfs}"
  export PATH="${rootfs}/usr/bin:${rootfs}/bin:${PATH}"

  if [ "${built}" -eq 0 ]; then
    if declare -f pkg_prepare >/dev/null 2>&1; then
      (cd "${srcdir}" && run_cmd "pkg_prepare") >> "${log_file}" 2>&1
    fi
    if declare -f pkg_build >/dev/null 2>&1; then
      (cd "${srcdir}" && run_cmd "pkg_build") >> "${log_file}" 2>&1
    fi
    echo "built=1" >> "${state}"
  fi

  local snap_before snap_after
  snap_before="$(mktemp)"
  snap_after="$(mktemp)"

  if [ "${installed}" -eq 0 ]; then
    snapshot_rootfs "${rootfs}" "${snap_before}"
    if declare -f pkg_install >/dev/null 2>&1; then
      (cd "${srcdir}" && run_cmd "pkg_install") >> "${log_file}" 2>&1
    else
      die "pkg_install não definido em ${pkg}"
    fi
    if declare -f pkg_post_install >/dev/null 2>&1; then
      (cd "${srcdir}" && run_cmd "pkg_post_install") >> "${log_file}" 2>&1
    fi
    snapshot_rootfs "${rootfs}" "${snap_after}"
    pkg_register_meta_and_manifest "${pkg}" "${profile}" "${rootfs}" "${snap_before}" "${snap_after}"
    echo "installed=1" >> "${state}"
  fi

  if [ "${packaged}" -eq 0 ]; then
    package_rootfs_diff "${pkg}" "${profile}"
    echo "packaged=1" >> "${state}"
  fi

  rm -rf "${builddir}" "${snap_before}" "${snap_after}"

  log_ok "Build concluído: ${pkg}"
}

build_with_deps() {
  local profile="$1"; shift
  local -a targets=("$@")
  local rootfs
  rootfs="$(rootfs_for_profile)"

  log_info "Resolvendo dependências para: ${targets[*]}"
  local order
  order="$(toposort_kahn "${targets[@]}")"
  log_info "Ordem de build:"
  printf '  %s\n' ${order}

  local pkg
  if (( ADM_DRY_RUN )); then
    for pkg in ${order}; do
      if is_pkg_installed "${pkg}" "${profile}"; then
        log_info " [DRY] ${pkg} já instalado em ${profile} (nada a fazer)."
      elif binary_cache_exists_for "${pkg}" "${profile}"; then
        log_info " [DRY] instalaria ${pkg} a partir de cache binário."
      else
        log_info " [DRY] construiria ${pkg} a partir do código-fonte."
      fi
    done
    return 0
  fi

  for pkg in ${order}; do
    if is_pkg_installed "${pkg}" "${profile}"; then
      log_info "Pacote já instalado para perfil ${profile}: ${pkg}"
      continue
    fi
    if install_binary_if_cached "${pkg}" "${profile}" "${rootfs}"; then
      log_ok "Instalado via cache binário: ${pkg}"
    else
      build_one_pkg "${pkg}" "${profile}"
    fi
  done
}

###############################################################################
# UNINSTALL / HOOKS POR PACOTE / ÓRFÃOS
###############################################################################

run_pkg_uninstall_hooks() {
  local pkg="$1" which="$2"
  load_package_script "${pkg}"
  case "${which}" in
    pre)
      if declare -f pkg_pre_uninstall >/dev/null 2>&1; then
        log_info "Hook pkg_pre_uninstall para ${pkg}"
        run_cmd "pkg_pre_uninstall"
      fi
      ;;
    post)
      if declare -f pkg_post_uninstall >/dev/null 2>&1; then
        log_info "Hook pkg_post_uninstall para ${pkg}"
        run_cmd "pkg_post_uninstall"
      fi
      ;;
  esac
}

uninstall_one_pkg() {
  local pkg="$1" profile="$2"
  local meta manifest
  meta="$(pkg_meta_path "${pkg}" "${profile}")"
  manifest="$(pkg_manifest_path "${pkg}" "${profile}")"

  if [ ! -f "${meta}" ]; then
    log_warn "Pacote não instalado: ${pkg} (${profile})"
    return 0
  fi

  local rootfs
  rootfs="$(rootfs_for_profile)"

  run_pkg_uninstall_hooks "${pkg}" pre

  if [ -f "${manifest}" ]; then
    log_info "Removendo arquivos listados em ${manifest}"
    while IFS= read -r f; do
      [ -n "${f}" ] || continue
      if [ ! -e "${f}" ]; then
        continue
      fi
      if (( ADM_DRY_RUN )); then
        printf "%b[DRY-DEL]%b %s\n" "${C_HI}" "${C_RESET}" "${f}"
      else
        rm -f "${f}" 2>/dev/null || true
        rmdir --ignore-fail-on-non-empty "$(dirname "${f}")" 2>/dev/null || true
      fi
    done < "${manifest}"
  else
    log_warn "Manifesto não encontrado para ${pkg}; nenhum arquivo removido."
  fi

  if (( ! ADM_DRY_RUN )); then
    rm -f "${meta}" "${manifest}"
  fi

  run_pkg_uninstall_hooks "${pkg}" post
  log_ok "Pacote removido: ${pkg}"
}

list_installed() {
  local profile="$1"
  local base="${ADM_DB_PKG_DIR}/${profile}"
  [ -d "${base}" ] || return 0
  local f
  while IFS= read -r -d '' f; do
    local rel="${f#${base}/}"
    rel="${rel%.meta}"
    local ver
    ver="$(grep '^VERSION=' "${f}" | head -n1 | cut -d= -f2-)"
    printf "%-40s %s\n" "${rel}" "${ver}"
  done < <(find "${base}" -type f -name '*.meta' -print0 | sort -z)
}

find_orphans() {
  local profile="$1"
  local base="${ADM_DB_PKG_DIR}/${profile}"
  [ -d "${base}" ] || return 0

  declare -A depended
  local f deps d

  while IFS= read -r -d '' f; do
    deps="$(grep '^DEPENDS=' "${f}" | head -n1 | cut -d= -f2- || true)"
    for d in ${deps}; do
      depended["${d}"]=1
    done
  done < <(find "${base}" -type f -name '*.meta' -print0)

  while IFS= read -r -d '' f; do
    local rel="${f#${base}/}"
    rel="${rel%.meta}"
    if [[ -z "${depended[${rel}]:-}" ]]; then
      echo "${rel}"
    fi
  done < <(find "${base}" -type f -name '*.meta' -print0 | sort -z)
}

toposort_subset_for_uninstall() {
  local profile="$1"; shift
  local -a targets=("$@")

  declare -A U_DEPS U_INDEG U_IN_TARGET

  local t
  for t in "${targets[@]}"; do
    U_IN_TARGET["${t}"]=1
  done

  local pkg deps d meta list
  for pkg in "${targets[@]}"; do
    meta="$(pkg_meta_path "${pkg}" "${profile}")"
    [ -f "${meta}" ] || continue
    deps="$(grep '^DEPENDS=' "${meta}" | head -n1 | cut -d= -f2- || true)"
    list=""
    for d in ${deps}; do
      if [[ -n "${U_IN_TARGET[${d}]:-}" ]]; then
        list="${list} ${d}"
      fi
    done
    U_DEPS["${pkg}"]="${list}"
  done

  for pkg in "${!U_DEPS[@]}"; do
    U_INDEG["${pkg}"]=0
  done

  for pkg in "${!U_DEPS[@]}"; do
    for d in ${U_DEPS[${pkg}]}; do
      U_INDEG["${d}"]=$(( ${U_INDEG[${d}]:-0} + 1 ))
    done
  done

  local -a queue=()
  for pkg in "${!U_INDEG[@]}"; do
    if [ "${U_INDEG[${pkg}]}" -eq 0 ]; then
      queue+=("${pkg}")
    fi
  done

  local -a order=()
  while ((${#queue[@]} > 0)); do
    local x="${queue[0]}"
    queue=("${queue[@]:1}")
    order+=("${x}")
    for d in ${U_DEPS[${x}]}; do
      U_INDEG["${d}"]=$(( ${U_INDEG[${d}]:-0} - 1 ))
      if [ "${U_INDEG[${d}]}" -eq 0 ]; then
        queue+=("${d}")
      fi
    done
  done

  local total=0
  for pkg in "${!U_INDEG[@]}"; do
    ((total++))
  done
  if [ "${#order[@]}" -ne "${total}" ]; then
    die "Ciclo de dependências ao calcular ordem de remoção."
  fi

  printf '%s\n' "${order[@]}"
}

remove_with_order() {
  local profile="$1"; shift
  local -a targets=("$@")
  local order
  order="$(toposort_subset_for_uninstall "${profile}" "${targets[@]}")"
  log_info "Ordem de remoção (reversa):"
  local -a arr=()
  local x
  for x in ${order}; do
    arr+=("${x}")
  done
  local i
  for (( i=${#arr[@]}-1; i>=0; i-- )); do
    uninstall_one_pkg "${arr[i]}" "${profile}"
  done
}

###############################################################################
# INFO / SEARCH / FETCH
###############################################################################

search_pkgs() {
  local pattern="$1"
  local base="${ADM_PKG_DIR}"
  local f
  while IFS= read -r -d '' f; do
    local rel="${f#${base}/}"
    rel="${rel%.sh}"
    if [[ "${rel}" == *"${pattern}"* ]]; then
      echo "${rel}"
    fi
  done < <(find "${base}" -type f -name '*.sh' -print0 | sort -z)
}

pkg_info() {
  local pkg="$1" profile="$2"
  load_package_script "${pkg}"
  local meta
  meta="$(pkg_meta_path "${pkg}" "${profile}")"

  echo "Pacote:   ${pkg}"
  echo "Nome:     ${PKG_NAME}"
  echo "Versão:   ${PKG_VERSION}"
  echo "Perfil:   ${profile}"
  echo "Rootfs:   $(rootfs_for_profile)"
  echo "Sources:"
  local s
  for s in "${PKG_SOURCES[@]:-}"; do
    echo "  - ${s}"
  done
  echo "Dependências:"
  local d
  for d in "${PKG_DEPENDS[@]:-}"; do
    echo "  - ${d}"
  done
  if [ -f "${meta}" ]; then
    echo
    echo "Meta instalado:"
    cat "${meta}"
  else
    echo
    echo "Não instalado para este perfil."
  fi
}

fetch_only() {
  local profile="$1"; shift
  local -a pkgs=("$@")
  log_info "Fetch de fontes (com deps) para: ${pkgs[*]}"
  local order
  order="$(toposort_kahn "${pkgs[@]}")"
  local p
  if (( ADM_DRY_RUN )); then
    for p in ${order}; do
      load_package_script "${p}"
      log_info " [DRY] baixaria fontes para ${p}:"
      local s
      for s in "${PKG_SOURCES[@]:-}"; do
        echo "   - ${s}"
      done
    done
    return 0
  fi
  for p in ${order}; do
    fetch_sources_for_pkg "${p}"
  done
}

###############################################################################
# SYNC COM REPO GIT
###############################################################################

sync_repo() {
  if [ -z "${ADM_REPO_URL}" ]; then
    die "ADM_REPO_URL não definido. Configure para usar sync."
  fi

  mkdir -p "${ADM_PKG_DIR}"
  if [ -d "${ADM_PKG_DIR}/.git" ]; then
    log_info "Atualizando repositório de scripts em ${ADM_PKG_DIR}"
    (cd "${ADM_PKG_DIR}" && run_cmd "git fetch --all --prune")
    (cd "${ADM_PKG_DIR}" && run_cmd "git checkout '${ADM_REPO_BRANCH}'")
    (cd "${ADM_PKG_DIR}" && run_cmd "git pull --ff-only origin '${ADM_REPO_BRANCH}'")
  else
    log_info "Clonando repositório de scripts em ${ADM_PKG_DIR}"
    run_cmd "git clone --branch '${ADM_REPO_BRANCH}' '${ADM_REPO_URL}' '${ADM_PKG_DIR}'"
  fi
  log_ok "Sync com repositório git concluído."
}

###############################################################################
# CLI
###############################################################################

usage() {
  cat <<EOF
Uso: $0 [opções globais] <comando> [args]

Opções globais:
  --profile {glibc|musl}   Perfil alvo (default glibc)
  --rootfs DIR             Rootfs custom (default /opt/adm/rootfs/<perfil>)
  --dry-run                Só mostra o que faria, não executa
  -v, --verbose            Mostra comandos internos
  -h, --help               Esta ajuda

Comandos:
  sync                     Sincroniza scripts de construção via git (ADM_REPO_URL)
  build PKG [...]          Resolve deps, compila e instala PKG(s) para o perfil
  fetch PKG [...]          Baixa sources (com deps) sem compilar
  deps PKG [...]           Mostra ordem de dependências (Kahn)
  list                     Lista pacotes instalados no perfil
  info PKG                 Mostra info detalhada do pacote
  search PADRAO            Procura scripts de construção
  orphans                  Lista pacotes órfãos
  remove-orphans           Remove órfãos em ordem segura
  remove PKG [...]         Remove pacotes, ordem reversa segura
EOF
}

parse_global_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        shift; [ $# -gt 0 ] || die "--profile requer argumento"
        set_profile "$1"; shift ;;
      --rootfs)
        shift; [ $# -gt 0 ] || die "--rootfs requer argumento"
        ADM_ROOTFS="$1"; shift ;;
      --dry-run)
        ADM_DRY_RUN=1; shift ;;
      -v|--verbose)
        ADM_VERBOSE=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      --)
        shift; break ;;
      -*)
        die "Opção desconhecida: $1" ;;
      *)
        break ;;
    esac
  done
  CMD="${1:-}"
  shift || true
  CMD_ARGS=("$@")
}

main() {
  parse_global_args "$@"
  [ -n "${CMD:-}" ] || { usage; exit 1; }

  case "${CMD}" in
    sync)
      sync_repo
      ;;
    build)
      [ "${#CMD_ARGS[@]}" -gt 0 ] || die "build requer PKG(s)."
      build_with_deps "${ADM_PROFILE}" "${CMD_ARGS[@]}"
      ;;
    fetch)
      [ "${#CMD_ARGS[@]}" -gt 0 ] || die "fetch requer PKG(s)."
      fetch_only "${ADM_PROFILE}" "${CMD_ARGS[@]}"
      ;;
    deps)
      [ "${#CMD_ARGS[@]}" -gt 0 ] || die "deps requer PKG(s)."
      toposort_kahn "${CMD_ARGS[@]}"
      ;;
    list)
      list_installed "${ADM_PROFILE}"
      ;;
    info)
      [ "${#CMD_ARGS[@]}" -eq 1 ] || die "info requer 1 PKG."
      pkg_info "${CMD_ARGS[0]}" "${ADM_PROFILE}"
      ;;
    search)
      [ "${#CMD_ARGS[@]}" -eq 1 ] || die "search requer PADRAO."
      search_pkgs "${CMD_ARGS[0]}"
      ;;
    orphans)
      find_orphans "${ADM_PROFILE}"
      ;;
    remove-orphans)
      mapfile -t ORF < <(find_orphans "${ADM_PROFILE}" || true)
      if [ "${#ORF[@]}" -eq 0 ]; then
        log_info "Nenhum órfão."
      else
        log_warn "Removendo órfãos: ${ORF[*]}"
        remove_with_order "${ADM_PROFILE}" "${ORF[@]}"
      fi
      ;;
    remove)
      [ "${#CMD_ARGS[@]}" -gt 0 ] || die "remove requer PKG(s)."
      remove_with_order "${ADM_PROFILE}" "${CMD_ARGS[@]}"
      ;;
    *)
      die "Comando desconhecido: ${CMD}"
      ;;
  esac
}

main "$@"
