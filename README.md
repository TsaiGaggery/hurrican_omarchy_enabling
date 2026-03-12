# Hurrican Omarchy Enabling — Hurrican/Performance

Enabling packages for Hurrican/Performance systems running Omarchy (Arch Linux) or Ubuntu 24.04.

## Contents

### sdca-backport-patches/

17-patch series to backport SDCA (SoundWire Device Class for Audio) class driver
fixes from mainline to kernel 6.19.6. Required for audio on Hurrican/Performance systems with
CS42L45 (jack) and CS35L57 (speaker) codecs.

Apply to a clean v6.19.6 kernel tree:

```bash
cd linux-6.19.6
git am ~/hurrican_omarchy_enabling/sdca-backport-patches/00*.patch
```

Key patches:
- 0002: ASoC jack hookup in class driver (fixes -ENOTSUPP on card registration)
- 0017: NULL pointer dereference fix in `sdca_jack_process` (crash fix)

### mipi-camera-ptl/

Build-from-source installers for OV08X40 MIPI camera with Intel IPU7 hardware ISP.
See [mipi-camera-ptl/README.md](mipi-camera-ptl/README.md) for full details.

Available scripts:
- `mipi_install.sh` — Omarchy full build (SOF kernel + camera stack)
- `mipi_install_omarchy_6196.sh` — Omarchy with pre-built 6.19.6 kernel (camera stack only)
- `mipi_install_ubuntu.sh` — Ubuntu 24.04 full build

```bash
cd hurrican_omarchy_enabling/mipi-camera-ptl/build-from-source
sudo ./mipi_install_omarchy_6196.sh
```

### openvino-install-scripts/

Automated installation of Intel OpenVINO with CPU, GPU, and NPU support.
See [openvino-install-scripts/README.md](openvino-install-scripts/README.md) for full details.

Available scripts:
- `install-openvino` — Omarchy / Arch Linux (pacman + AUR)
- `install-openvino-ubuntu` — Ubuntu 24.04 (apt + PPA)

```bash
cd hurrican_omarchy_enabling/openvino-install-scripts
./install-openvino
```
