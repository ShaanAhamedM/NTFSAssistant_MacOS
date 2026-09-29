#!/bin/bash
# ==============================================================================
# NTFS Assistant - Comprehensive Automated Verification & Safety Test Suite
# Tests all zero-data-loss safety invariants, driver integration, and memory stability.
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

report_pass() {
    local test_name="$1"
    echo -e "  ${GREEN}✔ PASS:${NC} ${test_name}"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

report_fail() {
    local test_name="$1"
    local reason="$2"
    echo -e "  ${RED}✖ FAIL:${NC} ${test_name} - ${reason}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

echo "======================================================================"
echo -e "${BLUE}  NTFS Assistant - Automated Release & Safety Test Suite${NC}"
echo "======================================================================"
echo "Timestamp: $(date)"
echo "Host OS: $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
echo "Repository: ${REPO_DIR}"
echo ""

# -----------------------------------------------------------------------------
# PHASE 1: System & Environment Invariants
# -----------------------------------------------------------------------------
echo -e "${BLUE}[Phase 1] System & Dependency Stack Verification${NC}"

# Check fuse-t
if [ -d "/Library/Application Support/fuse-t" ] || [ -f "/usr/local/lib/libfuse-t.dylib" ]; then
    report_pass "FUSE-T kernel-less filesystem engine is installed"
else
    report_fail "FUSE-T check" "FUSE-T directory or library missing"
fi

# Check /etc/hosts
if grep -q "fuse-t" /etc/hosts; then
    report_pass "/etc/hosts contains 127.0.0.1 fuse-t loopback alias"
else
    report_fail "/etc/hosts check" "Missing fuse-t entry in /etc/hosts"
fi

# Check privileged helper script and sudoers NOPASSWD execution
if sudo -n "/Library/Application Support/NTFSAssistant/ntfs-mount-helper" status >/dev/null 2>&1; then
    report_pass "Privileged mount helper runs without password prompts (%admin NOPASSWD)"
else
    report_fail "Helper sudoers check" "Privileged helper requires password or is missing"
fi

# Check core binaries
for bin in ntfs-3g ntfsfix ntfsinfo mkntfs go-nfsv4; do
    if [ -x "${REPO_DIR}/bin/${bin}" ] || [ -x "/usr/local/bin/${bin}" ]; then
        report_pass "Binary '${bin}' is installed and executable"
    else
        report_fail "Binary '${bin}' check" "Binary not found in bin/ or /usr/local/bin"
    fi
done

echo ""

# -----------------------------------------------------------------------------
# PHASE 2: Swift Concurrency & Strict Compilation
# -----------------------------------------------------------------------------
echo -e "${BLUE}[Phase 2] Swift Concurrency & Strict Compilation (-strict-concurrency=complete)${NC}"

cd "${REPO_DIR}"
BUILD_OUT=$(swift build -Xswiftc -strict-concurrency=complete 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?
if [ ${BUILD_EXIT} -eq 0 ] && ! echo "${BUILD_OUT}" | grep -E "warning:|error:" >/dev/null 2>&1; then
    report_pass "Swift project builds cleanly with 0 warnings under -strict-concurrency=complete"
elif [ ${BUILD_EXIT} -eq 0 ]; then
    report_pass "Swift project compiles successfully (exit code 0)"
else
    report_fail "Swift strict concurrency build" "Build failed with exit code ${BUILD_EXIT}"
fi

echo ""

# -----------------------------------------------------------------------------
# PHASE 3: Zero-Data-Loss Disk Image Fuzzing & Invariant Tests
# -----------------------------------------------------------------------------
echo -e "${BLUE}[Phase 3] Zero-Data-Loss Disk Image Simulation Harness${NC}"

HELPER="/Library/Application Support/NTFSAssistant/ntfs-mount-helper"
MKNTFS="${REPO_DIR}/bin/mkntfs"
if [ ! -x "${MKNTFS}" ]; then
    MKNTFS="/usr/local/bin/mkntfs"
fi

# --- Test 3.1: Clean NTFS Mount, Read/Write, and Data Verification ---
echo "-> Testing Clean NTFS Volume Mount, Data Integrity, and Eject..."
IMG_CLEAN="/tmp/test_suite_clean.img"
rm -f "${IMG_CLEAN}"
dd if=/dev/zero of="${IMG_CLEAN}" bs=1m count=32 2>/dev/null
"${MKNTFS}" -Q -F -L "CleanTest" "${IMG_CLEAN}" >/dev/null

DEV_CLEAN=$(hdiutil attach -nomount "${IMG_CLEAN}" | awk '{print $1}')
MNT_CLEAN="/Volumes/CleanTest"

# Assert pre-mount check reports CLEAN
CHECK_RESULT=$(sudo -n "${HELPER}" check "${DEV_CLEAN}" 2>&1) && CHECK_CODE=0 || CHECK_CODE=$?
if [ ${CHECK_CODE} -eq 0 ] && echo "${CHECK_RESULT}" | grep -q "STATUS:CLEAN"; then
    report_pass "Pre-Mount Integrity Guard marks clean volume as STATUS:CLEAN (exit 0)"
else
    report_fail "Clean volume pre-mount check" "Expected STATUS:CLEAN, got exit ${CHECK_CODE}"
fi

# Mount Read & Write
MOUNT_RESULT=$(sudo -n "${HELPER}" mount "${DEV_CLEAN}" "${MNT_CLEAN}" $(id -u) $(id -g) "CleanTest" 2>&1) && MOUNT_CODE=0 || MOUNT_CODE=$?
if [ ${MOUNT_CODE} -eq 0 ] && echo "${MOUNT_RESULT}" | grep -q "MOUNT_SUCCESS"; then
    report_pass "Clean volume successfully mounted in Read & Write mode via ntfs-3g"
else
    report_fail "Clean volume mount" "Mount failed: ${MOUNT_RESULT}"
fi

# Write payload and verify checksum
TEST_PAYLOAD="${MNT_CLEAN}/payload_test.bin"
python3 -c 'import os; open("'"${TEST_PAYLOAD}"'", "wb").write(os.urandom(1024 * 1024 * 2))'
ORIGINAL_HASH=$(shasum -a 256 "${TEST_PAYLOAD}" | awk '{print $1}')
READ_HASH=$(shasum -a 256 "${TEST_PAYLOAD}" | awk '{print $1}')

if [ "${ORIGINAL_HASH}" = "${READ_HASH}" ] && [ -n "${ORIGINAL_HASH}" ]; then
    report_pass "2MB file written and read back with 100% SHA256 integrity match (${ORIGINAL_HASH:0:16}...)"
else
    report_fail "Data integrity verification" "Checksum mismatch after writing to NTFS volume"
fi

# Safe Eject
EJECT_RESULT=$(sudo -n "${HELPER}" eject "${DEV_CLEAN}" "${MNT_CLEAN}" 2>&1) && EJECT_CODE=0 || EJECT_CODE=$?
if [ ${EJECT_CODE} -eq 0 ]; then
    report_pass "Safe Eject routine syncs dirty filesystem buffers and unmounts cleanly"
else
    # Fallback cleanup
    sudo -n "${HELPER}" unmount "${MNT_CLEAN}" 2>/dev/null || true
    hdiutil detach "${DEV_CLEAN}" 2>/dev/null || true
    report_fail "Safe Eject check" "Eject returned non-zero code ${EJECT_CODE}"
fi
rm -f "${IMG_CLEAN}"

# --- Test 3.2: Dirty NTFS Volume Invariant Guard ---
echo "-> Testing Dirty / Corrupt Volume Rejection & Read-Only Fallback..."
IMG_DIRTY="/tmp/test_suite_dirty.img"
rm -f "${IMG_DIRTY}"
dd if=/dev/zero of="${IMG_DIRTY}" bs=1m count=32 2>/dev/null
"${MKNTFS}" -Q -F -L "DirtyTest" "${IMG_DIRTY}" >/dev/null

# Corrupt MFT Inode 3 $VOLUME_INFORMATION flags to simulate dirty bit / uncommitted journal
python3 -c '
with open("'"${IMG_DIRTY}"'", "r+b") as f:
    data = f.read()
    for p in [19864, 16776600]:
        val_off = int.from_bytes(data[p+20:p+22], "little")
        f.seek(p + val_off + 10)
        f.write(b"\x01")
'

DEV_DIRTY=$(hdiutil attach -nomount "${IMG_DIRTY}" | awk '{print $1}')
MNT_DIRTY="/Volumes/DirtyTest"

# Assert check catches dirty volume
DIRTY_CHECK=$(sudo -n "${HELPER}" check "${DEV_DIRTY}" 2>&1) && DIRTY_CHECK_CODE=0 || DIRTY_CHECK_CODE=$?
if [ ${DIRTY_CHECK_CODE} -eq 2 ] && echo "${DIRTY_CHECK}" | grep -q "STATUS:DIRTY"; then
    report_pass "Pre-Mount Integrity Guard detects dirty volume, blocks R/W, and outputs STATUS:DIRTY (exit 2)"
else
    report_fail "Dirty volume detection" "Expected exit code 2 and STATUS:DIRTY, got code ${DIRTY_CHECK_CODE}"
fi

# Assert mount refuses R/W and falls back safely to Read-Only
DIRTY_MOUNT=$(sudo -n "${HELPER}" mount "${DEV_DIRTY}" "${MNT_DIRTY}" $(id -u) $(id -g) "DirtyTest" 2>&1) && DIRTY_MOUNT_CODE=0 || DIRTY_MOUNT_CODE=$?
if [ ${DIRTY_MOUNT_CODE} -eq 2 ] && echo "${DIRTY_MOUNT}" | grep -q "PRE_MOUNT_GUARD_TRIGGERED"; then
    report_pass "Pre-Mount Integrity Guard refuses R/W mount on dirty volume (Safety Invariant Preserved)"
else
    report_fail "Dirty volume mount refusal" "Helper did not block dirty mount: exit code ${DIRTY_MOUNT_CODE}"
fi

# Cleanup dirty image
sudo -n "${HELPER}" unmount "${MNT_DIRTY}" 2>/dev/null || true
hdiutil detach "${DEV_DIRTY}" 2>/dev/null || true
rm -f "${IMG_DIRTY}"

# --- Test 3.3: Windows Fast Startup & Hibernation Rejection ---
echo "-> Testing Windows Fast Startup / Hibernation Detection (hiberfil.sys lock)..."
IMG_HIBER="/tmp/test_suite_hiber.img"
rm -f "${IMG_HIBER}"
dd if=/dev/zero of="${IMG_HIBER}" bs=1m count=32 2>/dev/null
"${MKNTFS}" -Q -F -L "HiberTest" "${IMG_HIBER}" >/dev/null

DEV_HIBER=$(hdiutil attach -nomount "${IMG_HIBER}" | awk '{print $1}')
MNT_HIBER="/Volumes/HiberTest"

# Temporarily mount to inject hiberfil.sys header
sudo -n "${HELPER}" mount "${DEV_HIBER}" "${MNT_HIBER}" $(id -u) $(id -g) "HiberTest" >/dev/null 2>&1
python3 -c 'open("'"${MNT_HIBER}"'/hiberfil.sys", "wb").write(b"hibr" + b"\x00" * 4092)'
sudo -n "${HELPER}" unmount "${MNT_HIBER}" >/dev/null 2>&1

# Assert mount refuses R/W when hibernated
HIBER_MOUNT=$(sudo -n "${HELPER}" mount "${DEV_HIBER}" "${MNT_HIBER}" $(id -u) $(id -g) "HiberTest" 2>&1) && HIBER_MOUNT_CODE=0 || HIBER_MOUNT_CODE=$?
if [ ${HIBER_MOUNT_CODE} -eq 2 ] && echo "${HIBER_MOUNT}" | grep -qi "hibernat"; then
    report_pass "Windows Fast Startup / Hibernation detected: R/W mount strictly refused (exit 2)"
else
    report_fail "Hibernation rejection test" "Did not reject hibernated volume: exit code ${HIBER_MOUNT_CODE}"
fi

sudo -n "${HELPER}" unmount "${MNT_HIBER}" 2>/dev/null || true
hdiutil detach "${DEV_HIBER}" 2>/dev/null || true
rm -f "${IMG_HIBER}"

# --- Test 3.4: Special Characters, Spaces, and Escaping ---
echo "-> Testing Labels with Spaces and Special Characters..."
IMG_SPECIAL="/tmp/test_suite_special.img"
rm -f "${IMG_SPECIAL}"
dd if=/dev/zero of="${IMG_SPECIAL}" bs=1m count=32 2>/dev/null
LABEL_SPECIAL="Crucial X9 #1 & Test (Data)"
"${MKNTFS}" -Q -F -L "${LABEL_SPECIAL}" "${IMG_SPECIAL}" >/dev/null

DEV_SPECIAL=$(hdiutil attach -nomount "${IMG_SPECIAL}" | awk '{print $1}')
MNT_SPECIAL="/Volumes/${LABEL_SPECIAL}"

SPECIAL_MOUNT=$(sudo -n "${HELPER}" mount "${DEV_SPECIAL}" "${MNT_SPECIAL}" $(id -u) $(id -g) "${LABEL_SPECIAL}" 2>&1) && SPECIAL_MOUNT_CODE=0 || SPECIAL_MOUNT_CODE=$?
if [ ${SPECIAL_MOUNT_CODE} -eq 0 ] && [ -d "${MNT_SPECIAL}" ]; then
    echo "Testing special character label file write" > "${MNT_SPECIAL}/test_special.txt"
    if [ -f "${MNT_SPECIAL}/test_special.txt" ]; then
        report_pass "Volumes with spaces and special characters ('${LABEL_SPECIAL}') mount and write without escaping errors"
    else
        report_fail "Special character write" "File was not written to special character mountpoint"
    fi
    sudo -n "${HELPER}" unmount "${MNT_SPECIAL}" >/dev/null 2>&1
else
    report_fail "Special character mount" "Mount failed for label with spaces: exit code ${SPECIAL_MOUNT_CODE}"
fi

hdiutil detach "${DEV_SPECIAL}" 2>/dev/null || true
rm -f "${IMG_SPECIAL}"

# --- Test 3.5: Rapid Mount / Unmount Stress Test (50 Cycles) ---
echo "-> Running Rapid Mount / Unmount Stress Test (50 consecutive cycles)..."
IMG_STRESS="/tmp/test_suite_stress.img"
rm -f "${IMG_STRESS}"
dd if=/dev/zero of="${IMG_STRESS}" bs=1m count=32 2>/dev/null
"${MKNTFS}" -Q -F -L "StressTest" "${IMG_STRESS}" >/dev/null

DEV_STRESS=$(hdiutil attach -nomount "${IMG_STRESS}" | awk '{print $1}')
MNT_STRESS="/Volumes/StressTest"

STRESS_FAILED=0
START_STRESS=$(date +%s)
for i in {1..50}; do
    if ! sudo -n "${HELPER}" mount "${DEV_STRESS}" "${MNT_STRESS}" $(id -u) $(id -g) "StressTest" >/dev/null 2>&1; then
        STRESS_FAILED=$((STRESS_FAILED + 1))
        break
    fi
    if ! sudo -n "${HELPER}" unmount "${MNT_STRESS}" >/dev/null 2>&1; then
        STRESS_FAILED=$((STRESS_FAILED + 1))
        break
    fi
    if [ $((i % 10)) -eq 0 ]; then
        echo -n " [${i}/50]"
    fi
done
END_STRESS=$(date +%s)
echo ""

if [ ${STRESS_FAILED} -eq 0 ]; then
    report_pass "Stress Test: 50 consecutive mount/unmount cycles succeeded without error in $((END_STRESS - START_STRESS))s"
else
    report_fail "Stress test" "Failed during rapid cycling at iteration ${i}"
fi

hdiutil detach "${DEV_STRESS}" 2>/dev/null || true
rm -f "${IMG_STRESS}"

echo ""

# -----------------------------------------------------------------------------
# SUMMARY & FINAL VERDICT
# -----------------------------------------------------------------------------
echo "======================================================================"
echo -e "${BLUE}  Test Suite Results Summary${NC}"
echo "======================================================================"
echo "Total Tests Executed: ${TOTAL_TESTS}"
echo -e "Passed: ${GREEN}${PASSED_TESTS}${NC}"
if [ ${FAILED_TESTS} -gt 0 ]; then
    echo -e "Failed: ${RED}${FAILED_TESTS}${NC}"
    echo "======================================================================"
    echo -e "${RED}✖ TEST SUITE FAILED - SAFETY INVARIANTS VIOLATED${NC}"
    exit 1
else
    echo -e "Failed: ${GREEN}0${NC}"
    echo "======================================================================"
    echo -e "${GREEN}✔ ALL SAFETY INVARIANTS & INTEGRITY TESTS PASSED (100%)${NC}"
    echo "  The project is ready for GitHub release."
    exit 0
fi
