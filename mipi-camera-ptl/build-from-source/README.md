# MIPI Camera Build-from-Source Installer

Build and install the full Intel IPU7 hardware ISP camera stack from source
on Hurrican/Performance with OV08X40 sensor.

## Requirements

- Hurrican/Performance platform with OV08X40 MIPI camera
- Arch Linux (Omarchy or standard) **or** Ubuntu 24.04 LTS
- ~15 GB free disk space (kernel source + build artifacts)
- Internet connection (cloning repos + packages)
- 30-60 minutes for kernel build, ~5 minutes for everything else

## Quick Start

### Omarchy — Full Build (kernel + camera)

```bash
cd mipi-camera-ptl/build-from-source

# Phase 1: install deps, clone repos, build kernel
sudo ./mipi_install.sh
# -> configure bootloader, reboot into new kernel

# Phase 2: build modules + userspace, deploy everything
sudo ./mipi_install.sh
# -> reboot when prompted
```

### Omarchy — Pre-built 6.19.6 Kernel (camera only)

For systems already running kernel 6.19.6 built at `~/kernel-build/linux-6.19.6`.
Single-phase — no kernel build, no mid-install reboot.

```bash
cd mipi-camera-ptl/build-from-source
sudo ./mipi_install_omarchy_6196.sh
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

The two-phase scripts auto-detect which phase to run.

## How It Works

### Full build scripts (mipi_install.sh / mipi_install_ubuntu.sh)

Two phases because the kernel must be installed and booted before out-of-tree
modules can be built against it.

**Phase 1 (pre-reboot):**

| Step | What happens |
|------|-------------|
| 1 | Install build + runtime packages (~30 packages) |
| 2 | Clone 7 source repos into `~/camera-build/` |
| 3 | Apply kernel patch: PSYS port |
| 4 | Configure kernel (camera + audio configs enabled) |
| 5 | Build kernel (`make -j$(nproc)` — takes 30-60 min) |
| 6 | Install kernel + modules + create build symlink |
| 7 | Prompt to configure bootloader and reboot |

**Phase 2 (post-reboot):**

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
| 9 | Build `v4l2loopback` |
| 10 | Deploy system config (modprobe, WirePlumber, systemd) |
| 11 | Install camera-feed user service + camera-session wrapper |
| 12 | Build modified GNOME Snapshot (12 Mbps video quality) |
| 13 | Set up device permissions, udev rules, workarounds |
| 14 | Run depmod, ldconfig, daemon-reload |
| 15 | Clean up state file |

### Pre-built kernel script (mipi_install_omarchy_6196.sh)

Single phase — skips kernel build entirely. Applies PSYS patch to the existing
kernel source tree, then runs all Phase 2 steps against it.

## Source Repositories

All repos are cloned into `~/camera-build/`:

| Repo | Purpose |
|------|---------|
| [sof-linux](https://github.com/thesofproject/linux) | SOF kernel with IPU7 staging + USBIO (full build only) |
| [ipu7-drivers](https://github.com/intel/ipu7-drivers) | PSYS source (ported into staging) |
| [vision-drivers](https://github.com/intel/vision-drivers) | CVS driver for sensor power/ownership |
| [ipu7-camera-bins](https://github.com/intel/ipu7-camera-bins) | Proprietary firmware + imaging libs |
| [ipu7-camera-hal](https://github.com/intel/ipu7-camera-hal) | Camera HAL (libcamhal) |
| [icamerasrc](https://github.com/intel/icamerasrc) | GStreamer source plugin |
| [v4l2loopback](https://github.com/umlaeute/v4l2loopback) | Virtual V4L2 camera device |
| [snapshot](https://github.com/GNOME/snapshot) | GNOME Camera app |

## Patches Applied

Three git patches are applied automatically from `../patches/`:

| Patch | Target | What it does |
|-------|--------|-------------|
| `0001-staging-ipu7-port-PSYS-*` | kernel source | Copies PSYS source into kernel staging tree |
| `0003-icvs-*` | vision-drivers | Lets CVS firmware power sensor via USBIO GPIO |
| `0004-snapshot-*` | snapshot | 12 Mbps video bitrate + medium x264enc preset |

**Note:** Patch `0002` (ABI workaround) is intentionally **not** applied. Since
these scripts build both the kernel and modules from the same source, the ABI is
consistent and runtime PM works correctly without the workaround.

## Usage

```bash
# Omarchy — full build
sudo ./mipi_install.sh          # Phase 1 (first run) or Phase 2 (after reboot)
sudo ./mipi_install.sh --phase2 # Force Phase 2 (skip kernel version check)
sudo ./mipi_install.sh --reset  # Reset state and start from scratch

# Omarchy — pre-built 6.19.6 kernel
sudo ./mipi_install_omarchy_6196.sh          # Run installer
sudo ./mipi_install_omarchy_6196.sh --force  # Skip kernel version check

# Ubuntu 24.04
sudo ./mipi_install_ubuntu.sh          # Phase 1 or Phase 2
sudo ./mipi_install_ubuntu.sh --phase2 # Force Phase 2
sudo ./mipi_install_ubuntu.sh --reset  # Reset state
```

## Verify After Install

```bash
sudo dmesg | grep -i 'ipu7\|cvs\|ov08x'   # Driver messages
ls /dev/video* /dev/ipu*                     # Device nodes
gst-inspect-1.0 icamerasrc                   # GStreamer plugin
systemctl status camera-init.service         # Module loader service
lsmod | grep -E 'ipu7|intel_cvs|ov08x40|v4l2loopback'
```

Then open Camera (Snapshot) from the app launcher.

## Troubleshooting

**Kernel version mismatch warning:**
The PSYS patch adds a commit to the kernel source tree, changing the git hash
suffix. The script compares base versions only, but if you still get a warning,
use `--force` or `--phase2` to skip the check.

**Kernel build fails:**
Make sure you have enough disk space (~15 GB) and all build deps installed.
- Arch: `sudo pacman -S base-devel bc perl python cpio libelf pahole zstd flex bison openssl`
- Ubuntu: `sudo apt install build-essential bc perl python3 cpio libelf-dev dwarves zstd flex bison libssl-dev`

**CVS driver build fails with "No such file or directory":**
The `/lib/modules/$(uname -r)/build` symlink is missing. The script creates it
but if it got deleted: `sudo ln -sf ~/kernel-build/linux-6.19.6 /lib/modules/$(uname -r)/build`

**Camera HAL build fails with jsoncpp error:**
`sudo mkdir -p /usr/include/jsoncpp && sudo ln -sf /usr/include/json /usr/include/jsoncpp/json`

**Camera preview is black:**
Check `sudo dmesg | grep -i cvs` — you need "Transfer of ownership success".
If missing, the CVS patch wasn't applied. Also verify firmware is in `/lib/firmware/intel/ipu/`.

**Green line at bottom of video recordings:**
Hardware encoding (VAAPI) has a bug on this platform. The script disables it
automatically, but verify: `gsettings get org.gnome.Snapshot enable-hardware-encoding`
should return `false`.
