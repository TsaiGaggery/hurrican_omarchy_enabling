#!/bin/bash
# =============================================================================
# MIPI Camera Build-from-Source Installer for Hurrican/Performance
# — Omarchy 6.19.6 Edition (pre-built kernel) —
# =============================================================================
#
# Builds and installs the full Intel IPU7 hardware ISP camera stack with
# OV08X40 sensor from source against a pre-built 6.19.6 kernel.
#
# Prerequisites:
#   - Kernel 6.19.6 already built at ~/kernel-build/linux-6.19.6
#   - Kernel already installed and booted (with SDCA backport patches)
#
# Unlike mipi_install.sh (two-phase), this is a single-phase script:
# no kernel build, no reboot needed mid-install.
#
# Usage:
#   sudo ./mipi_install_omarchy_6196.sh          # Run installer
#   sudo ./mipi_install_omarchy_6196.sh --force   # Skip kernel version check
#
# =============================================================================

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"    # parent mipi-camera-ptl/ directory
PATCH_DIR="$PKG_DIR/patches"
SYSCONFIG_DIR="$PKG_DIR/system-config"
LIBCAMERA_DIR="$PKG_DIR/libcamera"

# Pre-built kernel source tree
KERNEL_SRC="$HOME/kernel-build/linux-6.19.6"

# Build directory — camera repos cloned here
BUILD_DIR="$HOME/camera-build"

# All repos — pinned to known-good commits for reproducible builds
declare -A REPOS=(
    [ipu7-drivers]="https://github.com/intel/ipu7-drivers.git a88b19096a738d0708742a78d6540d6d4a3021ff"
    [vision-drivers]="https://github.com/intel/vision-drivers.git a8d772f261bc90376944956b7bfd49b325ffa2f2"
    [ipu7-camera-bins]="https://github.com/intel/ipu7-camera-bins.git 403c67db6b279dd02752f11db6a34552f31a3ac5"
    [ipu7-camera-hal]="https://github.com/intel/ipu7-camera-hal.git b1f6ebef12111fb5da0133b144d69dd9b001836c"
    [v4l2loopback]="https://github.com/umlaeute/v4l2loopback.git c3b20156af40efaff2baae920f5a7026697366b4"
)
ICAMERASRC_REPO="https://github.com/intel/icamerasrc.git"
ICAMERASRC_COMMIT="4fb31db76b618aae72184c59314b839dedb42689"
SNAPSHOT_REPO="https://github.com/GNOME/snapshot.git"
SNAPSHOT_TAG="50.rc"

# ── Colors and logging ──────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

die() { log_error "$@"; exit 1; }

# ── Pre-flight ──────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo ./mipi_install_omarchy_6196.sh)"
fi

# Determine the real (non-root) user who invoked sudo
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
if [[ -z "$REAL_HOME" || "$REAL_HOME" == "/root" ]]; then
    log_warn "Could not determine non-root user home directory."
    log_warn "User services will need to be set up manually."
    REAL_HOME=""
fi

# Override paths to use the real user's home
KERNEL_SRC="$REAL_HOME/kernel-build/linux-6.19.6"
BUILD_DIR="$REAL_HOME/camera-build"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
fi

# Verify kernel source tree exists
if [[ ! -d "$KERNEL_SRC" ]]; then
    die "Kernel source not found: $KERNEL_SRC
    This script expects kernel 6.19.6 to be pre-built at that location.
    Use mipi_install.sh instead if you need to build the kernel from scratch."
fi

# Verify patches directory exists
if [[ ! -d "$PATCH_DIR" ]]; then
    die "Patches directory not found: $PATCH_DIR"
fi
for p in 0001 0003 0004; do
    if ! ls "$PATCH_DIR"/${p}-*.patch &>/dev/null; then
        die "Missing patch: $PATCH_DIR/${p}-*.patch"
    fi
done

# ── Helper functions ────────────────────────────────────────────────────────

clone_pinned() {
    local dir="$1" url="$2" commit="$3"
    if [[ -d "$BUILD_DIR/$dir/.git" ]]; then
        log_info "  $dir — already cloned, skipping"
        return
    fi
    mkdir -p "$BUILD_DIR/$dir"
    cd "$BUILD_DIR/$dir"
    git init
    git remote add origin "$url"
    git fetch --depth 1 origin "$commit"
    git checkout FETCH_HEAD
    log_info "  $dir — checked out ${commit:0:12}"
}

run_as_user() {
    runuser -u "$REAL_USER" -- "$@"
}

# ── Main install ─────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo " MIPI Camera Installer — Omarchy 6.19.6 (pre-built kernel)"
echo "================================================================"
echo ""

KVER="$(uname -r)"
log_info "Running kernel: $KVER"
log_info "Kernel source:  $KERNEL_SRC"

# Verify running kernel matches source tree (unless --force)
if [[ $FORCE -eq 0 ]]; then
    EXPECTED_KVER=$(make -s -C "$KERNEL_SRC" kernelrelease 2>/dev/null || echo "unknown")
    if [[ "$KVER" != "$EXPECTED_KVER" ]]; then
        log_warn "Running kernel ($KVER) doesn't match kernel source ($EXPECTED_KVER)"
        log_warn "Use --force to skip this check"
        read -rp "Continue anyway? [y/N] " answer
        if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            exit 0
        fi
    fi
fi

MODDIR="/lib/modules/$KVER"

# ── Step 1: Install packages ──────────────────────────────────────────────

log_step "Step 1/18: Installing build + runtime packages"

PACKAGES=(
    # Build dependencies
    base-devel bc perl python cpio libelf pahole zstd flex bison openssl
    cmake jsoncpp libdrm
    autoconf automake libtool pkgconf
    meson ninja rust
    # Runtime
    gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly
    pipewire pipewire-pulse pipewire-alsa wireplumber
    libcamera libcamera-tools gst-plugin-libcamera pipewire-libcamera
    snapshot glycin-gtk4
    intel-media-driver gst-plugin-va
)
pacman -S --needed --noconfirm "${PACKAGES[@]}" 2>&1 | tail -10
log_ok "Packages installed"

# ── Step 2: Clone camera repositories ─────────────────────────────────────

log_step "Step 2/18: Cloning camera source repositories"

mkdir -p "$BUILD_DIR"
chown "$REAL_USER:$REAL_USER" "$BUILD_DIR"

for repo in "${!REPOS[@]}"; do
    read -r url commit <<< "${REPOS[$repo]}"
    clone_pinned "$repo" "$url" "$commit"
done
clone_pinned "icamerasrc" "$ICAMERASRC_REPO" "$ICAMERASRC_COMMIT"

chown -R "$REAL_USER:$REAL_USER" "$BUILD_DIR"
log_ok "All camera repositories cloned to $BUILD_DIR/"

# ── Step 3: Apply PSYS patch to kernel source ─────────────────────────────

log_step "Step 3/18: Applying kernel patch (PSYS port) to $KERNEL_SRC"

cd "$KERNEL_SRC"

# Set git identity for am (needed if not already set)
git config user.email 2>/dev/null || git config user.email "build@localhost"
git config user.name 2>/dev/null || git config user.name "Build"

# Check if patch is already applied
if git log --oneline -20 | grep -q "port PSYS"; then
    log_info "  PSYS patch already applied, skipping"
else
    git am "$PATCH_DIR"/0001-staging-ipu7-*.patch
    log_info "  Applied: PSYS port from ipu7-drivers"
fi

# Copy UAPI header that PSYS source needs (not included in staging tree)
if [[ ! -f include/uapi/linux/ipu7-psys.h ]]; then
    cp "$BUILD_DIR/ipu7-drivers/include/uapi/linux/ipu7-psys.h" \
       include/uapi/linux/ipu7-psys.h
    log_info "  Copied PSYS UAPI header from ipu7-drivers"
fi

# Fix PSYS debugfs: out-of-tree code references isp->ipu7_dir which
# doesn't exist in the staging struct ipu7_device. Replace with NULL
# so debugfs creates a top-level "psys" dir instead of nesting.
PSYS_FILE="drivers/staging/media/ipu7/psys/ipu-psys.c"
if grep -q 'isp->ipu7_dir' "$PSYS_FILE"; then
    sed -i 's/psys->adev->isp->ipu7_dir/NULL/' "$PSYS_FILE"
    sed -i 's/if (isp->ipu7_dir)/if (psys->debugfsdir)/' "$PSYS_FILE"
    log_info "  Fixed PSYS debugfs references for staging struct"
fi

log_ok "Kernel patch applied"

# ── Step 4: Ensure build symlink ───────────────────────────────────────────

log_step "Step 4/18: Ensuring module build symlink"

if [[ ! -e "$MODDIR/build" ]]; then
    ln -sf "$KERNEL_SRC" "$MODDIR/build"
    log_info "Created build symlink: $MODDIR/build -> $KERNEL_SRC"
else
    log_info "Build symlink already exists: $(readlink -f "$MODDIR/build")"
fi

# ── Step 5: Remove conflicting out-of-tree IPU7 modules ───────────────────

log_step "Step 5/18: Removing conflicting out-of-tree IPU7 modules"

OOT_DIR="$MODDIR/updates/drivers/media/pci/intel/ipu7"
removed=0
for f in "$OOT_DIR/intel-ipu7.ko"* \
         "$OOT_DIR/intel-ipu7-isys.ko"* \
         "$OOT_DIR/psys/intel-ipu7-psys.ko"*; do
    if [[ -f "$f" ]]; then
        rm -f "$f"
        log_info "  Removed: $f"
        removed=1
    fi
done
[[ $removed -eq 0 ]] && log_ok "No conflicting modules found" || log_ok "Conflicting modules removed"

# ── Step 6: Build IPU7 staging modules ─────────────────────────────────────

log_step "Step 6/18: Building IPU7 staging modules (ISYS + PSYS)"

cd "$KERNEL_SRC"
make M=drivers/staging/media/ipu7 clean 2>/dev/null || true
make M=drivers/staging/media/ipu7 modules

# Strip BTF sections (prevents pahole errors on Arch)
objcopy --remove-section=.BTF drivers/staging/media/ipu7/intel-ipu7.ko 2>/dev/null || true
objcopy --remove-section=.BTF drivers/staging/media/ipu7/intel-ipu7-isys.ko 2>/dev/null || true
objcopy --remove-section=.BTF drivers/staging/media/ipu7/psys/intel-ipu7-psys.ko 2>/dev/null || true

# Install (compress with zstd)
STAGING_DIR="$MODDIR/kernel/drivers/staging/media/ipu7"
mkdir -p "$STAGING_DIR/psys"
zstd -f drivers/staging/media/ipu7/intel-ipu7.ko -o "$STAGING_DIR/intel-ipu7.ko.zst"
zstd -f drivers/staging/media/ipu7/intel-ipu7-isys.ko -o "$STAGING_DIR/intel-ipu7-isys.ko.zst"
zstd -f drivers/staging/media/ipu7/psys/intel-ipu7-psys.ko -o "$STAGING_DIR/psys/intel-ipu7-psys.ko.zst"

log_ok "IPU7 modules built and installed"

# ── Step 7: Build CVS driver ──────────────────────────────────────────────

log_step "Step 7/18: Building CVS driver (vision-drivers)"

cd "$BUILD_DIR/vision-drivers"

# Set git identity for am
git config user.email 2>/dev/null || git config user.email "build@localhost"
git config user.name 2>/dev/null || git config user.name "Build"

# Apply CVS patch if not already applied
if git log --oneline -1 | grep -q "rgbcamera_pwrup_host"; then
    log_info "  CVS patch already applied, skipping"
else
    git am "$PATCH_DIR"/0003-icvs-*.patch
    log_info "  Applied: rgbcamera_pwrup_host=0 fix"
fi

make KERNEL_SRC="$KERNEL_SRC" clean 2>/dev/null || true
make KERNEL_SRC="$KERNEL_SRC"
make KERNEL_SRC="$KERNEL_SRC" modules_install

log_ok "CVS driver built and installed"

# ── Step 8: Install IPU7 firmware ──────────────────────────────────────────

log_step "Step 8/18: Installing IPU7 firmware"

mkdir -p /lib/firmware/intel/ipu
cp -f "$BUILD_DIR"/ipu7-camera-bins/lib/firmware/intel/ipu/*.bin /lib/firmware/intel/ipu/
log_ok "Firmware installed to /lib/firmware/intel/ipu/"

# ── Step 9: Install proprietary libraries + headers ────────────────────────

log_step "Step 9/18: Installing proprietary libraries and headers"

cd "$BUILD_DIR/ipu7-camera-bins"

# Libraries (preserve symlinks)
cp -P lib/lib* /usr/lib/

# Headers
mkdir -p /usr/include/ipu7
cp -r include/* /usr/include/

# pkg-config
mkdir -p /usr/lib/pkgconfig
cp -r lib/pkgconfig/* /usr/lib/pkgconfig/

ldconfig
log_ok "Proprietary libraries and headers installed"

# ── Step 10: jsoncpp symlink (Arch quirk) ──────────────────────────────────

if [[ -d /usr/include/json ]] && [[ ! -e /usr/include/jsoncpp/json ]]; then
    mkdir -p /usr/include/jsoncpp
    ln -sf /usr/include/json /usr/include/jsoncpp/json
    log_info "Created jsoncpp header symlink"
fi

# ── Step 11: Build Camera HAL (libcamhal) ──────────────────────────────────

log_step "Step 11/18: Building Camera HAL (libcamhal)"

cd "$BUILD_DIR/ipu7-camera-hal"
rm -rf build
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_CAMHAL_ADAPTOR=ON \
    -DBUILD_CAMHAL_PLUGIN=ON \
    -DIPU_VERSIONS="ipu75xa" \
    -DUSE_STATIC_GRAPH=ON \
    -DUSE_STATIC_GRAPH_AUTOGEN=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    ..
make -j"$(nproc)"
make install
ldconfig

log_ok "Camera HAL built and installed"

# ── Step 12: Install HAL config and tuning files ───────────────────────────

log_step "Step 12/18: Installing HAL config and AIQB tuning files"

cd "$BUILD_DIR/ipu7-camera-hal"

# Main HAL config + AIQB tuning
mkdir -p /usr/share/defaults/etc/camera
cp config/linux/ipu75xa/libcamhal_configs.json /usr/share/defaults/etc/camera/
cp config/linux/ipu75xa/*.aiqb /usr/share/defaults/etc/camera/

# Graph configuration binaries
mkdir -p /etc/camera/ipu75xa/gcss
cp config/linux/ipu75xa/gcss/*.bin /etc/camera/ipu75xa/gcss/

# Per-sensor config JSONs
mkdir -p /etc/camera/ipu75xa/sensors
cp config/linux/ipu75xa/sensors/*.json /etc/camera/ipu75xa/sensors/

# Pipeline scheduler and PnP profiles
cp config/linux/ipu75xa/pipe_scheduler_profiles.json /etc/camera/ipu75xa/
cp config/linux/ipu75xa/pnp_profiles.json /etc/camera/ipu75xa/

log_ok "HAL config and tuning files installed"

# ── Step 13: Build icamerasrc ──────────────────────────────────────────────

log_step "Step 13/18: Building icamerasrc GStreamer plugin"

cd "$BUILD_DIR/icamerasrc"
export CHROME_SLIM_CAMHAL=ON
if [[ ! -f configure ]]; then
    ./autogen.sh
fi
./configure --prefix=/usr
make -j"$(nproc)"
make install
ldconfig

log_ok "icamerasrc built and installed"

# ── Step 14: Build v4l2loopback ────────────────────────────────────────────

log_step "Step 14/18: Building v4l2loopback"

cd "$BUILD_DIR/v4l2loopback"
make clean 2>/dev/null || true
make KDIR="$KERNEL_SRC"

mkdir -p "$MODDIR/updates"
cp v4l2loopback.ko "$MODDIR/updates/"

log_ok "v4l2loopback built and installed"

# ── Step 15: Install system config ─────────────────────────────────────────

log_step "Step 15/18: Installing system configuration"

# modprobe configs
cp "$SYSCONFIG_DIR/modprobe.d/camera-deps.conf" /etc/modprobe.d/
cp "$SYSCONFIG_DIR/modprobe.d/v4l2loopback.conf" /etc/modprobe.d/
log_info "  Installed modprobe configs"

# modules-load
mkdir -p /etc/modules-load.d
cp "$SYSCONFIG_DIR/modules-load.d/v4l2loopback.conf" /etc/modules-load.d/
log_info "  Installed v4l2loopback auto-load config"

# camera-init systemd service (system-level)
cp "$SYSCONFIG_DIR/systemd/camera-init.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable camera-init.service
log_info "  Installed and enabled camera-init.service"

# WirePlumber rules (.conf format for Omarchy)
mkdir -p /etc/wireplumber/wireplumber.conf.d
cp "$SYSCONFIG_DIR/wireplumber/hide-ipu7-v4l2.conf" /etc/wireplumber/wireplumber.conf.d/
cp "$SYSCONFIG_DIR/wireplumber/disable-libcamera.conf" /etc/wireplumber/wireplumber.conf.d/
log_info "  Installed WirePlumber rules"

log_ok "System configuration installed"

# ── Step 16: Install user service + camera wrapper ─────────────────────────

log_step "Step 16/18: Installing camera-feed service and camera-session wrapper"

if [[ -n "$REAL_HOME" ]]; then
    USER_SERVICE_DIR="$REAL_HOME/.config/systemd/user"
    mkdir -p "$USER_SERVICE_DIR"
    cp "$SYSCONFIG_DIR/systemd/camera-feed.service" "$USER_SERVICE_DIR/"
    chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/systemd"
    log_info "  Installed camera-feed.service for user $REAL_USER"

    if command -v runuser &>/dev/null; then
        run_as_user systemctl --user daemon-reload 2>/dev/null || true
        run_as_user systemctl --user disable camera-feed.service 2>/dev/null || true
    fi
fi

# /etc/skel for new users
mkdir -p /etc/skel/.config/systemd/user
cp "$SYSCONFIG_DIR/systemd/camera-feed.service" /etc/skel/.config/systemd/user/

# camera-session wrapper
install -m 755 "$SYSCONFIG_DIR/camera-session" /usr/local/bin/camera-session
log_info "  Installed camera-session wrapper"

log_ok "Camera-feed service and wrapper installed"

# ── Step 17: Build and install modified Snapshot ───────────────────────────

log_step "Step 17/18: Building modified GNOME Snapshot (higher video quality)"

SNAPSHOT_BUILD_DIR="/tmp/snapshot"
if [[ -d "$SNAPSHOT_BUILD_DIR/.git" ]]; then
    log_info "  Snapshot source already cloned in /tmp/snapshot"
else
    rm -rf "$SNAPSHOT_BUILD_DIR"
    git clone "$SNAPSHOT_REPO" "$SNAPSHOT_BUILD_DIR"
fi

cd "$SNAPSHOT_BUILD_DIR"
git checkout "$SNAPSHOT_TAG" 2>/dev/null || true

# Set git identity for am
git config user.email 2>/dev/null || git config user.email "build@localhost"
git config user.name 2>/dev/null || git config user.name "Build"

# Apply patch if not already applied
if git log --oneline -1 | grep -q "video bitrate"; then
    log_info "  Snapshot patch already applied, skipping"
else
    # Ensure we're on a branch for git am
    git checkout -b ptl-mods 2>/dev/null || git checkout ptl-mods 2>/dev/null || true
    git am "$PATCH_DIR"/0004-snapshot-*.patch
    log_info "  Applied: video quality patch (12 Mbps + medium preset)"
fi

# Build
rm -rf build
meson setup build --prefix=/usr --buildtype=release -Dprofile=default
meson compile -C build
meson install -C build

# Pin in pacman.conf to prevent overwrite
if ! grep -q 'IgnorePkg.*snapshot' /etc/pacman.conf; then
    sed -i '/^\[options\]/a IgnorePkg = snapshot' /etc/pacman.conf
    log_info "  Pinned snapshot package in pacman.conf"
fi

log_ok "Modified Snapshot built and installed"

# Modify Snapshot desktop file to use camera-session wrapper
# (must be AFTER Snapshot build — meson install overwrites the desktop file)
if [[ -f /usr/share/applications/org.gnome.Snapshot.desktop ]]; then
    sed -i 's|^Exec=snapshot|Exec=camera-session|' \
        /usr/share/applications/org.gnome.Snapshot.desktop
    update-desktop-database /usr/share/applications/ 2>/dev/null || true
    log_info "  Modified Snapshot desktop file to use camera-session"
fi

# Modify D-Bus service file
if [[ -f /usr/share/dbus-1/services/org.gnome.Snapshot.service ]]; then
    sed -i 's|Exec=/usr/bin/snapshot|Exec=/usr/local/bin/camera-session|' \
        /usr/share/dbus-1/services/org.gnome.Snapshot.service
    log_info "  Modified Snapshot D-Bus service to use camera-session"
fi

# ── Step 18: Device permissions + workarounds + finalize ───────────────────

log_step "Step 18/18: Device permissions, workarounds, and finalization"

# Add user to video group
if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
    usermod -aG video "$REAL_USER" 2>/dev/null || true
    log_info "  Added $REAL_USER to video group"
fi

# udev rule for IPU7 PSYS device
cat > /etc/udev/rules.d/90-ipu7-psys.rules << 'UDEVEOF'
KERNEL=="ipu7-psys0", MODE="0666", SYMLINK+="ipu-psys0"
UDEVEOF
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true
log_info "  Installed udev rule for IPU7 PSYS device"

# Create /run/camera (aiqd cache — suppresses non-fatal HAL warning)
mkdir -p /run/camera
chmod 777 /run/camera

# tmpfiles.d so it persists across reboots
mkdir -p /etc/tmpfiles.d
echo "d /run/camera 0777 root root -" > /etc/tmpfiles.d/camera.conf
log_info "  Created /run/camera cache directory"

# libcamera tuning file (software ISP fallback)
mkdir -p /usr/share/libcamera/ipa/simple
if [[ -f "$LIBCAMERA_DIR/ov08x40.yaml" ]]; then
    cp "$LIBCAMERA_DIR/ov08x40.yaml" /usr/share/libcamera/ipa/simple/
else
    cat > /usr/share/libcamera/ipa/simple/ov08x40.yaml << 'YAMLEOF'
# SPDX-License-Identifier: CC0-1.0
# Tuning file for OmniVision OV08X40
# Used by libcamera simple pipeline handler software ISP
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
      r: 16
      gr: 16
      gb: 16
      b: 16
  - Awb:
  - Adjust:
  - Agc:
...
YAMLEOF
fi
log_info "  Installed libcamera tuning file"

# Disable VAAPI hardware encoding (vah264enc green line bug)
if [[ -n "$REAL_HOME" ]] && command -v runuser &>/dev/null; then
    run_as_user gsettings set org.gnome.Snapshot enable-hardware-encoding false 2>/dev/null || true
    log_info "  Disabled hardware encoding in Snapshot (VAAPI workaround)"
fi

# Finalize
depmod -a
log_info "  Module dependencies rebuilt"

ldconfig
log_info "  Library cache updated"

systemctl daemon-reload
log_info "  systemd reloaded"

log_ok "Permissions and workarounds applied"

# ── Done ───────────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo -e " ${GREEN}Installation complete!${NC}"
echo "================================================================"
echo ""
echo " Installed components (all built from source):"
echo "   - IPU7 ISYS + PSYS staging modules (against kernel $KVER)"
echo "   - Intel CVS driver (rgbcamera_pwrup_host=0)"
echo "   - IPU7 firmware (ipu7ptl_fw.bin)"
echo "   - Camera HAL (libcamhal) + AIQB tuning"
echo "   - icamerasrc GStreamer plugin"
echo "   - v4l2loopback (against kernel $KVER)"
echo "   - Modified Snapshot (12 Mbps video, pinned in pacman)"
echo "   - WirePlumber rules + systemd services + camera-session wrapper"
echo ""
echo " Verify with:"
echo "   sudo dmesg | grep -i 'ipu7\|cvs\|ov08x'"
echo "   ls /dev/video* /dev/ipu*"
echo "   gst-inspect-1.0 icamerasrc"
echo "   systemctl status camera-init.service"
echo ""
echo " Open Camera (Snapshot) from the app launcher to test."
echo " The camera feed starts on-demand — LED is only on when Camera is open."
echo ""
log_warn "A reboot is recommended for all changes to take effect."
echo ""
read -rp "Reboot now? [y/N] " answer
if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
    log_info "Rebooting..."
    reboot
fi
