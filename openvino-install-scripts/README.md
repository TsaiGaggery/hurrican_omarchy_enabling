# OpenVINO Installation Scripts

Automated installation of Intel OpenVINO with CPU, GPU, and NPU support for Hurrican/Performance systems.

Two scripts are provided for different Linux distributions:

| Script | Target OS | Package Manager |
|--------|-----------|-----------------|
| `install-openvino` | Omarchy / Arch Linux | pacman + AUR |
| `install-openvino-ubuntu` | Ubuntu 24.04 LTS | apt + PPA |

## Requirements

- **Hardware**: Hurrican/Performance with Arc GPU and NPU
- **OS**: Ubuntu 24.04 LTS or Arch Linux (Omarchy)
- **Kernel**: Linux 6.13+ (required for NPU 5 / intel_vpu driver)
  - Ubuntu 24.04: the OEM or HWE kernel is recommended for full GPU support
  - Omarchy: kernel 6.19.6 or later recommended
- **Python**: 3.9 or later
- **Privileges**: sudo access required
- **Network**: Internet access to download packages

## Quick Start

### Ubuntu

```bash
chmod +x install-openvino-ubuntu
./install-openvino-ubuntu
```

### Omarchy (Arch Linux)

```bash
chmod +x install-openvino
./install-openvino
```

For non-interactive installation (e.g., scripted deployments):

```bash
./install-openvino-ubuntu -y
```

## Usage

```
install-openvino-ubuntu [OPTIONS]

Options:
  -h, --help          Show help message
  -y, --yes           Non-interactive mode (assume yes to all prompts)
  -v, --venv PATH     Custom virtual environment path (default: ~/openvino-env)
  --skip-npu          Skip NPU driver installation
  --skip-gpu          Skip GPU driver installation
  --uninstall         Remove OpenVINO installation
  --verify            Only run verification (check existing installation)
```

Both scripts accept the same options.

## What Gets Installed

### Phase 1: Base Packages

| Component | Ubuntu Package | Arch Package |
|-----------|---------------|--------------|
| Python pip | `python3-pip` | `python-pip` |
| Python venv | `python3-venv` | (built-in) |
| Python headers | `python3-dev` | (built-in) |

### Phase 1 (cont.): GPU Compute Packages

Skipped if `--skip-gpu` is passed.

| Component | Ubuntu (from PPA) | Arch |
|-----------|-------------------|------|
| Level Zero GPU backend | `libze-intel-gpu1` | `intel-compute-runtime` |
| Level Zero loader | `libze1` | `level-zero-loader` |
| OpenCL ICD | `intel-opencl-icd` | `intel-compute-runtime` |
| Metrics discovery | `intel-metrics-discovery` | (not required) |
| Graphics system controller | `libigsc0` | (not required) |
| OpenCL info tool | `clinfo` | (not required) |

**Ubuntu GPU source**: [ppa:kobuk-team/intel-graphics](https://launchpad.net/~kobuk-team/+archive/ubuntu/intel-graphics) (official Intel GPU compute PPA for Ubuntu)

### Phase 2: Python Virtual Environment

Creates `~/openvino-env` (configurable with `-v`), upgrades pip.

### Phase 3: OpenVINO

Installs `openvino` from [PyPI](https://pypi.org/project/openvino/) into the virtual environment.

### Phase 4: Intel NPU Driver

Skipped if `--skip-npu` is passed.

| | Ubuntu | Arch |
|-|--------|------|
| Source | `.deb` packages from [GitHub releases](https://github.com/intel/linux-npu-driver/releases) | AUR `intel-npu-driver-bin` |
| Packages | `intel-driver-compiler-npu`, `intel-fw-npu`, `intel-level-zero-npu` | `intel-npu-driver-bin` |
| Dependency | `libtbb12` | `onetbb` |

The Ubuntu script automatically fetches the latest release from the GitHub API.

### Phase 5: Kernel Module

Loads the `intel_vpu` kernel module and configures it to load at boot via `/etc/modules-load.d/intel-npu.conf`.

### Phase 6: User Permissions

Adds the current user to the `render` and `video` groups (required for GPU/NPU device access). Requires logout/login to take effect.

## Verification

Run verification on an existing installation:

```bash
./install-openvino-ubuntu --verify
```

Or use Python directly:

```bash
source ~/openvino-env/bin/activate
python3 -c "from openvino import Core; print(Core().available_devices)"
```

Expected output on a Hurrican/Performance system with all drivers installed:

```
['CPU', 'GPU', 'NPU']
```

## Uninstallation

```bash
./install-openvino-ubuntu --uninstall
```

This removes:
- The Python virtual environment (`~/openvino-env`)
- NPU driver packages (`intel-driver-compiler-npu`, `intel-fw-npu`, `intel-level-zero-npu`)
- NPU kernel module config (`/etc/modules-load.d/intel-npu.conf`)

It does **not** remove GPU compute packages or the Intel Graphics PPA. To remove those manually:

```bash
# Ubuntu
sudo add-apt-repository --remove ppa:kobuk-team/intel-graphics

# Arch
sudo pacman -R intel-compute-runtime level-zero-loader ocl-icd
```

## Logging

All installation output is logged to `/tmp/openvino-install-YYYYMMDD-HHMMSS.log`. If installation fails, check this file for details.

## Troubleshooting

### NPU not detected after installation

Reboot the system. The `intel_vpu` kernel module may need a fresh boot to initialize.

```bash
sudo reboot
```

After reboot, verify the device node exists:

```bash
ls -la /dev/accel/accel0
```

### GPU not detected in OpenVINO

Ensure you are in the `render` group (logout/login required after installation):

```bash
groups | grep render
```

On Ubuntu 24.04, ensure you have a kernel with Hurrican/Performance GPU support:

```bash
uname -r
# Should be 6.13+ (OEM or HWE kernel)
```

If using the stock GA kernel, install the HWE kernel:

```bash
sudo apt install linux-generic-hwe-24.04
```

### Permission denied on /dev/accel or /dev/dri

```bash
sudo usermod -aG render,video $USER
# Then logout and login again
```

### pip install fails behind a corporate proxy

Ensure proxy environment variables are set:

```bash
export http_proxy=http://your-proxy:port
export https_proxy=http://your-proxy:port
```

## External Sources

| Resource | URL |
|----------|-----|
| OpenVINO (pip) | https://pypi.org/project/openvino/ |
| Intel NPU Driver | https://github.com/intel/linux-npu-driver |
| Intel GPU PPA (Ubuntu) | https://launchpad.net/~kobuk-team/+archive/ubuntu/intel-graphics |
| Intel GPU Docs | https://dgpu-docs.intel.com/driver/client/overview.html |
| OpenVINO NPU Config | https://docs.openvino.ai/2025/get-started/install-openvino/configurations/configurations-intel-npu.html |
