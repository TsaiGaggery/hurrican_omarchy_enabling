#!/bin/bash
# =============================================================================
# MIPI Camera Build-from-Source Installer for Hurrican/Performance
# — Ubuntu Edition —
# =============================================================================
#
# Builds and installs the full Intel IPU7 hardware ISP camera stack with
# OV08X40 sensor from source on Ubuntu 24.04 LTS.  Two-phase script:
#
#   Phase 1 (pre-reboot):  Install deps, clone repos, apply patches,
#                          build kernel, install kernel via GRUB
#   Phase 2 (post-reboot): Build modules + userspace, deploy everything
#
# Usage:
#   sudo ./mipi_install_ubuntu.sh          # Phase 1 (first run) or Phase 2
#   sudo ./mipi_install_ubuntu.sh --reset  # Clear state and start over
#   sudo ./mipi_install_ubuntu.sh --phase2 # Force phase 2 (skip kernel check)
#
# The script automatically detects which phase to run based on saved state.
# =============================================================================

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"    # parent mipi-camera-ptl/ directory
PATCH_DIR="$PKG_DIR/patches"
SYSCONFIG_DIR="$PKG_DIR/system-config"
LIBCAMERA_DIR="$PKG_DIR/libcamera"

# Build directory — all repos cloned here
BUILD_DIR="$HOME/camera-build"

# State file to track progress across reboots
STATE_FILE="$HOME/.mipi-camera-install-state"

# Kernel — pinned to 6.19.0-rc6 (known-good commit for camera + audio)
KERNEL_REPO="https://github.com/thesofproject/linux.git"
KERNEL_COMMIT="d3af4d87e047012571254c0fbc43863e1be20856"

# All repos — pinned to known-good commits for reproducible builds
# Format: "url commit"
declare -A REPOS=(
    [ipu7-drivers]="https://github.com/intel/ipu7-drivers.git a88b19096a738d0708742a78d6540d6d4a3021ff"
    [vision-drivers]="https://github.com/intel/vision-drivers.git a8d772f261bc90376944956b7bfd49b325ffa2f2"
    [ipu7-camera-bins]="https://github.com/intel/ipu7-camera-bins.git 403c67db6b279dd02752f11db6a34552f31a3ac5"
    [ipu7-camera-hal]="https://github.com/intel/ipu7-camera-hal.git b1f6ebef12111fb5da0133b144d69dd9b001836c"
    [v4l2loopback]="https://github.com/umlaeute/v4l2loopback.git c3b20156af40efaff2baae920f5a7026697366b4"
)
ICAMERASRC_REPO="https://github.com/intel/icamerasrc.git"
ICAMERASRC_COMMIT="4fb31db76b618aae72184c59314b839dedb42689"

# Snapshot (GNOME Camera app) — 46.3 + always-copy patch for PipeWire buffer crash
SNAPSHOT_REPO="https://github.com/GNOME/snapshot.git"
SNAPSHOT_TAG="46.3"

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
    die "This script must be run as root (use sudo ./mipi_install_ubuntu.sh)"
fi

# Verify we're on Ubuntu/Debian
if [[ ! -f /etc/os-release ]] || ! grep -qi 'ubuntu\|debian' /etc/os-release; then
    die "This script is for Ubuntu/Debian. Use mipi_install.sh for Arch Linux."
fi

# Determine the real (non-root) user who invoked sudo
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
if [[ -z "$REAL_HOME" || "$REAL_HOME" == "/root" ]]; then
    log_warn "Could not determine non-root user home directory."
    log_warn "User services will need to be set up manually."
    REAL_HOME=""
fi

# Override BUILD_DIR to use the real user's home
BUILD_DIR="$REAL_HOME/camera-build"
STATE_FILE="$REAL_HOME/.mipi-camera-install-state"

# Handle --reset flag
if [[ "${1:-}" == "--reset" ]]; then
    rm -f "$STATE_FILE"
    log_info "State cleared. Run again to start from Phase 1."
    exit 0
fi

FORCE_PHASE2=0
if [[ "${1:-}" == "--phase2" ]]; then
    FORCE_PHASE2=1
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

get_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "fresh"
    fi
}

set_state() {
    echo "$1" > "$STATE_FILE"
    chown "$REAL_USER:$REAL_USER" "$STATE_FILE"
}

clone_pinned() {
    local dir="$1" url="$2" commit="$3"
    if [[ -d "$BUILD_DIR/$dir/.git" ]]; then
        log_info "  $dir — already cloned, skipping"
        return
    fi
    run_as_user mkdir -p "$BUILD_DIR/$dir"
    cd "$BUILD_DIR/$dir"
    run_as_user git init
    run_as_user git remote add origin "$url"
    run_as_user git fetch --depth 1 origin "$commit"
    run_as_user git checkout FETCH_HEAD
    log_info "  $dir — checked out ${commit:0:12}"
}

run_as_user() {
    runuser -u "$REAL_USER" -- "$@"
}

# ── Phase 1: Kernel Build (pre-reboot) ──────────────────────────────────────

phase1() {
    echo ""
    echo "================================================================"
    echo " MIPI Camera Installer (Ubuntu) — Phase 1: Kernel Build"
    echo "================================================================"
    echo ""

    # ── 1.1 Install packages ────────────────────────────────────────
    log_step "Step 1/7: Installing build + runtime packages"

    apt-get update

    local PACKAGES=(
        # Build dependencies
        build-essential bc perl python3 cpio libelf-dev dwarves zstd
        flex bison libssl-dev
        cmake libjsoncpp-dev libdrm-dev
        autoconf automake libtool pkg-config
        meson ninja-build rustc cargo
        # GStreamer (build + runtime)
        libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
        gstreamer1.0-plugins-base gstreamer1.0-plugins-good
        gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly
        gstreamer1.0-tools
        # PipeWire / WirePlumber (should already be installed on Ubuntu desktop)
        pipewire wireplumber
        # libcamera
        libcamera-dev libcamera-tools
        # Snapshot build deps
        libgtk-4-dev libadwaita-1-dev libx264-dev
        libgstreamer-plugins-bad1.0-dev gettext
        # VAAPI
        intel-media-va-driver
        # Misc build + runtime deps
        git curl gawk python3-pip libexpat1-dev libtinyxml2-dev libglib2.0-dev
        ffmpeg
    )
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}" 2>&1 | tail -20
    log_ok "Packages installed"

    # ── 1.2 Clone repositories ──────────────────────────────────────
    log_step "Step 2/7: Cloning source repositories"

    mkdir -p "$BUILD_DIR"
    chown "$REAL_USER:$REAL_USER" "$BUILD_DIR"

    # SOF kernel — shallow clone of pinned commit
    if [[ -d "$BUILD_DIR/sof-linux/.git" ]]; then
        log_info "  sof-linux — already cloned, skipping"
    else
        log_info "  sof-linux — cloning commit $KERNEL_COMMIT (this takes a while)..."
        run_as_user mkdir -p "$BUILD_DIR/sof-linux"
        cd "$BUILD_DIR/sof-linux"
        run_as_user git init
        run_as_user git remote add origin "$KERNEL_REPO"
        run_as_user git fetch --depth 1 origin "$KERNEL_COMMIT"
        run_as_user git checkout FETCH_HEAD
        log_info "  sof-linux — checked out $KERNEL_COMMIT"
    fi

    # Other repos — each entry is "url commit"
    for repo in "${!REPOS[@]}"; do
        local url commit
        read -r url commit <<< "${REPOS[$repo]}"
        clone_pinned "$repo" "$url" "$commit"
    done
    clone_pinned "icamerasrc" "$ICAMERASRC_REPO" "$ICAMERASRC_COMMIT"

    log_ok "All repositories cloned to $BUILD_DIR/"

    # ── 1.3 Apply kernel patches ────────────────────────────────────
    log_step "Step 3/7: Applying kernel patch (PSYS port)"

    cd "$BUILD_DIR/sof-linux"

    # Set git identity for am (needed if not already set)
    run_as_user git config user.email 2>/dev/null || run_as_user git config user.email "build@localhost"
    run_as_user git config user.name 2>/dev/null || run_as_user git config user.name "Build"

    # Check if patch is already applied
    if run_as_user git log --oneline -5 | grep -q "port PSYS"; then
        log_info "  PSYS patch already applied, skipping"
    else
        run_as_user git am "$PATCH_DIR"/0001-staging-ipu7-*.patch
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
    local PSYS_FILE="drivers/staging/media/ipu7/psys/ipu-psys.c"
    if grep -q 'isp->ipu7_dir' "$PSYS_FILE"; then
        sed -i 's/psys->adev->isp->ipu7_dir/NULL/' "$PSYS_FILE"
        sed -i 's/if (isp->ipu7_dir)/if (psys->debugfsdir)/' "$PSYS_FILE"
        log_info "  Fixed PSYS debugfs references for staging struct"
    fi

    # NOTE: Patch 0002 (ABI workaround) is NOT applied here.
    # Since we build kernel + modules from the same source, the ABI is
    # consistent and runtime PM works correctly without the workaround.

    log_ok "Kernel patch applied"

    # ── 1.4 Configure kernel ────────────────────────────────────────
    log_step "Step 4/7: Configuring kernel"

    cd "$BUILD_DIR/sof-linux"

    if [[ ! -f .config ]]; then
        # Ubuntu OEM kernels typically don't have /proc/config.gz,
        # but ship config in /boot/config-$(uname -r)
        local BOOT_CONFIG="/boot/config-$(uname -r)"
        if [[ -f "$BOOT_CONFIG" ]]; then
            cp "$BOOT_CONFIG" .config
            log_info "  Copied kernel config from $BOOT_CONFIG"
        elif [[ -f /proc/config.gz ]]; then
            zcat /proc/config.gz > .config
            log_info "  Extracted running kernel config from /proc/config.gz"
        else
            die "No kernel config found. Expected $BOOT_CONFIG or /proc/config.gz"
        fi
    else
        log_info "  Using existing .config"
    fi

    # Clear Ubuntu-specific signing keys (cert files don't exist in SOF tree)
    scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
    scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
    log_info "  Cleared Ubuntu certificate signing keys"

    # Enable camera-related configs
    scripts/config --enable STAGING_MEDIA
    scripts/config --module VIDEO_INTEL_IPU7
    scripts/config --module IPU_BRIDGE
    scripts/config --module VIDEO_OV08X40
    scripts/config --module USB_USBIO
    scripts/config --module I2C_USBIO
    scripts/config --module MEDIA_SUPPORT
    scripts/config --module V4L2_FWNODE
    scripts/config --enable VIDEO_V4L2_SUBDEV_API
    scripts/config --enable VIDEO_V4L2_I2C
    scripts/config --module V4L2_ASYNC
    scripts/config --module VIDEOBUF2_DMA_SG
    scripts/config --module VIDEOBUF2_V4L2

    # Enable SDCA class driver (required for CS42L45 audio codec on Hurrican/Performance)
    scripts/config --module SND_SOC_SDCA_CLASS

    make olddefconfig
    log_ok "Kernel configured"

    # ── 1.5 Build kernel ────────────────────────────────────────────
    log_step "Step 5/7: Building kernel (this takes 30-60 minutes)"

    cd "$BUILD_DIR/sof-linux"
    make -j"$(nproc)"
    log_ok "Kernel build complete"

    # ── 1.6 Install kernel ──────────────────────────────────────────
    log_step "Step 6/7: Installing kernel and modules"

    cd "$BUILD_DIR/sof-linux"
    local NEW_KVER
    NEW_KVER=$(make -s kernelrelease)

    make modules_install
    log_info "  Modules installed for $NEW_KVER"

    # Install kernel (vmlinuz, System.map) to /boot/ and generate initramfs.
    # On Ubuntu, `make install` runs /sbin/installkernel which:
    #   1. Copies vmlinuz-<ver> and System.map-<ver> to /boot/
    #   2. Runs update-initramfs to create /boot/initrd.img-<ver>
    make install
    log_info "  Kernel installed to /boot/"

    # Create /lib/modules/<version>/build symlink for out-of-tree module builds
    local BUILD_LINK="/lib/modules/$NEW_KVER/build"
    if [[ ! -e "$BUILD_LINK" ]]; then
        ln -sf "$BUILD_DIR/sof-linux" "$BUILD_LINK"
        log_info "  Created build symlink: $BUILD_LINK -> $BUILD_DIR/sof-linux"
    fi

    # Fix ownership — build ran as root but user needs write access for Phase 2
    chown -R "$REAL_USER:$REAL_USER" "$BUILD_DIR"

    log_ok "Kernel $NEW_KVER installed"

    # ── 1.7 Bootloader (GRUB) ───────────────────────────────────────
    log_step "Step 7/7: Configuring GRUB bootloader"

    local GRUB_CFG="/etc/default/grub"

    # Show GRUB menu so user can select kernel (OEM default is timeout=0, hidden)
    if grep -q '^GRUB_TIMEOUT=0' "$GRUB_CFG"; then
        sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' "$GRUB_CFG"
        log_info "  Set GRUB_TIMEOUT=5 (was 0)"
    fi
    if grep -q '^GRUB_TIMEOUT_STYLE=hidden' "$GRUB_CFG"; then
        sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' "$GRUB_CFG"
        log_info "  Set GRUB_TIMEOUT_STYLE=menu (was hidden)"
    fi

    # Set SOF kernel as default boot entry.
    # Ubuntu GRUB puts OEM-packaged kernels in the top-level "Ubuntu" entry
    # and custom-built kernels only in "Advanced options" submenu.
    # Use GRUB_DEFAULT="saved" + grub-set-default to point at the SOF kernel
    # inside the Advanced submenu: "gnulinux-advanced-...>gnulinux-<ver>-advanced-..."
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' "$GRUB_CFG"
    log_info "  Set GRUB_DEFAULT=saved"

    # Regenerate GRUB config first so the SOF entry exists
    update-grub

    # Find the SOF kernel's menuentry ID in grub.cfg
    # Escape regex special chars in kernel version (e.g. the '+' in 6.19.0-rc6+)
    local KVER_ESC="${NEW_KVER//+/\\+}"
    KVER_ESC="${KVER_ESC//./\\.}"
    local SOF_ENTRY_ID
    SOF_ENTRY_ID=$(grep -oP "gnulinux-${KVER_ESC}-advanced-[a-f0-9-]+" /boot/grub/grub.cfg | head -1) || true
    local ADVANCED_ID
    ADVANCED_ID=$(grep -oP "gnulinux-advanced-[a-f0-9-]+" /boot/grub/grub.cfg | head -1) || true

    if [[ -n "$SOF_ENTRY_ID" && -n "$ADVANCED_ID" ]]; then
        grub-set-default "${ADVANCED_ID}>${SOF_ENTRY_ID}"
        log_info "  Set default boot: ${ADVANCED_ID}>${SOF_ENTRY_ID}"
        log_ok "GRUB configured — SOF kernel ($NEW_KVER) is default boot entry"
    else
        log_warn "Could not find SOF kernel entry in grub.cfg"
        log_warn "Manually select '$NEW_KVER' from Advanced options in GRUB menu"
    fi

    # ── Save state and prompt reboot ────────────────────────────────
    set_state "phase1_complete"

    echo ""
    echo "================================================================"
    echo -e " ${GREEN}Phase 1 complete!${NC}"
    echo "================================================================"
    echo ""
    echo " Kernel $NEW_KVER has been built and installed."
    echo " GRUB has been updated — the SOF kernel is the default boot entry."
    echo ""
    echo " Next steps:"
    echo "   1. Reboot (SOF kernel will boot by default)"
    echo "   2. Run this script again: sudo ./mipi_install_ubuntu.sh"
    echo "      (Phase 2 will build modules and userspace)"
    echo ""
    read -rp "Reboot now? [y/N] " answer
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        log_info "Rebooting..."
        reboot
    fi
}

# ── Phase 2: Modules + Userspace (post-reboot) ─────────────────────────────

phase2() {
    echo ""
    echo "================================================================"
    echo " MIPI Camera Installer (Ubuntu) — Phase 2: Modules + Userspace"
    echo "================================================================"
    echo ""

    local KVER
    KVER="$(uname -r)"
    local MODDIR="/lib/modules/$KVER"
    log_info "Running kernel: $KVER"

    # Verify we're on the SOF kernel (unless forced)
    if [[ $FORCE_PHASE2 -eq 0 ]]; then
        if [[ ! -d "$BUILD_DIR/sof-linux" ]]; then
            die "Build directory not found: $BUILD_DIR/sof-linux"
        fi
        local EXPECTED_KVER
        EXPECTED_KVER=$(make -s -C "$BUILD_DIR/sof-linux" kernelrelease 2>/dev/null || echo "unknown")
        if [[ "$KVER" != "$EXPECTED_KVER" ]]; then
            log_warn "Running kernel ($KVER) doesn't match built kernel ($EXPECTED_KVER)"
            log_warn "If you already have the correct kernel, use: sudo ./mipi_install_ubuntu.sh --phase2"
            read -rp "Continue anyway? [y/N] " answer
            if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
                exit 0
            fi
        fi
    fi

    # Ensure build symlink exists
    if [[ ! -e "$MODDIR/build" ]]; then
        ln -sf "$BUILD_DIR/sof-linux" "$MODDIR/build"
        log_info "Created build symlink: $MODDIR/build"
    fi

    # ── 2.1 Remove conflicting out-of-tree IPU7 modules ────────────
    log_step "Step 1/15: Removing conflicting out-of-tree IPU7 modules"

    local OOT_DIR="$MODDIR/updates/drivers/media/pci/intel/ipu7"
    local removed=0
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

    # ── 2.2 Build IPU7 staging modules ──────────────────────────────
    log_step "Step 2/15: Building IPU7 staging modules (ISYS + PSYS)"

    cd "$BUILD_DIR/sof-linux"
    make M=drivers/staging/media/ipu7 clean 2>/dev/null || true
    make M=drivers/staging/media/ipu7 modules

    # Strip BTF sections (prevents pahole errors)
    objcopy --remove-section=.BTF drivers/staging/media/ipu7/intel-ipu7.ko 2>/dev/null || true
    objcopy --remove-section=.BTF drivers/staging/media/ipu7/intel-ipu7-isys.ko 2>/dev/null || true
    objcopy --remove-section=.BTF drivers/staging/media/ipu7/psys/intel-ipu7-psys.ko 2>/dev/null || true

    # Install (compress with zstd to match Ubuntu's module compression)
    local STAGING_DIR="$MODDIR/kernel/drivers/staging/media/ipu7"
    mkdir -p "$STAGING_DIR/psys"
    zstd -f drivers/staging/media/ipu7/intel-ipu7.ko -o "$STAGING_DIR/intel-ipu7.ko.zst"
    zstd -f drivers/staging/media/ipu7/intel-ipu7-isys.ko -o "$STAGING_DIR/intel-ipu7-isys.ko.zst"
    zstd -f drivers/staging/media/ipu7/psys/intel-ipu7-psys.ko -o "$STAGING_DIR/psys/intel-ipu7-psys.ko.zst"

    log_ok "IPU7 modules built and installed"

    # ── 2.3 Build CVS driver ────────────────────────────────────────
    log_step "Step 3/15: Building CVS driver (vision-drivers)"

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

    make KERNEL_SRC="$BUILD_DIR/sof-linux" clean 2>/dev/null || true
    make KERNEL_SRC="$BUILD_DIR/sof-linux"
    make KERNEL_SRC="$BUILD_DIR/sof-linux" modules_install

    log_ok "CVS driver built and installed"

    # ── 2.4 Install IPU7 firmware ───────────────────────────────────
    log_step "Step 4/15: Installing IPU7 firmware"

    mkdir -p /lib/firmware/intel/ipu
    cp -f "$BUILD_DIR"/ipu7-camera-bins/lib/firmware/intel/ipu/*.bin /lib/firmware/intel/ipu/
    log_ok "Firmware installed to /lib/firmware/intel/ipu/"

    # ── 2.5 Install proprietary libraries + headers ─────────────────
    log_step "Step 5/15: Installing proprietary libraries and headers"

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

    # ── 2.6 jsoncpp symlink ─────────────────────────────────────────
    # Ubuntu may have headers in /usr/include/json or /usr/include/jsoncpp/json
    if [[ -d /usr/include/json ]] && [[ ! -e /usr/include/jsoncpp/json ]]; then
        mkdir -p /usr/include/jsoncpp
        ln -sf /usr/include/json /usr/include/jsoncpp/json
        log_info "Created jsoncpp header symlink"
    fi

    # ── 2.7 Build Camera HAL (libcamhal) ────────────────────────────
    log_step "Step 6/15: Building Camera HAL (libcamhal)"

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

    # ── 2.8 Install HAL config and tuning files ─────────────────────
    log_step "Step 7/15: Installing HAL config and AIQB tuning files"

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

    # ── 2.9 Build icamerasrc ────────────────────────────────────────
    log_step "Step 8/15: Building icamerasrc GStreamer plugin"

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

    # ── 2.10 Build v4l2loopback ─────────────────────────────────────
    log_step "Step 9/15: Building v4l2loopback"

    cd "$BUILD_DIR/v4l2loopback"
    make clean 2>/dev/null || true
    make KDIR="$BUILD_DIR/sof-linux"

    mkdir -p "$MODDIR/updates"
    cp v4l2loopback.ko "$MODDIR/updates/"

    log_ok "v4l2loopback built and installed"

    # ── 2.11 Install system config ──────────────────────────────────
    log_step "Step 10/15: Installing system configuration"

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

    # WirePlumber rules — Ubuntu 24.04 uses WirePlumber 0.4.x (Lua config format)
    mkdir -p /etc/wireplumber/main.lua.d
    cp "$SYSCONFIG_DIR/wireplumber/51-hide-ipu7.lua" /etc/wireplumber/main.lua.d/
    cp "$SYSCONFIG_DIR/wireplumber/51-disable-libcamera.lua" /etc/wireplumber/main.lua.d/
    log_info "  Installed WirePlumber Lua rules (0.4.x format)"

    log_ok "System configuration installed"

    # ── 2.12 Install user service + camera wrapper ──────────────────
    log_step "Step 11/15: Installing camera-feed service and camera-session wrapper"

    # Install ffmpeg-based camera-feed wrapper (workaround for GStreamer 1.24
    # v4l2sink MMAP buffer bug with v4l2loopback — use ffmpeg as V4L2 writer)
    install -m 755 "$SYSCONFIG_DIR/camera-feed-ffmpeg" /usr/local/bin/camera-feed-ffmpeg
    log_info "  Installed camera-feed-ffmpeg wrapper"

    # Install camera-feed service with ffmpeg bridge instead of v4l2sink
    if [[ -n "$REAL_HOME" ]]; then
        local USER_SERVICE_DIR="$REAL_HOME/.config/systemd/user"
        mkdir -p "$USER_SERVICE_DIR"
        cp "$SYSCONFIG_DIR/systemd/camera-feed.service" "$USER_SERVICE_DIR/"
        # Replace v4l2sink pipeline with ffmpeg bridge
        sed -i 's|^ExecStart=.*|ExecStart=/usr/local/bin/camera-feed-ffmpeg|' "$USER_SERVICE_DIR/camera-feed.service"
        sed -i '/^Environment=GST_PLUGIN_PATH/d' "$USER_SERVICE_DIR/camera-feed.service"
        chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/systemd"
        log_info "  Installed camera-feed.service (ffmpeg bridge) for user $REAL_USER"

        if command -v runuser &>/dev/null; then
            run_as_user systemctl --user daemon-reload 2>/dev/null || true
            run_as_user systemctl --user disable camera-feed.service 2>/dev/null || true
        fi
    fi

    # /etc/skel for new users
    mkdir -p /etc/skel/.config/systemd/user
    cp "$SYSCONFIG_DIR/systemd/camera-feed.service" /etc/skel/.config/systemd/user/
    sed -i 's|^ExecStart=.*|ExecStart=/usr/local/bin/camera-feed-ffmpeg|' /etc/skel/.config/systemd/user/camera-feed.service
    sed -i '/^Environment=GST_PLUGIN_PATH/d' /etc/skel/.config/systemd/user/camera-feed.service

    # camera-session wrapper
    install -m 755 "$SYSCONFIG_DIR/camera-session" /usr/local/bin/camera-session
    log_info "  Installed camera-session wrapper"

    log_ok "Camera-feed service and wrapper installed"

    # ── 2.13 Build and install Snapshot 46.3 ─────────────────────────
    log_step "Step 12/15: Building GNOME Snapshot 46.3 (Camera app)"

    # Ubuntu 24.04 ships Snapshot 46.2 which crashes on GStreamer 1.24 due
    # to a camerabin/multiqueue use-after-free in gst_video_frame_copy_plane.
    # Snapshot 46.3 + always-copy patch: forces pipewiresrc to copy buffers to
    # system memory, preventing use-after-free when PipeWire recycles fd-backed
    # buffers while GStreamer's videofilter is still copying from them.
    # Snapshot 47+ requires libadwaita >= 1.6 (Ubuntu has 1.5) so 46.3 is
    # the newest compatible version.
    log_info "  Cloning Snapshot ${SNAPSHOT_TAG}..."
    if [[ -d "$BUILD_DIR/snapshot/.git" ]]; then
        log_info "  snapshot — already cloned, skipping"
    else
        run_as_user git clone --depth 1 --branch "$SNAPSHOT_TAG" \
            "$SNAPSHOT_REPO" "$BUILD_DIR/snapshot"
    fi

    # Patch: set always-copy=true on pipewiresrc to prevent buffer use-after-free
    cd "$BUILD_DIR/snapshot"
    if ! grep -q 'always-copy' aperture/src/camera.rs 2>/dev/null; then
        sed -i '/set_property("client-name"/a\        element.set_property("always-copy", true);' \
            aperture/src/camera.rs
        log_info "  Applied always-copy patch to aperture/src/camera.rs"
    fi

    run_as_user meson setup build --prefix=/usr --buildtype=release -Dprofile=default 2>&1 | tail -5
    run_as_user meson compile -C build 2>&1 | tail -5
    meson install -C build 2>&1 | tail -5
    log_info "  Installed Snapshot ${SNAPSHOT_TAG} (with always-copy patch)"

    # Pin to prevent apt upgrade overwriting our build
    apt-mark hold gnome-snapshot 2>/dev/null || true
    log_info "  Pinned gnome-snapshot package (apt-mark hold)"

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

    # Set VP8 video recording bitrate to 20 Mbps (default 256 kbps is too low for 4K)
    local VP8_PRESET="/usr/share/gstreamer-1.0/presets/GstVP8Enc.prs"
    if [[ -f "$VP8_PRESET" ]]; then
        if ! grep -q 'target-bitrate' "$VP8_PRESET"; then
            sed -i '/^\[Profile Realtime\]/,/^\[/{/^lag-in-frames=/a\target-bitrate=20000000
}' "$VP8_PRESET"
            log_info "  Set VP8 recording bitrate to 20 Mbps in GstVP8Enc preset"
        fi
    else
        mkdir -p /usr/share/gstreamer-1.0/presets
        cat > "$VP8_PRESET" << 'VP8EOF'
[_presets_]
version=0.10
element-name=GstVP8Enc

[Profile Realtime]
deadline=1
cpu-used=4
lag-in-frames=0
target-bitrate=20000000
VP8EOF
        log_info "  Created VP8 preset with 20 Mbps recording bitrate"
    fi

    # ── 2.14 Device permissions + workarounds ───────────────────────
    log_step "Step 13/15: Setting up device permissions and workarounds"

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

    # Note: Snapshot 46.3 does not have enable-hardware-encoding gsettings key.
    # VAAPI (vah264enc) is not available on Ubuntu 24.04 anyway
    # (intel-media-va-driver 24.1.0 lacks GPU support for this platform).

    log_ok "Permissions and workarounds applied"

    # ── 2.15 Finalize ──────────────────────────────────────────────
    log_step "Step 14/15: Finalizing"

    depmod -a
    log_info "  Module dependencies rebuilt"

    ldconfig
    log_info "  Library cache updated"

    systemctl daemon-reload
    log_info "  systemd reloaded"

    # ── Done ────────────────────────────────────────────────────────
    log_step "Step 15/15: Cleanup"

    rm -f "$STATE_FILE"
    log_info "  State file removed"

    echo ""
    echo "================================================================"
    echo -e " ${GREEN}Installation complete!${NC}"
    echo "================================================================"
    echo ""
    echo " Installed components (all built from source):"
    echo "   - SOF kernel with IPU7 ISYS + PSYS (built from source)"
    echo "   - Intel CVS driver (rgbcamera_pwrup_host=0)"
    echo "   - IPU7 firmware (ipu7ptl_fw.bin)"
    echo "   - Camera HAL (libcamhal) + AIQB tuning"
    echo "   - icamerasrc GStreamer plugin"
    echo "   - v4l2loopback (built against SOF kernel)"
    echo "   - Snapshot 46.3 (built from source, pinned via apt-mark hold)"
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
}

# ── Main: determine which phase to run ──────────────────────────────────────

STATE="$(get_state)"

case "$STATE" in
    fresh)
        if [[ $FORCE_PHASE2 -eq 1 ]]; then
            phase2
        else
            phase1
        fi
        ;;
    phase1_complete)
        phase2
        ;;
    *)
        die "Unknown state: $STATE — use --reset to start over"
        ;;
esac
