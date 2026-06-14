# Bandwidth & codec tuning

Building this package gives you the **capability** for RemoteFX and H.264.
Whether they actually cut your bandwidth depends on server config, client
settings, and your workload. This is the cheat-sheet.

## Which codec wins?

| Workload | Best codec | Why |
|---|---|---|
| Terminals, IDEs, browsers, office (mostly static, text-heavy) | **RemoteFX** | Sends only changed regions + caches static screens; keeps text crisp. H.264 4:2:0 can blur small colored text and re-encodes whole frames. |
| Video, photos, animation, smooth scrolling | **H.264 (GFX)** | ~3–4× smaller than bitmap at 1080p; designed for full-motion. |

xrdp advertises both; the **client negotiates** which to use. You don't pick
one at build time — you have both.

Trade-off to remember: xrdp's H.264 encoder is **software-only** (x264/OpenH264
on the CPU). On a multi-user server, H.264 raises *server* CPU noticeably;
RemoteFX is much lighter. Clients hardware-decode H.264, so the cost is on the
server side.

## Server side — `/etc/xrdp/xrdp.ini`

These are on by default but verify:

```ini
[Globals]
bitmap_cache=true
bitmap_compression=true
bulk_compression=true
max_bpp=32            ; keep 32 — H.264 and modern mstsc need it; do NOT drop to 16 if you want H.264
```

The codec order / GFX behaviour lives in `xrdp.ini`'s connection sections and
in `sesman.ini`. After changing, restart: `sudo systemctl restart xrdp`.

## Client side — the biggest free wins (no rebuild)

Disabling desktop eye-candy cuts bandwidth regardless of codec:

- **Windows mstsc:** Experience tab → pick "Modem" / uncheck wallpaper, font
  smoothing, desktop composition, window-drag contents, menu animations.
- **FreeRDP / Remmina:**
  ```
  xfreerdp /v:HOST /gfx:AVC444 +gfx-progressive /network:modem \
           -wallpaper -themes -fonts -window-drag -menu-anims
  ```
  `/gfx:AVC444` requests H.264; drop it (or use `/rfx`) to prefer RemoteFX.
  Remmina must be built against a libfreerdp with H.264 (ffmpeg/OpenH264),
  else it logs "does not support H264" and falls back to RemoteFX.

## Verifying a codec is actually in use

Watch the xrdp log while connecting:
```
sudo journalctl -u xrdp -f
```
Look for GFX / H264 / RFX capability negotiation lines. If H.264 never
engages from a Windows client, confirm the client is Win10/11 mstsc with
32-bit color and that `xorgxrdp` is the matching fleet build (a mismatched
xorgxrdp breaks GFX — see README caveats).
