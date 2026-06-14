# xrdp-fleet

Build a **custom xrdp 0.10.6 with RemoteFX *and* H.264 (GFX)** as `.deb`
packages, and serve them from a **signed GitHub Pages apt repository** so all
your machines install and stay updated with plain `apt`.

Built for a small fleet (10+ Ubuntu / Linux Mint boxes) where stock xrdp eats
too much bandwidth. The stock Ubuntu/Debian xrdp in the 0.9.x series has **no
H.264 at all** (the encoder is a stub) — you only get H.264 from **0.10.2+**.
This repo rebuilds Debian's well-maintained 0.10.6 packaging, with both codecs
already enabled, targeted at your exact distro releases.

> Want the codec/bandwidth tuning details? See [docs/TUNING.md](docs/TUNING.md).

---

## How it controls "dependency explosion"

The thing that makes cross-distro `.deb` builds blow up is `dpkg-shlibdeps`
baking in whatever library versions were present *at build time*. The defenses
here:

1. **Build inside the exact target distro.** Each `.deb` is compiled in an
   `ubuntu:24.04` or `ubuntu:22.04` container, so its `Depends:` only ever
   reference libraries that exist on that release. A noble build is published
   only to the noble suite; a jammy build only to jammy.
2. **Per-codename apt suites and pools.** `dists/noble` and `dists/jammy` each
   index **only** their own `pool/<codename>/`, so a jammy machine can never be
   offered a noble-built package.
3. **`--no-install-recommends` + apt pinning** on the client, so installing
   xrdp doesn't drag in optional extras, and your build wins over (and is never
   clobbered by) the distro package.

---

## Repository layout

```
config.env                  # single source of truth: versions, codenames, identity
Makefile                    # make keygen / build / repo / clean
scripts/
  build-deb.sh              # (in-container) fetch Debian source, set codec build, dpkg-buildpackage
  build-local.sh            # (host) drive Docker per codename -> ./out/<cn>/*.deb
  make-repo.sh              # assemble ./repo, apt-ftparchive, GPG-sign Release/InRelease
  gpg-keygen.sh             # one-time signing key + export for CI secret
.github/workflows/release.yml  # CI: matrix build -> sign -> publish gh-pages
client/
  install-client.sh         # run on each machine: add repo, pin, install
  fleet-xrdp.sources        # deb822 reference
  90-fleet-xrdp.pref        # apt pin reference
docs/TUNING.md              # codec + bandwidth tuning
```

Nothing from upstream xrdp is vendored — `build-deb.sh` fetches the pinned
Debian **source** package (`xrdp_0.10.6-5`, `xorgxrdp_0.10.5-2`) at build time.

---

## What gets built

| Package | Upstream | Codecs |
|---|---|---|
| `xrdp` | 0.10.6 | RemoteFX (`--enable-rfxcodec`) + H.264 (`--enable-x264` + `--enable-openh264`), plus jpeg, opus, mp3lame, fuse, pam, vsock |
| `xorgxrdp` | 0.10.5 | the matching Xorg backend — **must** match xrdp's 0.10.x ABI (see caveats) |

The Debian 0.10.6 `debian/rules` already enables both codecs, so **no rules
patch is applied** — we only restamp the version per codename.

---

## One-time setup

```bash
git clone https://github.com/norandom/xrdp-fleet && cd xrdp-fleet

# 1. Create the apt signing key (writes fleet-xrdp-private.asc)
make keygen

# 2. Store the private key as a CI secret, then destroy the local export
gh secret set GPG_PRIVATE_KEY < fleet-xrdp-private.asc
shred -u fleet-xrdp-private.asc

# 3. In GitHub: Settings -> Pages -> Source = "Deploy from a branch",
#    Branch = gh-pages / root. (The first CI run creates the branch.)
```

## Build & publish (CI)

```bash
git tag v0.10.6-fleet1 && git push --tags     # or run the workflow manually
```
CI builds noble+jammy in Docker, signs the repo, and publishes it to
`https://norandom.github.io/xrdp-fleet/`.

## Build locally (optional, to test before pushing)

Needs Docker. Produces `.deb`s under `./out/`:
```bash
make build            # both codenames
make build-noble      # just one
make repo             # assemble + sign ./repo from ./out (needs the signing key)
```

## Install on each of your machines

```bash
curl -fsSL https://norandom.github.io/xrdp-fleet/install-client.sh | bash
```
The script auto-detects the Ubuntu base (`noble`/`jammy` — it reads
`UBUNTU_CODENAME`, so Linux Mint works), adds the signed repo, pins it, and
installs `xrdp` + `xorgxrdp` without recommends. Thereafter `apt upgrade` keeps
them current from your repo.

---

## Updating later

- **Ship a fresh rebuild of the same xrdp:** bump `FLEET_REV` in `config.env`
  (`1` → `2`), tag, push. Clients auto-upgrade (higher version sorts higher).
- **Take a newer upstream xrdp:** update `XRDP_UPSTREAM` / `XRDP_DEBREV` (and
  xorgxrdp) in `config.env` to the current sid version
  (https://packages.debian.org/sid/xrdp), then tag & push.

---

## Caveats (read these)

1. **xorgxrdp must match — highest risk.** xrdp ↔ xorgxrdp talk over a private
   local IPC + shared-memory framebuffer that changed in 0.10.x. The distro's
   0.9.x xorgxrdp will produce broken/garbled GFX against this xrdp. This repo
   always builds and ships the matching `xorgxrdp 0.10.5`; the client installer
   installs it explicitly. Don't mix.
2. **jammy `systemd-dev` fix is automatic.** jammy (systemd 249) lacks the
   `systemd-dev` build-dep (split out at systemd 253); `build-deb.sh` rewrites
   it to `libsystemd-dev`. If a future xrdp needs `systemdsystemunitdir` and
   the build errors on it, add `--with-systemdsystemunitdir=/lib/systemd/system`
   via a `debian/rules` override.
3. **Versions use a `~fleetN~ubuntuXX.04` suffix**, which sorts *below* a
   hypothetical official `0.10.6-1`. The `Pin-Priority: 1001` is what
   guarantees your build wins regardless — keep the pin in place.
4. **Per-codename builds are mandatory.** A noble `.deb` is not reliably
   installable on jammy and vice-versa; that's by design.
5. **openh264** comes from Ubuntu **universe** (source-built, not the Cisco
   binary blob). Default Ubuntu container images have universe enabled.
6. **amd64 only** here (`nasm`-built RemoteFX SIMD is amd64). Extend the matrix
   for other arches if needed.

---

## Why not just `apt source xrdp` + edit `debian/rules`?

That was the original plan, but on the 0.9.24 source tree the H.264 flags
(`--enable-gfx-avc444` etc.) don't exist — autoconf silently ignores unknown
`--enable-*` flags, so you'd ship a package that builds fine and contains **no
H.264**. Real H.264 needs the 0.10.x line, which is what this repo builds.
