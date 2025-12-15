#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

STATE_DIR="${STATE_DIR:-/var/lib/adm}"
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
PKG_SCRIPTS_DIR="${PKG_SCRIPTS_DIR:-$ADM_ROOT/packages}"

INST_DB="$STATE_DIR/installed"
REV_DB="$STATE_DIR/revdeps"

have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "ERRO: $*" >&2; exit 1; }

sanitize() { echo "$1" | tr -cd 'A-Za-z0-9._+-'; }
pkg_id() { echo "$(sanitize "$1")-$(sanitize "$2")"; }

find_any_category_script() {
  local name="$1" ver="$2"
  find "$PKG_SCRIPTS_DIR" -type f -name "${name}-${ver}.sh" 2>/dev/null | head -n1
}
category_from_script() { basename "$(dirname "$1")"; }

# sandbox metadata (só deps)
meta_deps_from_script() {
  local script="$1"
  bash -n "$script" >/dev/null 2>&1 || return 1
  bash -c "
    set -Eeuo pipefail
    source '$script'
    declare -p PKG_DEPENDS 2>/dev/null || echo 'declare -a PKG_DEPENDS=()'
  "
}

parse_dep() {
  local s="$1" name op ver
  if [[ "$s" == *">="* ]]; then name="${s%%>=*}"; op=">="; ver="${s#*>=}"
  elif [[ "$s" == *"<="* ]]; then name="${s%%<=*}"; op="<="; ver="${s#*<=}"
  elif [[ "$s" == *"="* ]]; then name="${s%%=*}"; op="="; ver="${s#*=}"
  elif [[ "$s" == *"@"* ]]; then name="${s%%@*}"; op="="; ver="${s#*@}"
  else
    if [[ "$s" == *"-"* ]]; then
      local suf="${s##*-}"
      if [[ "$suf" =~ ^[0-9] ]]; then name="${s%-*}"; op="="; ver="$suf"
      else name="$s"; op=""; ver=""
      fi
    else name="$s"; op=""; ver=""
    fi
  fi
  name="$(sanitize "$name")"; ver="$(sanitize "$ver")"
  echo "$name|$op|$ver"
}

revdeps_add() {
  local dep_id="$1" dependent_id="$2"
  mkdir -p "$REV_DB"
  local f="$REV_DB/$dep_id.rdeps"
  touch "$f"
  grep -qxF "$dependent_id" "$f" 2>/dev/null || echo "$dependent_id" >>"$f"
}

echo "==> Migração: preparando banco do adm em $STATE_DIR"
[[ -d "$INST_DB" ]] || die "INST_DB não existe: $INST_DB"
[[ -d "$PKG_SCRIPTS_DIR" ]] || die "PKG_SCRIPTS_DIR não existe: $PKG_SCRIPTS_DIR"

# 1) Completar deps= e category= em manifestos quando possível
for d in "$INST_DB"/*; do
  [[ -d "$d" ]] || continue
  id="$(basename "$d")"
  mf="$d/manifest.info"

  if [[ ! -f "$mf" ]]; then
    echo "WARN: sem manifest.info: $id (não migra deps)"
    continue
  fi

  name="${id%-*}"
  ver="${id##*-}"

  # Se já tem deps=, pula
  if grep -qE '^deps=' "$mf"; then
    continue
  fi

  script="$(find_any_category_script "$name" "$ver" || true)"
  if [[ -z "$script" ]]; then
    echo "WARN: sem script para extrair deps: $id"
    continue
  fi
  cat="$(category_from_script "$script")"

  # Extrai deps do script em sandbox
  dump="$(meta_deps_from_script "$script" || true)"
  if [[ -z "$dump" ]]; then
    echo "WARN: não conseguiu extrair deps: $id"
    continue
  fi

  # Avalia declare -p para ter PKG_DEPENDS
  PKG_DEPENDS=()
  eval "$dump"

  dep_ids=()
  for dep in "${PKG_DEPENDS[@]:-}"; do
    IFS='|' read -r dn _ dv <<<"$(parse_dep "$dep")"
    [[ -n "$dn" && -n "$dv" ]] || continue
    dep_ids+=("$(pkg_id "$dn" "$dv")")
  done

  # Garante category/script e adiciona deps=
  {
    # preserva conteúdo existente removendo qualquer category/script antigo duplicado
    grep -vE '^(category=|script=|deps=)$' "$mf" || true
    echo "category=$cat"
    echo "script=$script"
    echo "deps=${dep_ids[*]:-}"
  } >"$mf.new"
  mv "$mf.new" "$mf"

  echo "OK: manifest atualizado: $id (deps=${#dep_ids[@]})"
done

# 2) Rebuild total de reverse-deps a partir de deps=
echo "==> Rebuild REV_DB"
rm -f "$REV_DB"/*.rdeps 2>/dev/null || true
mkdir -p "$REV_DB"

for d in "$INST_DB"/*; do
  [[ -d "$d" ]] || continue
  id="$(basename "$d")"
  mf="$d/manifest.info"
  [[ -f "$mf" ]] || continue
  deps="$(grep -E '^deps=' "$mf" | cut -d= -f2- || true)"
  for dep in $deps; do
    [[ -n "$dep" ]] || continue
    revdeps_add "$dep" "$id"
  done
done

echo "==> Migração concluída."
echo "Sugestão: rode agora: adm doctor --fix"
