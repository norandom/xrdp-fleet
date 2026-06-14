#!/usr/bin/env bash
# ---------------------------------------------------------------------
# One-time: generate the apt repo signing key, then export the private
# half for the GitHub Actions secret. The PUBLIC half is published by
# make-repo.sh as pubkey.gpg; the PRIVATE half must NEVER be committed.
# ---------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source config.env

if gpg --list-secret-keys --with-colons "$GPG_EMAIL" 2>/dev/null | grep -q '^sec'; then
  echo "A secret key for $GPG_EMAIL already exists; not creating another."
else
  cat > gen-key-params <<EOF
%echo Generating ${GPG_NAME}
Key-Type: rsa
Key-Length: 4096
Subkey-Type: rsa
Subkey-Length: 4096
Name-Real: ${GPG_NAME}
Name-Email: ${GPG_EMAIL}
Expire-Date: 3y
%no-protection
%commit
%echo done
EOF
  gpg --batch --gen-key gen-key-params
  rm -f gen-key-params
fi

KEYID="$(gpg --list-secret-keys --with-colons "$GPG_EMAIL" | awk -F: '/^sec/{print $5; exit}')"
gpg --armor --export-secret-keys "$KEYID" > fleet-xrdp-private.asc

cat <<MSG

Signing key ready: $KEYID

Next steps (one-time):
  1. Add the private key as a GitHub Actions secret:
       gh secret set GPG_PRIVATE_KEY < fleet-xrdp-private.asc
  2. Delete the local export once stored:
       shred -u fleet-xrdp-private.asc   # (or rm)
  3. The public key ships automatically as repo/pubkey.gpg when CI runs.

Keep your local GnuPG keyring backed up — it is the only copy of the key.
MSG
