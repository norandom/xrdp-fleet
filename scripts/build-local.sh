#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Build the .debs locally with Docker, for one or all configured codenames.
#   ./scripts/build-local.sh           # all codenames in config.env
#   ./scripts/build-local.sh noble     # just one
# Artifacts land in ./out/<codename>/.
# ---------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source config.env

TARGETS="${*:-$CODENAMES}"

image_for() {
  case "$1" in
    noble) echo "ubuntu:24.04" ;;
    jammy) echo "ubuntu:22.04" ;;
    *) echo "" ;;
  esac
}

for cn in $TARGETS; do
  img="$(image_for "$cn")"
  [ -n "$img" ] || { echo "No image mapping for codename '$cn' (add one in build-local.sh)"; exit 1; }
  echo "############ Building for $cn ($img) ############"
  mkdir -p "out/$cn"
  docker run --rm \
    -v "$PWD":/work:ro \
    -v "$PWD/out/$cn":/out \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    "$img" bash /work/scripts/build-deb.sh "$cn"
done

echo "All builds complete. Artifacts:"
find out -name '*.deb' -printf '  %p\n' 2>/dev/null || true
