#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Assemble + GPG-sign a multi-suite apt repository into ./repo from the
# .debs in ./out (or a dir passed as $1).
#
# Layout (per-codename pool so a suite NEVER indexes another suite's debs):
#   repo/pool/<codename>/main/*.deb
#   repo/dists/<codename>/main/binary-amd64/Packages[.gz]
#   repo/dists/<codename>/{Release,Release.gpg,InRelease}
#   repo/pubkey.gpg                      (dearmored public key for clients)
#
# Requires the signing secret key (scripts/gpg-keygen.sh locally, or
# `gpg --import` of the GPG_PRIVATE_KEY secret in CI).
# ---------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source config.env

OUT="${1:-out}"
rm -rf repo
mkdir -p repo

# --- Route each .deb to its codename's pool by the version suffix -----
shopt -s nullglob globstar
found=0
for deb in "$OUT"/**/*.deb; do
  base="$(basename "$deb")"
  case "$base" in
    *~ubuntu24.04_*) suite="noble" ;;
    *~ubuntu22.04_*) suite="jammy" ;;
    *) echo "WARN: cannot route '$base' to a suite (no ~ubuntuXX.04 tag); skipping"; continue ;;
  esac
  mkdir -p "repo/pool/$suite/main"
  cp "$deb" "repo/pool/$suite/main/"
  found=$((found + 1))
done
[ "$found" -gt 0 ] || { echo "No .debs found under '$OUT/' — run scripts/build-local.sh first."; exit 1; }

# --- Generate apt-ftparchive config ----------------------------------
# Note: apt-ftparchive's $(DIST) expands to the FULL tree name (e.g.
# "dists/noble"), so the default Packages path "$(DIST)/$(SECTION)/binary-
# $(ARCH)/Packages" already resolves correctly — don't re-prefix it. We only
# override Directory per-tree to point at that codename's isolated pool, which
# is what guarantees a suite never indexes another codename's .debs.
# BinCacheDB "" disables the cache db (avoids a stray permission error).
cd repo
{
  echo 'Dir { ArchiveDir "."; };'
  echo 'Default { Packages::Compress ". gzip"; Contents::Compress ". gzip"; };'
  echo 'TreeDefault { BinCacheDB "/tmp/xrdp-fleet-aptcache-$(ARCH).db"; };'
  for SUITE in $CODENAMES; do
    echo "Tree \"dists/$SUITE\" { Directory \"pool/$SUITE/\$(SECTION)\"; Sections \"main\"; Architectures \"amd64\"; }"
  done
} > apt-ftparchive.conf

for SUITE in $CODENAMES; do mkdir -p "dists/$SUITE/main/binary-amd64"; done
apt-ftparchive generate apt-ftparchive.conf

# --- Find the signing key by email -----------------------------------
KEYID="$(gpg --list-secret-keys --with-colons "$GPG_EMAIL" 2>/dev/null | awk -F: '/^sec/{print $5; exit}')"
[ -n "$KEYID" ] || { echo "No GPG secret key for $GPG_EMAIL — run scripts/gpg-keygen.sh (or import the CI secret)."; exit 1; }

# --- Per-suite signed Release ----------------------------------------
for SUITE in $CODENAMES; do
  apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="$REPO_ORIGIN" \
    -o APT::FTPArchive::Release::Label="$REPO_LABEL" \
    -o APT::FTPArchive::Release::Suite="$SUITE" \
    -o APT::FTPArchive::Release::Codename="$SUITE" \
    -o APT::FTPArchive::Release::Architectures="amd64" \
    -o APT::FTPArchive::Release::Components="main" \
    -o APT::FTPArchive::Release::Acquire-By-Hash="yes" \
    release "dists/$SUITE" > "dists/$SUITE/Release"
  gpg --batch --yes --default-key "$KEYID" --clearsign -o "dists/$SUITE/InRelease"  "dists/$SUITE/Release"
  gpg --batch --yes --default-key "$KEYID" -abs        -o "dists/$SUITE/Release.gpg" "dists/$SUITE/Release"
done

# --- Public key for clients (dearmored, for Signed-By keyring) --------
gpg --export "$KEYID" > pubkey.gpg
rm -f apt-ftparchive.conf

echo "apt repo built in ./repo  (suites: $CODENAMES, key: $KEYID)"
find . -maxdepth 4 -type f | sort
