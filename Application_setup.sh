#!/bin/bash

# =============================================================================
# Ubuntu Server Software Installation Script  –  Multi-Architecture Edition
# Installs: Chrome, VLC, VSCode, SSH (with service), Mosquitto (with service),
#           XRDP, SSHPass, FFplay, DockStation, TeamViewer
#
# Supported architectures: amd64 (x86_64) | arm64 (aarch64) | armhf (armv7l)
# Tested on: Ubuntu 20.04 / 22.04 / 24.04 LTS
# Run as:    sudo bash install_software.sh
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
log()     { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
skip()    { echo -e "${YELLOW}[SKIP]${NC}  $*"; }

require_root() {
    [[ $EUID -eq 0 ]] || error "Please run with sudo: sudo bash $0"
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

download_deb() {
    local url="$1" dest="$2"
    log "Downloading $(basename "$dest") …"
    wget -q --show-progress --retry-connrefused --tries=5 --timeout=60 \
         -O "$dest" "$url" || { warn "Download failed: $url"; return 1; }
}

install_deb() {
    local deb="$1"
    DEBIAN_FRONTEND=noninteractive dpkg -i "$deb" 2>/dev/null || apt-get install -f -y
}

# ── Architecture Detection ────────────────────────────────────────────────────
detect_arch() {
    ARCH=$(dpkg --print-architecture)          # amd64 | arm64 | armhf
    MACHINE=$(uname -m)                        # x86_64 | aarch64 | armv7l

    case "$ARCH" in
        amd64)   ARCH_ALT="x86_64"  ;;
        arm64)   ARCH_ALT="aarch64" ;;
        armhf)   ARCH_ALT="armv7l"  ;;
        *)       warn "Unrecognised architecture: $ARCH ($MACHINE). Some packages may fail." ;;
    esac

    echo -e "${BOLD}Detected architecture:${NC} $ARCH ($MACHINE)"
}

# ── Pre-flight ─────────────────────────────────────────────────────────────────
require_root
detect_arch

log "Updating package lists …"
apt-get update -qq

log "Installing prerequisites …"
apt_install curl wget gnupg2 apt-transport-https software-properties-common \
            ca-certificates lsb-release

UBUNTU_CODENAME=$(lsb_release -cs)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILED=()
SKIPPED=()

# =============================================================================
# 1. SSH  (all architectures – in apt)
# =============================================================================
log "── [1/10] OpenSSH Server ──"
if apt_install openssh-server; then
    systemctl enable --now ssh
    success "SSH installed and service enabled (port 22)."
else
    warn "SSH installation failed."; FAILED+=("SSH")
fi

# =============================================================================
# 2. VLC  (all architectures – universe repo)
# =============================================================================
log "── [2/10] VLC ──"
add-apt-repository -y universe &>/dev/null || true
apt-get update -qq
if apt_install vlc; then
    success "VLC installed."
else
    warn "VLC installation failed."; FAILED+=("VLC")
fi

# =============================================================================
# 3. FFplay  (all architectures – via ffmpeg in apt)
# =============================================================================
log "── [3/10] FFplay (via ffmpeg) ──"
if apt_install ffmpeg; then
    success "FFplay installed."
else
    warn "FFplay installation failed."; FAILED+=("FFplay")
fi

# =============================================================================
# 4. SSHPass  (all architectures – in apt)
# =============================================================================
log "── [4/10] SSHPass ──"
if apt_install sshpass; then
    success "SSHPass installed."
else
    warn "SSHPass installation failed."; FAILED+=("SSHPass")
fi

# =============================================================================
# 5. Mosquitto  (all architectures – official PPA)
# =============================================================================
log "── [5/10] Mosquitto MQTT Broker ──"
curl -fsSL https://repo.mosquitto.org/debian/mosquitto-repo.gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/mosquitto-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/mosquitto-archive-keyring.gpg] \
https://repo.mosquitto.org/debian ${UBUNTU_CODENAME} main" \
    > /etc/apt/sources.list.d/mosquitto.list

apt-get update -qq
if apt_install mosquitto mosquitto-clients; then
    systemctl enable --now mosquitto
    success "Mosquitto installed and service enabled (port 1883)."
else
    warn "Mosquitto PPA failed, trying universe fallback …"
    apt_install mosquitto mosquitto-clients && systemctl enable --now mosquitto \
        || { warn "Mosquitto fallback also failed."; FAILED+=("Mosquitto"); }
fi

# =============================================================================
# 6. XRDP  (all architectures – in apt)
# =============================================================================
log "── [6/10] XRDP ──"
if apt_install xrdp; then
    systemctl enable --now xrdp
    ufw status | grep -q "Status: active" && ufw allow 3389/tcp &>/dev/null || true
    success "XRDP installed and service enabled (port 3389)."
else
    warn "XRDP installation failed."; FAILED+=("XRDP")
fi

# =============================================================================
# 7. Google Chrome
#    amd64  → official Google .deb
#    arm64  → Chromium from apt (Google does NOT ship arm64 Chrome for Linux)
#    armhf  → Chromium from apt (same reason)
# =============================================================================
log "── [7/10] Google Chrome / Chromium ──"
case "$ARCH" in
    amd64)
        CHROME_DEB="$TMP/google-chrome-stable.deb"
        if download_deb \
            "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" \
            "$CHROME_DEB" && install_deb "$CHROME_DEB"; then
            success "Google Chrome (stable) installed."
        else
            warn "Chrome .deb failed, falling back to Chromium …"
            apt_install chromium-browser || apt_install chromium \
                && success "Chromium installed as fallback." \
                || { warn "Chrome/Chromium install failed."; FAILED+=("Chrome/Chromium"); }
        fi
        ;;
    arm64|armhf)
        # Google Chrome is x86-only; Chromium is the official ARM alternative
        warn "Google Chrome is NOT available for $ARCH. Installing Chromium instead (recommended by Google)."
        if apt_install chromium-browser 2>/dev/null || apt_install chromium 2>/dev/null; then
            success "Chromium installed (ARM alternative to Chrome)."
        else
            warn "Chromium installation failed."; FAILED+=("Chromium (ARM)")
        fi
        SKIPPED+=("Google Chrome → replaced with Chromium on $ARCH")
        ;;
    *)
        warn "Unknown arch $ARCH – skipping Chrome."; SKIPPED+=("Chrome (unsupported arch)")
        ;;
esac

# =============================================================================
# 8. Visual Studio Code
#    amd64 / arm64 / armhf → Microsoft's official signed repo supports all three
# =============================================================================
log "── [8/10] Visual Studio Code ──"
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /usr/share/keyrings/microsoft-archive-keyring.gpg

echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] \
https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list

apt-get update -qq
if apt_install code; then
    success "VS Code installed."
else
    warn "VS Code installation failed."; FAILED+=("VS Code")
fi

# =============================================================================
# 9. TeamViewer
#    amd64  → official .deb
#    arm64  → official arm64 .deb (TeamViewer supports it since v15)
#    armhf  → NOT supported by TeamViewer; skip with message
# =============================================================================
log "── [9/10] TeamViewer ──"
case "$ARCH" in
    amd64)
        TV_URL="https://download.teamviewer.com/download/linux/teamviewer_amd64.deb"
        ;;
    arm64)
        TV_URL="https://download.teamviewer.com/download/linux/teamviewer_arm64.deb"
        ;;
    armhf)
        skip "TeamViewer does NOT support armhf (32-bit ARM). Skipping."
        SKIPPED+=("TeamViewer (not supported on armhf)")
        TV_URL=""
        ;;
    *)
        skip "TeamViewer: unknown arch $ARCH. Skipping."
        SKIPPED+=("TeamViewer (unknown arch)")
        TV_URL=""
        ;;
esac

if [[ -n "${TV_URL:-}" ]]; then
    TV_DEB="$TMP/teamviewer.deb"
    if download_deb "$TV_URL" "$TV_DEB" && install_deb "$TV_DEB"; then
        success "TeamViewer installed."
    else
        warn "TeamViewer installation failed."; FAILED+=("TeamViewer")
    fi
fi

# =============================================================================
# 10. DockStation  (GitHub releases)
#     Picks the correct .deb for detected arch from release assets
# =============================================================================
log "── [10/10] DockStation ──"
DS_API="https://api.github.com/repos/DockStation/dockstation/releases/latest"

# Map dpkg arch → pattern used in GitHub asset filenames
case "$ARCH" in
    amd64) DS_PATTERN="amd64\.deb" ;;
    arm64) DS_PATTERN="arm64\.deb" ;;
    armhf) DS_PATTERN="armhf\.deb\|armv7\.deb\|arm\.deb" ;;
    *)     DS_PATTERN="amd64\.deb" ;;   # best-effort fallback
esac

DS_URL=$(curl -fsSL "$DS_API" \
    | grep "browser_download_url" \
    | grep -E "$DS_PATTERN" \
    | head -1 \
    | cut -d '"' -f 4 || true)

if [[ -n "${DS_URL:-}" ]]; then
    DS_DEB="$TMP/dockstation.deb"
    if download_deb "$DS_URL" "$DS_DEB" && install_deb "$DS_DEB"; then
        success "DockStation installed."
    else
        warn "DockStation install failed."; FAILED+=("DockStation")
    fi
else
    # DockStation may not publish ARM builds – note it clearly
    warn "No DockStation release found for arch '$ARCH'. It may not publish ARM builds."
    SKIPPED+=("DockStation (no $ARCH release found)")
fi

# =============================================================================
# Final Report
# =============================================================================
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} Installation Summary  (arch: $ARCH / $MACHINE)${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ ${#FAILED[@]} -eq 0 && ${#SKIPPED[@]} -eq 0 ]]; then
    success "All software installed successfully! 🎉"
else
    if [[ ${#FAILED[@]} -gt 0 ]]; then
        echo -e "\n${RED}Failed (${#FAILED[@]}):${NC}"
        for pkg in "${FAILED[@]}"; do echo -e "   ${RED}✗${NC} $pkg"; done
    fi
    if [[ ${#SKIPPED[@]} -gt 0 ]]; then
        echo -e "\n${YELLOW}Skipped / Substituted (${#SKIPPED[@]}):${NC}"
        for pkg in "${SKIPPED[@]}"; do echo -e "   ${YELLOW}⚠${NC} $pkg"; done
    fi
fi

echo ""
log "Services enabled: SSH (22)  |  Mosquitto (1883)  |  XRDP (3389)"
log "Reboot recommended if this is a fresh server."
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"