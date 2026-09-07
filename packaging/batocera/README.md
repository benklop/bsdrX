# Batocera package

A SHARE-persistent install of the Linux bundle: kmsgrab + VAAPI ffmpeg, the
`bsdrx` user service, iHD/DRM permission workarounds, and settings on
`/userdata` (overlay `/opt` is empty after a Batocera reboot).

```bash
# with the linux docker image (also emits AppImage + .deb):
./distribute.sh linux
# or pack from an already-built dist .deb (no docker):
make batocera
```

Artifact: `dist/bsdr-agent_<version>_batocera.tar.gz`

On the guest (as root):

```bash
tar -xzf bsdr-agent_*_batocera.tar.gz
cd bsdr-agent-batocera
./install.sh
```

`install.sh` copies the tree to `/userdata/opt/bsdrX`, bind-mounts it at
`/opt/bsdrX`, installs `/userdata/system/services/bsdrx`, seeds
`use_vaapi=1` / `use_kmsgrab=1` if settings are missing, and enables the
service. Override `SHARE`, `BSDRX_OPT`, or `START=0`.

The tarball does **not** ship `libva` — Batocera's iHD is built against
system libva 2.23, and the Debian 12 bundle's libva 1.17 cannot load it
(`__vaDriverInit_1_0`). The service also stashes any leftover bundled
`libva*.so*` so a `.deb` copy still works.

The service (each start):

- bind-mounts SHARE onto `/opt/bsdrX`
- points bundled libssl at Batocera's CA bundle
- symlinks `/usr/lib/dri/iHD_drv_video.so` → `/usr/lib/va/iHD_drv_video.so`
- `chmod a+rw /dev/dri/card0 /dev/dri/renderD128` (no `setcap` on Batocera)
- launches `--vaapi --kmsgrab --no-browser` with the panel on `:8088`

Optional `/userdata/system/bsdrx/bsdrx.env` for `BSDRX_ARGS` / cloud keys.
Optional `/userdata/system/bsdrx/learn-quest-arp.py` if present.
