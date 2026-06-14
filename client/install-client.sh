#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Run this on each of your machines to install the fleet xrdp build.
#   curl -fsSL https://norandom.github.io/xrdp-fleet/install-client.sh | bash
# (or copy this file over and run it).
#
# It adds the signed repo, pins it so it wins over the distro package
# (and is never clobbered by `apt upgrade`), and installs xrdp+xorgxrdp
# with --no-install-recommends to avoid dependency bloat.
# ---------------------------------------------------------------------
set -euo pipefail

PAGES_URL="https://norandom.github.io/xrdp-fleet"
REPO_ORIGIN="fleet-xrdp"
REPO_LABEL="fleet-xrdp"

# Detect the Ubuntu base codename. NOTE: on Linux Mint, VERSION_CODENAME is
# the Mint codename (e.g. 'xia'); the Ubuntu base is in UBUNTU_CODENAME.
# shellcheck disable=SC1091
. /etc/os-release
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
case "$CODENAME" in
  noble|jammy) ;;
  *) echo "Unsupported base '$CODENAME'. This repo serves noble (24.04) and jammy (22.04)." >&2
     echo "On Mint, ensure UBUNTU_CODENAME is set in /etc/os-release." >&2
     exit 1 ;;
esac
echo ">> Detected Ubuntu base: $CODENAME"

SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

# 1) Keyring (APT 2.4+ canonical location)
$SUDO install -d -m 0755 /etc/apt/keyrings
curl -fsSL "$PAGES_URL/pubkey.gpg" | $SUDO tee /etc/apt/keyrings/fleet-xrdp.gpg >/dev/null

# 2) deb822 source — Suites is the codename, Components is main (NOT './')
$SUDO tee /etc/apt/sources.list.d/fleet-xrdp.sources >/dev/null <<EOF
Types: deb
URIs: $PAGES_URL
Suites: $CODENAME
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/fleet-xrdp.gpg
EOF

# 3) Pin so our repo wins (1001 > 1000 allows even a downgrade) but still
#    auto-updates from our own repo on future rebuilds.
$SUDO tee /etc/apt/preferences.d/90-fleet-xrdp >/dev/null <<EOF
Package: *
Pin: release o=$REPO_ORIGIN,l=$REPO_LABEL
Pin-Priority: 1001
EOF

# 4) Install. xorgxrdp is functionally required (the Xorg session backend)
#    and must be the matching fleet build, so install it explicitly —
#    --no-install-recommends would otherwise skip it.
$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends xrdp xorgxrdp

echo
echo
echo ">> Installed:"
echo "     xrdp     $(dpkg-query -W -f='${Version}' xrdp 2>/dev/null)"
echo "     xorgxrdp $(dpkg-query -W -f='${Version}' xorgxrdp 2>/dev/null)"
echo ">> Versions should carry a ~fleetN~ tag. RemoteFX + H.264 are both compiled in;"
echo "   the RDP client negotiates which codec to use per session."
