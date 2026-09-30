#!/bin/bash
# ==============================================================================
# NTFS Assistant - Production DMG Installer Packaging Script
# Creates a clean, drag-to-Applications distributable .dmg disk image
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/NTFSAssistant.app"
DMG_NAME="NTFSAssistant-1.0.0.dmg"
DMG_OUTPUT="${BUILD_DIR}/${DMG_NAME}"
STAGING_DIR="/tmp/ntfs_dmg_staging"

echo "=========================================================="
echo "  Building Distributable macOS DMG Installer"
echo "=========================================================="

# 1. Package App Bundle
echo "[1/4] Ensuring latest app bundle is packaged..."
"${SCRIPT_DIR}/package_app.sh"

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "Error: App bundle does not exist at ${APP_BUNDLE}"
    exit 1
fi

# 2. Prepare staging area
echo "[2/4] Setting up DMG staging area..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

# 3. Create compressed disk image (UDZO)
echo "[3/4] Creating compressed UDZO disk image..."
rm -f "${DMG_OUTPUT}"
hdiutil create \
    -volname "NTFS Assistant" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_OUTPUT}" >/dev/null

rm -rf "${STAGING_DIR}"

# 4. Verify DMG integrity & generate SHA256
echo "[4/4] Verifying disk image integrity..."
hdiutil verify "${DMG_OUTPUT}" >/dev/null

DMG_SHA256=$(shasum -a 256 "${DMG_OUTPUT}" | awk '{print $1}')
DMG_SIZE=$(du -h "${DMG_OUTPUT}" | awk '{print $1}')

echo "=========================================================="
echo "  ✔ DMG Successfully Created: ${DMG_OUTPUT}"
echo "  Size:   ${DMG_SIZE}"
echo "  SHA256: ${DMG_SHA256}"
echo "=========================================================="
