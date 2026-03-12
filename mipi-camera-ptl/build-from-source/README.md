# MIPI Camera Build-from-Source Installer

Build and install the full Intel IPU7 hardware ISP camera stack from source
on Hurrican/Performance with OV08X40 sensor.

This is the companion to `install.sh` (which deploys pre-built binaries).
Use this script when you need to build everything yourself — different kernel
version, different Arch install, or just want to see how the sausage is made.

## Requirements

- Hurrican/Performance platform with OV08X40 MIPI camera
- Arch Linux (Omarchy or standard) **or** Ubuntu 24.04 LTS
- ~15 GB free disk space (kernel source + build artifacts)
- Internet connection (cloning repos + packages)
- 30-60 minutes for kernel build, ~5 minutes for everything else

## Quick Start

### Arch Linux (Omarchy)

```bash
cd mipi-camera-ptl/build-from-source

# Phase 1: install deps, clone repos, build kernel
sudo ./mipi_install.sh
# -> configure bootloader, reboot into new kernel

# Phase 2: build modules + userspace, deploy everything
sudo ./mipi_install.sh
# -> reboot when prompted
```

### Ubuntu 24.04

```bash
cd mipi-camera-ptl/build-from-source

# Phase 1: install deps, clone repos, build kernel
sudo ./mipi_install_ubuntu.sh
# -> GRUB updated, reboot (SOF kernel is default)

# Phase 2: build modules + userspace, deploy everything
sudo ./mipi_install_ubuntu.sh
# -> reboot when prompted
```

Both scripts auto-detect which phase to run.

## How It Works

The script runs in two phases because the kernel must be installed and booted
before out-of-tree modules can be built against it.

### Phase 1 (pre-reboot)

| Step | What happens |
|------|-------------|
| 1 | Install build + runtime packages via pacman (~30 packages) |
| 2 | Clone 7 source repos into `~/camera-build/` |
| 3 | Apply kernel patches: PSYS port + ABI workaround |
| 4 | Configure kernel (camera + audio configs enabled via `scripts/config`) |
| 5 | Build kernel (`make -j$(nproc)` — takes 30-60 min) |
| 6 | Install kernel + modules + create build symlink |
| 7 | Prompt to configure bootloader and reboot |

### Phase 2 (post-reboot)

| Step | What happens |
|------|-------------|
| 1 | Remove conflicting out-of-tree IPU7 modules |
| 2 | Build IPU7 staging modules (ISYS + PSYS), strip BTF, compress |
| 3 | Build CVS driver with ownership fix (`rgbcamera_pwrup_host=0`) |
| 4 | Install IPU7 firmware from `ipu7-camera-bins` |
| 5 | Install proprietary imaging libraries + headers |
| 6 | Build Camera HAL (`libcamhal`) via cmake |
| 7 | Install HAL config + AIQB tuning files |
| 8 | Build `icamerasrc` GStreamer plugin |
| 9 | Build `v4l2loopback` against SOF kernel |
| 10 | Deploy system config (modprobe, WirePlumber, systemd) |
| 11 | Install camera-feed user service + camera-session wrapper |
| 12 | Build modified GNOME Snapshot (12 Mbps video quality) |
| 13 | Set up device permissions, udev rules, workarounds |
| 14 | Run depmod, ldconfig, daemon-reload |
| 15 | Clean up state file |

## Source Repositories

All repos are cloned into `~/camera-build/`:

| Repo | Branch | Purpose |
|------|--------|---------|
| [sof-linux](https://github.com/thesofproject/linux) | `topic/sof-dev` | SOF kernel with IPU7 staging + USBIO |
| [ipu7-drivers](https://github.com/intel/ipu7-drivers) | `main` | PSYS source (ported into staging) |
| [vision-drivers](https://github.com/intel/vision-drivers) | `main` | CVS driver for sensor power/ownership |
| [ipu7-camera-bins](https://github.com/intel/ipu7-camera-bins) | `main` | Proprietary firmware + imaging libs |
| [ipu7-camera-hal](https://github.com/intel/ipu7-camera-hal) | `main` | Camera HAL (libcamhal) |
| [icamerasrc](https://github.com/intel/icamerasrc) | `icamerasrc_slim_api` | GStreamer source plugin |
| [v4l2loopback](https://github.com/umlaeute/v4l2loopback) | `main` | Virtual V4L2 camera device |
| [snapshot](https://github.com/GNOME/snapshot) | tag `50.rc` | GNOME Camera app |

## Patches Applied

Three git patches are applied automatically from `patches/`:

| Patch | Target | What it does |
|-------|--------|-------------|
| `0001-staging-ipu7-port-PSYS-from-ipu7-drivers.patch` | sof-linux | Copies PSYS source into kernel staging tree |
| `0003-icvs-set-rgbcamera_pwrup_host-0-for-Panther-Lake.patch` | vision-drivers | Lets CVS firmware power sensor via USBIO GPIO |
| `0004-snapshot-increase-video-bitrate-and-improve-x264enc.patch` | snapshot | 12 Mbps video bitrate + medium x264enc preset |

**Note:** Patch `0002` (ABI workaround) is intentionally **not** applied. It was
needed only for the pre-built binary installer (`install.sh`) where the kernel
binary was compiled from a different commit than the module source tree, causing
a `struct auxiliary_driver` layout mismatch. Since this script builds both the
kernel and modules from the same source, the ABI is consistent and runtime PM
works correctly without the workaround.

## Usage

```bash
# Arch Linux
sudo ./mipi_install.sh          # Phase 1 (first run) or Phase 2 (after reboot)
sudo ./mipi_install.sh --phase2 # Force Phase 2 (skip kernel version check)
sudo ./mipi_install.sh --reset  # Reset state and start from scratch

# Ubuntu 24.04
sudo ./mipi_install_ubuntu.sh          # Phase 1 or Phase 2
sudo ./mipi_install_ubuntu.sh --phase2 # Force Phase 2
sudo ./mipi_install_ubuntu.sh --reset  # Reset state
```

## What Gets Installed

| Component | Location |
|-----------|----------|
| SOF kernel | `/boot/` + `/lib/modules/<version>/` |
| IPU7 modules (ISYS + PSYS) | `/lib/modules/<version>/kernel/drivers/staging/media/ipu7/` |
| CVS driver | `/lib/modules/<version>/updates/drivers/misc/icvs/` |
| v4l2loopback | `/lib/modules/<version>/updates/` |
| IPU7 firmware | `/lib/firmware/intel/ipu/` |
| libcamhal + imaging libs | `/usr/lib/` |
| icamerasrc plugin | `/usr/lib/gstreamer-1.0/` |
| AIQB tuning files | `/usr/share/defaults/etc/camera/` |
| Sensor configs | `/etc/camera/ipu75xa/` |
| Modprobe configs | `/etc/modprobe.d/` |
| WirePlumber rules | `/etc/wireplumber/wireplumber.conf.d/` |
| camera-init.service | `/etc/systemd/system/` |
| camera-feed.service | `~/.config/systemd/user/` |
| camera-session wrapper | `/usr/local/bin/` |
| Modified Snapshot | `/usr/bin/snapshot` (pinned in pacman/apt) |
| udev rule | `/etc/udev/rules.d/90-ipu7-psys.rules` |
| libcamera tuning | `/usr/share/libcamera/ipa/simple/ov08x40.yaml` |

## Verify After Install

```bash
# Check kernel modules loaded
lsmod | grep -E 'ipu7|intel_cvs|ov08x40|v4l2loopback'

# Check dmesg for camera stack
sudo dmesg | grep -i 'ipu7\|cvs\|ov08x'

# Check devices
ls /dev/video* /dev/ipu*

# Check icamerasrc plugin
gst-inspect-1.0 icamerasrc

# Check services
systemctl status camera-init.service
```

Then open Camera (Snapshot) from the app launcher.

## Troubleshooting

**Phase 2 says kernel version mismatch:**
You haven't booted into the new kernel yet. Update your bootloader config
and reboot, or use `--phase2` to skip the check if you know the kernel is correct.

**Kernel build fails:**
Make sure you have enough disk space (~15 GB) and all build deps installed.
The script installs them automatically but if the package manager failed silently, try:
- Arch: `sudo pacman -S base-devel bc perl python cpio libelf pahole zstd flex bison openssl`
- Ubuntu: `sudo apt install build-essential bc perl python3 cpio libelf-dev dwarves zstd flex bison libssl-dev`

**CVS driver build fails with "No such file or directory":**
The `/lib/modules/$(uname -r)/build` symlink is missing. The script creates it
but if it got deleted: `sudo ln -sf ~/camera-build/sof-linux /lib/modules/$(uname -r)/build`

**Camera HAL build fails with jsoncpp error:**
The jsoncpp header path symlink may be missing:
`sudo mkdir -p /usr/include/jsoncpp && sudo ln -sf /usr/include/json /usr/include/jsoncpp/json`

**Camera preview is black:**
Check `sudo dmesg | grep -i cvs` — you need "Transfer of ownership success".
If missing, the CVS patch wasn't applied. Also verify firmware is in `/lib/firmware/intel/ipu/`.

**Green line at bottom of video recordings:**
Hardware encoding (VAAPI) has a bug on this platform. The script disables it
automatically, but verify: `gsettings get org.gnome.Snapshot enable-hardware-encoding`
should return `false`.

## Files in This Package

```
mipi-camera-ptl/
├── build-from-source/
│   ├── mipi_install.sh                 <- Build from source (Arch Linux)
│   ├── mipi_install_ubuntu.sh          <- Build from source (Ubuntu 24.04)
│   └── README.md                       <- This file
├── install.sh                          <- Binary deployer (pre-built)
├── uninstall.sh                        <- Uninstaller
├── patches/                            (shared — used by both installers)
│   ├── 0001-staging-ipu7-port-PSYS-from-ipu7-drivers.patch
│   ├── 0002-staging-ipu7-PSYS-ISYS-ABI-workaround-for-runtime-PM.patch
│   ├── 0003-icvs-set-rgbcamera_pwrup_host-0-for-Panther-Lake.patch
│   └── 0004-snapshot-increase-video-bitrate-and-improve-x264enc.patch
├── system-config/                      (shared — modprobe, systemd, wireplumber)
│   ├── modprobe.d/
│   ├── modules-load.d/
│   ├── systemd/
│   ├── wireplumber/
│   └── camera-session
├── camera-defaults/                    (AIQB tuning — used by install.sh only)
├── camera-ipu75xa/                     (sensor configs — used by install.sh only)
├── libcamera/
│   └── ov08x40.yaml                    (software ISP fallback tuning)
└── README.md                           (README for binary installer)
```

## See Also

- `MIPI_CAMERA_SETUP.md` — full setup guide with explanations
- `MIPI_CAMERA_TECHNICAL_NOTES.md` — debugging notes and hardware discovery
