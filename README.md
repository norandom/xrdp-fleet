# xrdp-fleet

Build custom xrdp 0.10.6 `.deb` packages with RemoteFX and H.264 (GFX), then
serve them from a signed GitHub Pages apt repository. Client machines install
and update through normal `apt` commands.

This is for a small fleet of Ubuntu, Linux Mint, and Kali machines where stock
xrdp uses too much bandwidth. The Ubuntu/Debian xrdp 0.9.x packages do not have
working H.264 support. The encoder is only a stub there; real H.264 support
starts in xrdp 0.10.2. This repo rebuilds Debian's 0.10.6 packaging with both
codecs enabled for each target distro release.

> **Architectural limitation -- full-screen snapshots.** `xorgxrdp` captures
> the entire screen as a bitmap on every frame. Unlike Windows RDP, where the
> GDI subsystem tells the protocol exactly which screen region changed and how
> to draw it, Linux xrdp has no equivalent fine-grained damage tracking. This
> means every frame carries full-screen pixel data regardless of what actually
> changed. The H.264 graphics pipeline (GFX / x264) is **not** more effective
> than RemoteFX 24-bit in this architecture -- both still encode a full-screen
> snapshot per frame. Capping the frame rate is the most effective bandwidth
> knob available today. This project cannot overcome these architectural limits;
> it only ensures both codecs are actually compiled in (unlike distro packages
> that ship a stub encoder).

> Want the codec/bandwidth tuning details? See [docs/TUNING.md](docs/TUNING.md).

## How it controls "dependency explosion"

The thing that makes cross-distro `.deb` builds blow up is `dpkg-shlibdeps`
baking in the library versions present at build time. This repo avoids that in
three ways:

1. Build inside the target distro. Each `.deb` is compiled in an
   `ubuntu:24.04` or `ubuntu:22.04` container, so its `Depends:` only ever
   reference libraries that exist on that release. A noble build is published
   only to the noble suite; a jammy build only to jammy.
2. Use per-codename apt suites and pools. `dists/noble` and `dists/jammy` each
   index only their own `pool/<codename>/`, so a jammy machine can never be
   offered a noble-built package.
3. Use `--no-install-recommends` and apt pinning on the client. Installing xrdp
   does not drag in optional extras, and your build keeps priority over the
   distro package.

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

Nothing from upstream xrdp is vendored. `build-deb.sh` fetches the pinned Debian
source packages, `xrdp_0.10.6-5` and `xorgxrdp_0.10.5-2`, at build time.

## What gets built

| Package | Upstream | Codecs |
|---|---|---|
| `xrdp` | 0.10.6 | RemoteFX (`--enable-rfxcodec`) + H.264 (`--enable-x264` + `--enable-openh264`), plus jpeg, opus, mp3lame, fuse, pam, vsock |
| `xorgxrdp` | 0.10.5 | matching Xorg backend for xrdp's 0.10.x ABI. Do not mix this with 0.9.x xorgxrdp. |

The Debian 0.10.6 `debian/rules` file already enables both codecs, so this repo
does not patch the build rules. It only restamps the package version per
codename.

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

## Build and publish with CI

```bash
git tag v0.10.6-fleet1 && git push --tags     # or run the workflow manually
```
CI builds every codename in `config.env` (noble, jammy, kali-rolling) in Docker,
signs the repo, and publishes it to `https://norandom.github.io/xrdp-fleet/`.

## Build locally

Local builds need Docker and write `.deb` files under `./out/`:
```bash
make build            # both codenames
make build-noble      # just one
make repo             # assemble + sign ./repo from ./out (needs the signing key)
```

## Install on each of your machines

```bash
curl -fsSL https://norandom.github.io/xrdp-fleet/install-client.sh | bash
```
The script detects the suite from `UBUNTU_CODENAME` on Ubuntu/Mint
(`noble`/`jammy`) or `VERSION_CODENAME` on Kali (`kali-rolling`). It then adds
the signed repo, pins it, and installs `xrdp` and `xorgxrdp` without recommends.
After that, `apt upgrade` keeps them current from your repo.

> On Kali, stock `xrdp` (from Debian) usually already includes both codecs, so
> this build is mainly for fleet uniformity/pinning rather than new capability.

## Updating later

- To ship a fresh rebuild of the same xrdp, bump `FLEET_REV` in `config.env`
  (`1` to `2`), tag, and push. Clients auto-upgrade because the higher version
  sorts higher.
- To take a newer upstream xrdp, update `XRDP_UPSTREAM`, `XRDP_DEBREV`, and the
  xorgxrdp values in `config.env` to the current sid version
  (https://packages.debian.org/sid/xrdp), then tag and push.

## Caveats (read these)

1. xrdp and xorgxrdp must match. They talk over private local IPC and a
   shared-memory framebuffer that changed in 0.10.x. The distro's 0.9.x
   xorgxrdp will produce broken or garbled GFX against this xrdp. This repo
   always builds and ships the matching `xorgxrdp 0.10.5`, and the client
   installer installs it explicitly.
2. jammy backport fixes are automatic. `build-deb.sh` applies two fixes for
   Debian sid packaging on Ubuntu 22.04, gated on `jammy`:
   - `systemd-dev` build-dep to `libsystemd-dev` (systemd-dev was split out at
     systemd 253; jammy ships 249).
   - `sysvinit-utils (>= 3.06-4)` runtime dep to `lsb-base` (`/lib/lsb/init-functions`
     moved into sysvinit-utils in sid; jammy still uses lsb-base).
   noble needs neither. If a future xrdp needs `systemdsystemunitdir` and the
   build errors on it, add `--with-systemdsystemunitdir=/lib/systemd/system` via
   a `debian/rules` override.
3. xrdp is installed before xorgxrdp during the build, because xorgxrdp
   build-depends on `xrdp (>= 0.10.5)`; `build-deb.sh` handles this ordering.
4. Versions use a `~fleetN~ubuntuXX.04` suffix, which sorts below a
   hypothetical official `0.10.6-1`. The `Pin-Priority: 1001` is what
   guarantees your build wins regardless. Keep the pin in place.
5. Per-codename builds are required. A noble `.deb` is not reliably installable
   on jammy, and the reverse is also true.
6. openh264 comes from Ubuntu universe (source-built, not the Cisco
   binary blob). Default Ubuntu container images have universe enabled.
7. This repo builds amd64 only (`nasm`-built RemoteFX SIMD is amd64). Extend the
   matrix for other arches if needed.

## Why not just `apt source xrdp` + edit `debian/rules`?

That was the original plan, but on the 0.9.24 source tree the H.264 flags
(`--enable-gfx-avc444` and related flags) do not exist. Autoconf silently
ignores unknown `--enable-*` flags, so the package builds but still has no
H.264 support. Real H.264 needs the 0.10.x line, which is what this repo builds.
