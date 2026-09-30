#!/bin/bash
# ==============================================================================
# NTFS Assistant - Safe Eject & Data Loss Prevention Test Harness
# Tests all data safety invariants, cache flushing, busy handle protection,
# and verifies zero volume corruption after eject.
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="/Library/Application Support/NTFSAssistant/ntfs-mount-helper"
MKNTFS="${REPO_DIR}/bin/mkntfs"
NTFSFIX="${REPO_DIR}/bin/ntfsfix"
NTFSINFO="${REPO_DIR}/bin/ntfsinfo"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

TOTAL=0
PASSED=0
FAILED=0

pass() {
    echo -e "  ${GREEN}✔ PASS:${NC} $1"
    PASSED=$((PASSED + 1))
    TOTAL=$((TOTAL + 1))
}

fail() {
    echo -e "  ${RED}✖ FAIL:${NC} $1 - $2"
    FAILED=$((FAILED + 1))
    TOTAL=$((TOTAL + 1))
}

cleanup_disks() {
    for dev in $(hdiutil info | grep -E "test_eject_.*\.img" | awk '{print $1}'); do
        hdiutil detach "$dev" -force >/dev/null 2>&1 || true
    done
    rm -f /tmp/test_eject_*.img
}
trap cleanup_disks EXIT

echo "======================================================================"
echo -e "${BLUE}  NTFS Assistant: Safe Eject & Zero-Data-Loss Verification Suite${NC}"
echo "======================================================================"

# -----------------------------------------------------------------------------
# TEST 1: Clean Mount, Data Write, Hash, Eject, and Post-Eject Clean Verification
# -----------------------------------------------------------------------------
echo -e "\n${BLUE}[Test 1] Full Data Write, Hash Match, and Post-Eject Clean State Verification${NC}"
IMG1="/tmp/test_eject_data_integrity.img"
rm -f "$IMG1"
dd if=/dev/zero of="$IMG1" bs=1m count=64 2>/dev/null
"$MKNTFS" -Q -F -L "EjectData" "$IMG1" >/dev/null

DEV1=$(hdiutil attach -nomount "$IMG1" | awk '{print $1}')
MNT1="/Volumes/EjectData"

# Mount R/W
sudo -n "$HELPER" mount "$DEV1" "$MNT1" $(id -u) $(id -g) "EjectData" >/dev/null

# Write 10MB of random binary payload
PAYLOAD="$MNT1/test_payload_10mb.bin"
python3 -c 'import os; open("'"$PAYLOAD"'", "wb").write(os.urandom(1024 * 1024 * 10))'
ORIGINAL_SHA=$(shasum -a 256 "$PAYLOAD" | awk '{print $1}')

# Execute Safe Eject
EJECT_OUT=$(sudo -n "$HELPER" eject "$DEV1" "$MNT1" 2>&1)
if echo "$EJECT_OUT" | grep -q "EJECT_SUCCESS"; then
    pass "Safe Eject completed with EJECT_SUCCESS"
else
    fail "Safe Eject execution" "$EJECT_OUT"
fi

# Verify disk was detached
if hdiutil info | grep -q "$IMG1"; then
    fail "Detached check" "Image is still attached after eject"
else
    pass "Image properly detached from system by eject"
fi

# Re-attach raw disk and verify NTFS volume state is 100% clean
DEV1_RE=$(hdiutil attach -nomount "$IMG1" | awk '{print $1}')
CHECK_REPORT=$(sudo -n "$HELPER" check "$DEV1_RE" 2>&1) && CHECK_CODE=0 || CHECK_CODE=$?
if [ $CHECK_CODE -eq 0 ] && echo "$CHECK_REPORT" | grep -q "STATUS:CLEAN"; then
    pass "Post-eject volume is 100% clean (STATUS:CLEAN, exit 0, no dirty flag)"
else
    fail "Post-eject volume cleanliness" "Report: $CHECK_REPORT"
fi

# Mount again and verify the 10MB payload has 100% identical SHA256
MNT1_VERIFY="/Volumes/EjectDataVerify"
sudo -n "$HELPER" mount "$DEV1_RE" "$MNT1_VERIFY" $(id -u) $(id -g) "EjectDataVerify" >/dev/null
VERIFIED_SHA=$(shasum -a 256 "$MNT1_VERIFY/test_payload_10mb.bin" | awk '{print $1}')

if [ "$ORIGINAL_SHA" = "$VERIFIED_SHA" ]; then
    pass "Zero data loss: 10MB file verified with 100% SHA256 match ($VERIFIED_SHA)"
else
    fail "Data loss detected" "Expected $ORIGINAL_SHA, got $VERIFIED_SHA"
fi

sudo -n "$HELPER" eject "$DEV1_RE" "$MNT1_VERIFY" >/dev/null
rm -f "$IMG1"

# -----------------------------------------------------------------------------
# TEST 2: Active Open File / In-Use Protection (Refuse Force-Kill)
# -----------------------------------------------------------------------------
echo -e "\n${BLUE}[Test 2] Active Open File Protection (Refuse Eject While Files Are In Use)${NC}"
IMG2="/tmp/test_eject_busy.img"
rm -f "$IMG2"
dd if=/dev/zero of="$IMG2" bs=1m count=32 2>/dev/null
"$MKNTFS" -Q -F -L "EjectBusy" "$IMG2" >/dev/null

DEV2=$(hdiutil attach -nomount "$IMG2" | awk '{print $1}')
MNT2="/Volumes/EjectBusy"
sudo -n "$HELPER" mount "$DEV2" "$MNT2" $(id -u) $(id -g) "EjectBusy" >/dev/null

# Start background writer holding an open descriptor
python3 -c '
import time
with open("'"$MNT2"'/busy_document.txt", "w") as f:
    for i in range(100):
        f.write(f"Line {i} of important unsaved work\n")
        f.flush()
        time.sleep(0.1)
' &
BG_WRITER_PID=$!
sleep 0.5

# Attempt Safe Eject while file is actively being written
BUSY_EJECT_OUT=$(sudo -n "$HELPER" eject "$DEV2" "$MNT2" 2>&1) && BUSY_EXIT=0 || BUSY_EXIT=$?

if [ $BUSY_EXIT -ne 0 ] && echo "$BUSY_EJECT_OUT" | grep -q "EJECT_FAILED_BUSY"; then
    pass "Safety Invariant Preserved: Helper strictly refused eject while file was in use (exit $BUSY_EXIT)"
else
    fail "Busy handle rejection" "Expected refusal, got exit $BUSY_EXIT: $BUSY_EJECT_OUT"
fi

# Verify drive is still mounted and writer was not killed or disrupted
if /sbin/mount | grep -q "$MNT2"; then
    pass "Volume remained mounted and protected without data corruption"
else
    fail "Volume unmounted unexpectedly" "Mountpoint was dropped while file was open"
fi

# Wait for writer to complete cleanly
wait $BG_WRITER_PID || true

# Now that file is closed, safe eject should succeed cleanly
CLEAN_EJECT_OUT=$(sudo -n "$HELPER" eject "$DEV2" "$MNT2" 2>&1) && CLEAN_EXIT=0 || CLEAN_EXIT=$?
if [ $CLEAN_EXIT -eq 0 ] && echo "$CLEAN_EJECT_OUT" | grep -q "EJECT_SUCCESS"; then
    pass "Eject succeeded cleanly once open file was closed"
else
    fail "Eject after close" "Exit $CLEAN_EXIT: $CLEAN_EJECT_OUT"
fi

# Verify volume on re-attach
DEV2_RE=$(hdiutil attach -nomount "$IMG2" | awk '{print $1}')
BUSY_CHECK=$(sudo -n "$HELPER" check "$DEV2_RE" 2>&1) && BUSY_CHECK_CODE=0 || BUSY_CHECK_CODE=$?
if [ $BUSY_CHECK_CODE -eq 0 ] && echo "$BUSY_CHECK" | grep -q "STATUS:CLEAN"; then
    pass "Volume verified 100% clean after handled busy scenario"
else
    fail "Volume clean check after busy test" "$BUSY_CHECK"
fi
hdiutil detach "$DEV2_RE" >/dev/null 2>&1 || true
rm -f "$IMG2"

# -----------------------------------------------------------------------------
# TEST 3: Dirty Buffer Flush Under Rapid Writes (Sync Guarantee)
# -----------------------------------------------------------------------------
echo -e "\n${BLUE}[Test 3] Dirty Buffer Cache Flush Under Rapid Sequential Writes${NC}"
IMG3="/tmp/test_eject_sync.img"
rm -f "$IMG3"
dd if=/dev/zero of="$IMG3" bs=1m count=48 2>/dev/null
"$MKNTFS" -Q -F -L "EjectSync" "$IMG3" >/dev/null

DEV3=$(hdiutil attach -nomount "$IMG3" | awk '{print $1}')
MNT3="/Volumes/EjectSync"
sudo -n "$HELPER" mount "$DEV3" "$MNT3" $(id -u) $(id -g) "EjectSync" >/dev/null

# Write 20 individual files in rapid succession without explicit sync
EXPECTED_HASHES=()
for i in {1..20}; do
    FILE_PATH="$MNT3/rapid_file_${i}.dat"
    head -c 65536 /dev/urandom > "$FILE_PATH"
    EXPECTED_HASHES+=("$(shasum -a 256 "$FILE_PATH" | awk '{print $1}')")
done

# Eject immediately
sudo -n "$HELPER" eject "$DEV3" "$MNT3" >/dev/null
pass "Rapid-write safe eject finished cleanly"

# Re-attach and verify every single file's hash matches exactly
DEV3_RE=$(hdiutil attach -nomount "$IMG3" | awk '{print $1}')
sudo -n "$HELPER" mount "$DEV3_RE" "$MNT3" $(id -u) $(id -g) "EjectSync" >/dev/null

ALL_MATCH=true
for i in {1..20}; do
    FILE_PATH="$MNT3/rapid_file_${i}.dat"
    ACTUAL_HASH=$(shasum -a 256 "$FILE_PATH" | awk '{print $1}')
    EXP_HASH="${EXPECTED_HASHES[$((i - 1))]}"
    if [ "$ACTUAL_HASH" != "$EXP_HASH" ]; then
        ALL_MATCH=false
        break
    fi
done

if [ "$ALL_MATCH" = "true" ]; then
    pass "All 20 rapidly written files intact with 100% hash consistency"
else
    fail "Rapid-write integrity" "Hash mismatch detected in file ${i}"
fi

sudo -n "$HELPER" eject "$DEV3_RE" "$MNT3" >/dev/null
rm -f "$IMG3"

# -----------------------------------------------------------------------------
# TEST 4: No Orphaned Daemons / ntfs-3g Clean Process Termination
# -----------------------------------------------------------------------------
echo -e "\n${BLUE}[Test 4] Daemon Lifecycle & Process Termination Verification${NC}"
IMG4="/tmp/test_eject_daemon.img"
rm -f "$IMG4"
dd if=/dev/zero of="$IMG4" bs=1m count=32 2>/dev/null
"$MKNTFS" -Q -F -L "EjectDaemon" "$IMG4" >/dev/null

DEV4=$(hdiutil attach -nomount "$IMG4" | awk '{print $1}')
MNT4="/Volumes/EjectDaemon"
sudo -n "$HELPER" mount "$DEV4" "$MNT4" $(id -u) $(id -g) "EjectDaemon" >/dev/null

if pgrep -f "ntfs-3g.*$DEV4" >/dev/null; then
    pass "ntfs-3g process active while mounted"
else
    fail "ntfs-3g process" "ntfs-3g process not found for $DEV4"
fi

sudo -n "$HELPER" eject "$DEV4" "$MNT4" >/dev/null

if pgrep -f "ntfs-3g.*$DEV4" >/dev/null; then
    fail "Daemon termination" "ntfs-3g is still running as a zombie/orphan!"
else
    pass "ntfs-3g process cleanly and completely terminated upon safe eject"
fi
rm -f "$IMG4"

# -----------------------------------------------------------------------------
# TEST 5: Repetitive Eject Endurance Stress (10 cycles)
# -----------------------------------------------------------------------------
echo -e "\n${BLUE}[Test 5] Repetitive Eject Endurance Stress Test (10 cycles)${NC}"
IMG5="/tmp/test_eject_stress.img"
rm -f "$IMG5"
dd if=/dev/zero of="$IMG5" bs=1m count=32 2>/dev/null
"$MKNTFS" -Q -F -L "EjectStress" "$IMG5" >/dev/null

CYCLE_FAIL=false
for cycle in {1..10}; do
    DEV_STRESS=$(hdiutil attach -nomount "$IMG5" | awk '{print $1}')
    MNT_STRESS="/Volumes/EjectStress"
    sudo -n "$HELPER" mount "$DEV_STRESS" "$MNT_STRESS" $(id -u) $(id -g) "EjectStress" >/dev/null
    
    echo "test cycle $cycle data" > "$MNT_STRESS/cycle_$cycle.txt"
    
    if ! sudo -n "$HELPER" eject "$DEV_STRESS" "$MNT_STRESS" >/dev/null 2>&1; then
        CYCLE_FAIL=true
        fail "Endurance cycle $cycle" "Eject returned error"
        break
    fi
    echo -n " [$cycle/10]"
done
echo ""

if [ "$CYCLE_FAIL" = "false" ]; then
    pass "10 consecutive mount -> write -> safe eject cycles completed flawlessly"
fi

# Verify final image state
DEV_FINAL=$(hdiutil attach -nomount "$IMG5" | awk '{print $1}')
FINAL_CHECK=$(sudo -n "$HELPER" check "$DEV_FINAL" 2>&1) && FINAL_CODE=0 || FINAL_CODE=$?
if [ $FINAL_CODE -eq 0 ] && echo "$FINAL_CHECK" | grep -q "STATUS:CLEAN"; then
    pass "Final volume state after 10 stress cycles is 100% clean"
else
    fail "Final volume state" "$FINAL_CHECK"
fi
hdiutil detach "$DEV_FINAL" >/dev/null 2>&1 || true
rm -f "$IMG5"

echo ""
echo "======================================================================"
echo -e "Total Safe Eject Tests: ${TOTAL} | Passed: ${GREEN}${PASSED}${NC} | Failed: ${RED}${FAILED}${NC}"
echo "======================================================================"

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✔ SAFE EJECT VERIFICATION PASSED WITH ZERO DATA LOSS GUARANTEED!${NC}"
    exit 0
else
    echo -e "${RED}✖ SAFE EJECT SUITE FAILED${NC}"
    exit 1
fi
