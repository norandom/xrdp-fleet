#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Build xrdp + xorgxrdp .debs for ONE Ubuntu codename, INSIDE a matching
# container, so dpkg-shlibdeps generates dependencies that match exactly
# that distro (no cross-distro dependency explosion).
#
# Invoked (by build-local.sh or CI) as root inside ubuntu:24.04 / 22.04:
#   docker run --rm -v "$PWD":/work:ro -v "$PWD/out/<cn>":/out \
#       ubuntu:24.04 bash /work/scripts/build-deb.sh <codename>
#
# Reads pinned versions from /work/config.env. Writes .debs to /out.
# ---------------------------------------------------------------------
set -euxo pipefail

CODENAME="${1:?usage: build-deb.sh <noble|jammy>}"
WORK="${WORK:-/work}"
OUT="${OUT:-/out}"
# shellcheck disable=SC1091
source "$WORK/config.env"

case "$CODENAME" in
  noble) RELTAG="ubuntu24.04" ;;
  jammy) RELTAG="ubuntu22.04" ;;
  *) echo "Unknown codename: $CODENAME (expected noble|jammy)"; exit 2 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential devscripts equivs dpkg-dev ca-certificates wget xz-utils

mkdir -p "$OUT"
BUILD="$(mktemp -d)"
cd "$BUILD"

# fetch <pkgname> <filename> — try each configured mirror in turn
fetch() {
  local pkg="$1" file="$2" b
  for b in "$DEBIAN_POOL" "$SNAPSHOT_POOL"; do
    [ -n "$b" ] || continue
    if wget -q "$b/$pkg/$file"; then return 0; fi
  done
  echo "ERROR: could not fetch $file from any mirror." >&2
  echo "  sid has likely moved past the pinned version. Update config.env to the" >&2
  echo "  current version (https://packages.debian.org/sid/$pkg) or set SNAPSHOT_POOL." >&2
  return 1
}

# build_one <pkg> <upstream> <debrev> <full-version>
build_one() {
  local pkg="$1" up="$2" rev="$3" ver="$4"
  echo "=== Building $pkg $ver for $CODENAME ==="
  fetch "$pkg" "${pkg}_${up}-${rev}.dsc"
  fetch "$pkg" "${pkg}_${up}.orig.tar.gz"
  fetch "$pkg" "${pkg}_${up}-${rev}.debian.tar.xz"
  dpkg-source -x "${pkg}_${up}-${rev}.dsc" "src-${pkg}"
  pushd "src-${pkg}" >/dev/null

  # jammy fix: systemd-dev was split out of systemd at v253; jammy ships 249,
  # so the build-dep is unsatisfiable. libsystemd-dev provides the headers/.pc.
  if [ "$CODENAME" = "jammy" ]; then
    sed -i -E 's/([[:space:],])systemd-dev\b/\1libsystemd-dev/g' debian/control
  fi

  # Stamp a fleet version that outranks the distro package and is unique per
  # codename (~ sorts below the bare archive version; the apt pin forces the win).
  dch -b -v "$ver" --distribution "$CODENAME" "Fleet rebuild of $pkg $up for $CODENAME"

  # Pull build-deps from the TARGET distro; surfaces any gap explicitly.
  mk-build-deps -i -r -t 'apt-get -y --no-install-recommends' debian/control

  dpkg-buildpackage -us -uc -b
  popd >/dev/null

  cp ./*.deb "$OUT"/
  rm -rf "src-${pkg}" ./*.deb ./*.dsc ./*.tar.* ./*.changes ./*.buildinfo 2>/dev/null || true
}

build_one xrdp     "$XRDP_UPSTREAM"     "$XRDP_DEBREV" \
          "${XRDP_UPSTREAM}-${XRDP_DEBREV}~fleet${FLEET_REV}~${RELTAG}"

build_one xorgxrdp "$XORGXRDP_UPSTREAM" "$XORGXRDP_DEBREV" \
          "${XORGXRDP_EPOCH}:${XORGXRDP_UPSTREAM}-${XORGXRDP_DEBREV}~fleet${FLEET_REV}~${RELTAG}"

# When run locally, hand artifacts back to the host user (CI leaves them root).
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
  chown -R "$HOST_UID:$HOST_GID" "$OUT"
fi

ls -l "$OUT"
echo "=== Done: $CODENAME ==="
