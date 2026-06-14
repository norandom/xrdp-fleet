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

# --- Landing page + client installer ---------------------------------
# Publishes install-client.sh into the repo (so `curl <pages>/install-client.sh
# | bash` works) and an index.html (so the root URL isn't a bare 404).
cp ../client/install-client.sh ./install-client.sh
cat > index.html <<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${REPO_LABEL} — xrdp apt repo</title>
<style>body{font-family:system-ui,sans-serif;max-width:46rem;margin:3rem auto;padding:0 1rem;line-height:1.55}
pre{background:#f4f4f4;border-radius:6px;padding:1rem;overflow:auto}code{background:#f4f4f4;border-radius:4px;padding:.1rem .3rem}</style>
</head><body>
<h1>${REPO_LABEL}</h1>
<p>Custom <strong>xrdp ${XRDP_UPSTREAM}</strong> + matching xorgxrdp with <strong>RemoteFX and H.264</strong>,
built per-distro and served as a GPG-signed apt repository. Suites: <code>${CODENAMES}</code> (amd64).</p>
<h2>Install</h2>
<pre>curl -fsSL ${PAGES_URL}/install-client.sh | bash</pre>
<p>Auto-detects the Ubuntu base (noble / jammy; Linux Mint supported), adds this repo with
GPG verification and an apt pin, then installs <code>xrdp</code> + <code>xorgxrdp</code>.</p>
<h2>Contents</h2>
<ul>
<li><a href="install-client.sh">install-client.sh</a></li>
<li><a href="pubkey.gpg">pubkey.gpg</a> — repo signing key</li>
<li><code>dists/&lt;suite&gt;/</code> + <code>pool/&lt;suite&gt;/</code> — the archive</li>
</ul>
<p>Source &amp; docs: <a href="https://github.com/${GH_USER}/${GH_REPO}">github.com/${GH_USER}/${GH_REPO}</a></p>
</body></html>
HTML

rm -f apt-ftparchive.conf

echo "apt repo built in ./repo  (suites: $CODENAMES, key: $KEYID)"
find . -maxdepth 4 -type f | sort
