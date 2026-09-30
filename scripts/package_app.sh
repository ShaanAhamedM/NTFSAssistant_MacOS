#!/bin/bash
# ==============================================================================
# NTFS Assistant - Application Bundling & Packaging Script
# Compiles and packages production ./build/NTFSAssistant.app bundle
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/NTFSAssistant.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "=========================================================="
echo "  Packaging NTFSAssistant.app"
echo "=========================================================="

# 1. Compile release binary if needed
echo "[1/4] Ensuring release binary is compiled..."
cd "${PROJECT_DIR}"
swift build -c release

RELEASE_BIN="${PROJECT_DIR}/.build/release/NTFSAssistant"
if [ ! -f "${RELEASE_BIN}" ]; then
    echo "Error: Release binary not found at ${RELEASE_BIN}"
    exit 1
fi

# 2. Setup bundle directories
echo "[2/4] Constructing App Bundle layout..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}/bin"
mkdir -p "${RESOURCES_DIR}/lib"
mkdir -p "${RESOURCES_DIR}/scripts"

# Copy main binary
cp -f "${RELEASE_BIN}" "${MACOS_DIR}/NTFSAssistant"
chmod 755 "${MACOS_DIR}/NTFSAssistant"

mkdir -p "${RESOURCES_DIR}/packages"

# Copy embedded drivers & tools
cp -f "${PROJECT_DIR}/bin/ntfs-3g" "${RESOURCES_DIR}/bin/"
cp -f "${PROJECT_DIR}/bin/ntfsfix" "${RESOURCES_DIR}/bin/"
cp -f "${PROJECT_DIR}/bin/ntfslabel" "${RESOURCES_DIR}/bin/"
cp -f "${PROJECT_DIR}/bin/ntfsinfo" "${RESOURCES_DIR}/bin/"
cp -f "${PROJECT_DIR}/bin/mkntfs" "${RESOURCES_DIR}/bin/" 2>/dev/null || true
cp -f "${PROJECT_DIR}/bin/go-nfsv4" "${RESOURCES_DIR}/bin/"

cp -f "${PROJECT_DIR}/lib/"* "${RESOURCES_DIR}/lib/" 2>/dev/null || true
cp -f "${PROJECT_DIR}/scripts/ntfs-mount-helper.sh" "${RESOURCES_DIR}/scripts/ntfs-mount-helper"
cp -f "${PROJECT_DIR}/scripts/ntfs-mount-helper.sh" "${RESOURCES_DIR}/scripts/ntfs-mount-helper.sh"
cp -f "${PROJECT_DIR}/scripts/setup_environment.sh" "${RESOURCES_DIR}/scripts/"
if [ -f "${PROJECT_DIR}/scripts/fuse-t.pkg" ]; then
    cp -f "${PROJECT_DIR}/scripts/fuse-t.pkg" "${RESOURCES_DIR}/packages/"
fi

chmod 755 "${RESOURCES_DIR}/bin/"* "${RESOURCES_DIR}/scripts/"*

# 3. Create Info.plist & PkgInfo
echo "[3/4] Writing Info.plist & PkgInfo..."
cat << 'EOF' > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>NTFSAssistant</string>
    <key>CFBundleIdentifier</key>
    <string>com.shaanahamedm.NTFSAssistant</string>
    <key>CFBundleName</key>
    <string>NTFS Assistant</string>
    <key>CFBundleDisplayName</key>
    <string>NTFS Assistant</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Shaan M. Open source under GPL-2.0-or-later.</string>
</dict>
</plist>
EOF

echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# 4. Ad-hoc Code Sign bundle
echo "[4/4] Applying ad-hoc code signature..."
codesign --force --deep -s - "${APP_BUNDLE}"

echo "=========================================================="
echo "  Successfully packaged: ${APP_BUNDLE}"
echo "=========================================================="
