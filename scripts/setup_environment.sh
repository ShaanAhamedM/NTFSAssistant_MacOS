#!/bin/bash
# ==============================================================================
# NTFS Assistant - Environment & Dependency Setup Script
# Automatically verifies and configures fuse-t, ntfs-3g, helper daemon, and sudoers
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=========================================================="
echo "  NTFS Assistant - Environment & Dependency Setup"
echo "=========================================================="

# 1. Check for Homebrew
echo "[1/6] Checking Homebrew..."
if which brew >/dev/null 2>&1; then
    BREW_PATH="$(which brew)"
    echo "  ✔ Homebrew detected at: ${BREW_PATH} ($(brew --version | head -n1))"
else
    echo "  ⚠ Homebrew not found in PATH. Proceeding with bundled binaries..."
fi

# 2. Check & Install FUSE-T
echo "[2/6] Verifying FUSE-T (kext-less FUSE engine)..."
FUSE_T_INSTALLED=false
if [ -d "/Library/Application Support/fuse-t" ] || [ -f "/usr/local/lib/libfuse-t.dylib" ]; then
    FUSE_T_INSTALLED=true
    echo "  ✔ FUSE-T is already installed."
else
    PKG_PATH="${SCRIPT_DIR}/fuse-t.pkg"
    if [ ! -f "${PKG_PATH}" ]; then
        if [ -f "${BASE_DIR}/packages/fuse-t.pkg" ]; then
            PKG_PATH="${BASE_DIR}/packages/fuse-t.pkg"
        elif [ -f "${BASE_DIR}/scripts/fuse-t.pkg" ]; then
            PKG_PATH="${BASE_DIR}/scripts/fuse-t.pkg"
        elif [ -f "${SCRIPT_DIR}/../packages/fuse-t.pkg" ]; then
            PKG_PATH="${SCRIPT_DIR}/../packages/fuse-t.pkg"
        fi
    fi
    if [ ! -f "${PKG_PATH}" ]; then
        echo "  -> Downloading latest FUSE-T package..."
        curl -L -o "${PKG_PATH}" "https://github.com/macos-fuse-t/fuse-t/releases/download/1.2.7/fuse-t-macos-installer-1.2.7.pkg"
    fi
    sudo /usr/sbin/installer -pkg "${PKG_PATH}" -target /
    echo "  ✔ FUSE-T successfully installed."
fi

# 3. Configure /etc/hosts for fuse-t
echo "[3/6] Verifying /etc/hosts for fuse-t NFS loopback..."
if grep -q "fuse-t" /etc/hosts; then
    echo "  ✔ /etc/hosts already has fuse-t loopback configured."
else
    echo "  -> Adding '127.0.0.1 fuse-t' to /etc/hosts..."
    echo "127.0.0.1 fuse-t" | sudo tee -a /etc/hosts >/dev/null
    echo "  ✔ /etc/hosts updated."
fi

# 4. Install binaries and libraries to /usr/local and /Library/Application Support/NTFSAssistant
echo "[4/6] Installing self-contained ntfs-3g and ntfsprogs..."
sudo /bin/mkdir -p /usr/local/bin /usr/local/lib
sudo /bin/mkdir -p "/Library/Application Support/NTFSAssistant/bin"
sudo /bin/mkdir -p "/Library/Application Support/NTFSAssistant/lib"

sudo /bin/cp -f "${BASE_DIR}/bin/ntfs-3g" "/usr/local/bin/"
sudo /bin/cp -f "${BASE_DIR}/bin/ntfsfix" "/usr/local/bin/"
sudo /bin/cp -f "${BASE_DIR}/bin/ntfslabel" "/usr/local/bin/"
sudo /bin/cp -f "${BASE_DIR}/bin/ntfsinfo" "/usr/local/bin/"
sudo /bin/cp -f "${BASE_DIR}/bin/go-nfsv4" "/usr/local/bin/"

sudo /bin/cp -f "${BASE_DIR}/lib/"* "/usr/local/lib/" 2>/dev/null || true

sudo /bin/cp -f "${BASE_DIR}/bin/"* "/Library/Application Support/NTFSAssistant/bin/"
sudo /bin/cp -f "${BASE_DIR}/lib/"* "/Library/Application Support/NTFSAssistant/lib/" 2>/dev/null || true

sudo /bin/chmod 755 /usr/local/bin/ntfs-3g /usr/local/bin/ntfsfix /usr/local/bin/go-nfsv4
sudo /bin/chmod 755 "/Library/Application Support/NTFSAssistant/bin/"*
echo "  ✔ Driver binaries and libraries installed successfully."

# 5. Install privileged helper script
echo "[5/6] Installing privileged mount helper..."
HELPER_DEST="/Library/Application Support/NTFSAssistant/ntfs-mount-helper"
HELPER_SRC="${SCRIPT_DIR}/ntfs-mount-helper.sh"
if [ ! -f "${HELPER_SRC}" ]; then
    HELPER_SRC="${SCRIPT_DIR}/ntfs-mount-helper"
fi
sudo /bin/cp -f "${HELPER_SRC}" "${HELPER_DEST}"
sudo /bin/cp -f "${SCRIPT_DIR}/setup_environment.sh" "/Library/Application Support/NTFSAssistant/setup_environment.sh" 2>/dev/null || true
sudo /usr/sbin/chown root:wheel "${HELPER_DEST}" "/Library/Application Support/NTFSAssistant/setup_environment.sh" 2>/dev/null || true
sudo /bin/chmod 755 "${HELPER_DEST}" "/Library/Application Support/NTFSAssistant/setup_environment.sh" 2>/dev/null || true
echo "  ✔ Helper script installed at: ${HELPER_DEST}"

# 6. Configure sudoers.d for passwordless mounting operations
echo "[6/6] Configuring minimal, secure sudoers rule..."
SUDOERS_FILE="/etc/sudoers.d/ntfs-assistant"
SUDOERS_TMP="$(mktemp /tmp/ntfs-sudoers.XXXXXX)"

cat << 'EOF' > "${SUDOERS_TMP}"
# NTFS Assistant Privileged Operations Rule
# Allows non-interactive safe mounting, unmounting, and pre-mount checks
%admin ALL=(ALL) NOPASSWD: /Library/Application\ Support/NTFSAssistant/ntfs-mount-helper, /usr/local/bin/ntfs-3g, /usr/local/bin/ntfsfix, /usr/sbin/diskutil
EOF

# Validate syntax with visudo
if sudo /usr/sbin/visudo -c -f "${SUDOERS_TMP}"; then
    sudo /bin/cp "${SUDOERS_TMP}" "${SUDOERS_FILE}"
    sudo /bin/chmod 440 "${SUDOERS_FILE}"
    sudo /usr/sbin/chown root:wheel "${SUDOERS_FILE}"
    rm -f "${SUDOERS_TMP}"
    echo "  ✔ Sudoers rule validated and active at: ${SUDOERS_FILE}"
else
    rm -f "${SUDOERS_TMP}"
    echo "  ✖ Sudoers validation failed! Aborting sudoers installation."
    exit 1
fi

echo "=========================================================="
echo "  Setup Completed Successfully!"
echo "  NTFS Assistant is ready for plug-and-play R/W operation."
echo "=========================================================="
