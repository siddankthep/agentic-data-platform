#!/usr/bin/env bash
# Install or remove a bundled example, by copying its artifacts into the working
# scaffold directories (and removing exactly those copies again).
#
#   scripts/example.sh install stripe
#   scripts/example.sh clean   stripe
#
# The scaffold ships empty; an example under examples/<name>/ is the removable
# reference. Its files are copied in — never symlinked — so the working tree is
# exactly what dbt / Cube / Terraform load. After install or clean, run
# `make dagster-refresh` so Dagster re-reads the dbt project and Airbyte catalog.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-}"
name="${2:-}"

[ -n "$action" ] && [ -n "$name" ] || { echo "usage: $0 {install|clean} <example>" >&2; exit 2; }
SRC="$ROOT/examples/$name"
[ -d "$SRC" ] || { echo "no such example: examples/$name" >&2; exit 2; }

# Each entry: <path under examples/$name>  ->  <destination under repo root>.
# Directory sources copy their *contents* into the destination directory.
map_pairs() {
  cat <<EOF
transformation/models/staging/$name	$ROOT/transformation/models/staging/$name
transformation/models/intermediate/$name	$ROOT/transformation/models/intermediate/$name
transformation/models/marts/$name	$ROOT/transformation/models/marts/$name
cube/cubes	$ROOT/cube_semantics/model/cubes
cube/views	$ROOT/cube_semantics/model/views
terraform	$ROOT/ingestion/terraform
seed_${name}.py	$ROOT/ingestion/seed_${name}.py
EOF
}

install_one() {
  local rel="$1" dst="$2" src="$SRC/$1"
  [ -e "$src" ] || return 0
  if [ -d "$src" ]; then
    mkdir -p "$dst"
    cp -R "$src"/. "$dst"/
    echo "  + $rel/ -> ${dst#$ROOT/}/"
  else
    cp "$src" "$dst"
    echo "  + $rel -> ${dst#$ROOT/}"
  fi
}

clean_one() {
  local rel="$1" dst="$2" src="$SRC/$1"
  [ -e "$src" ] || return 0
  if [ -d "$src" ]; then
    # Remove only the files this example installed, then prune empty dirs.
    ( cd "$src" && find . -type f -print0 ) | while IFS= read -r -d '' f; do
      rm -f "$dst/${f#./}"
    done
    find "$dst" -type d -empty -delete 2>/dev/null || true
    echo "  - ${dst#$ROOT/}/ (example files removed)"
  else
    rm -f "$dst"
    echo "  - ${dst#$ROOT/}"
  fi
}

case "$action" in
  install)
    echo "Installing example '$name':"
    while IFS=$'\t' read -r rel dst; do install_one "$rel" "$dst"; done < <(map_pairs)
    echo "Done. Run 'make dagster-refresh' to re-read the project."
    ;;
  clean)
    echo "Removing example '$name':"
    while IFS=$'\t' read -r rel dst; do clean_one "$rel" "$dst"; done < <(map_pairs)
    echo "Done. Run 'make dagster-refresh' to re-read the project."
    ;;
  *)
    echo "usage: $0 {install|clean} <example>" >&2; exit 2 ;;
esac
