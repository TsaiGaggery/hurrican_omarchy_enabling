# MIPI Camera Build-from-Source — Hurrican/Performance

Build-from-source installers for OV08X40 MIPI camera with Intel IPU7 hardware ISP.

## Requirements

- Hurrican/Performance platform with OV08X40 camera
- Omarchy (Arch Linux) or Ubuntu 24.04 LTS
- Internet connection (for package dependencies and repo cloning)

## Installation Scripts

### Omarchy — Full Build (SOF kernel + camera stack)

Two-phase installer: Phase 1 builds a SOF kernel (6.19.0-rc6), Phase 2 builds
camera modules and userspace against it.

```bash
cd mipi-camera-ptl/build-from-source

# Phase 1: install deps, clone repos, build + install kernel
sudo ./mipi_install.sh
# Reboot into the new kernel

# Phase 2: build modules + userspace, deploy everything
sudo ./mipi_install.sh
# Reboot when prompted
```

### Omarchy — Pre-built 6.19.6 Kernel (camera stack only)

Single-phase installer for systems already running kernel 6.19.6 built at
`~/kernel-build/linux-6.19.6`. Skips kernel build entirely.

```bash
cd mipi-camera-ptl/build-from-source
sudo ./mipi_install_omarchy_6196.sh
# Reboot when prompted
```

### Ubuntu 24.04

Two-phase installer using apt, GRUB, and Ubuntu conventions.

```bash
cd mipi-camera-ptl/build-from-source

# Phase 1: install deps, clone repos, build + install kernel
sudo ./mipi_install_ubuntu.sh
# Reboot (SOF kernel is default GRUB entry)

# Phase 2: build modules + userspace, deploy everything
sudo ./mipi_install_ubuntu.sh
# Reboot when prompted
```

## What Gets Installed

| Component | Description |
|-----------|-------------|
| IPU7 kernel modules | ISYS (capture) + PSYS (hardware ISP) |
| CVS driver | Camera ownership transfer (`rgbcamera_pwrup_host=0`) |
| IPU7 firmware | `ipu7ptl_fw.bin` |
| Camera HAL | `libcamhal` + Intel imaging libraries |
| AIQB tuning | `OV08X40_KAFE799_PTL.aiqb` for 3A (AWB/AE/AF) |
| icamerasrc | GStreamer source plugin for hardware ISP |
| v4l2loopback | Virtual camera bridge (`/dev/video50`) |
| WirePlumber rules | Hide raw IPU7 V4L2 devices, disable libcamera monitor |
| camera-feed.service | Camera feed (icamerasrc -> v4l2loopback) |
| GNOME Snapshot | Modified Camera app (12 Mbps video, software encoding) |

Open Camera from the app launcher (Super + Space, type "Camera").

## Directory Structure

```
mipi-camera-ptl/
├── build-from-source/              # Installer scripts
│   ├── mipi_install.sh             # Omarchy full build (SOF kernel + camera)
│   ├── mipi_install_omarchy_6196.sh # Omarchy 6.19.6 (camera stack only)
│   └── mipi_install_ubuntu.sh      # Ubuntu 24.04 full build
├── patches/                        # Kernel and app patches
│   ├── 0001-staging-ipu7-*.patch   # PSYS port to staging tree
│   ├── 0003-icvs-*.patch           # CVS rgbcamera_pwrup_host=0 fix
│   └── 0004-snapshot-*.patch       # Snapshot video quality improvement
├── system-config/                  # System configuration files
│   ├── modprobe.d/                 # Module blacklist and soft deps
│   ├── modules-load.d/             # v4l2loopback auto-load
│   ├── systemd/                    # camera-init and camera-feed services
│   ├── wireplumber/                # IPU7 hide rules (.conf and .lua)
│   ├── camera-session              # On-demand camera wrapper
│   └── camera-feed-ffmpeg          # ffmpeg bridge (Ubuntu)
├── libcamera/                      # OV08X40 software ISP tuning
└── README.md
```

## Verify Installation

```bash
sudo dmesg | grep -i 'ipu7\|cvs\|ov08x'   # Driver messages
ls /dev/video* /dev/ipu*                     # Device nodes
gst-inspect-1.0 icamerasrc                   # GStreamer plugin
systemctl status camera-init.service         # Module loader service
```
