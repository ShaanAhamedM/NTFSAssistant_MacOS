#!/bin/bash
# ==============================================================================
# NTFS Assistant - Full Industrial Endurance & Stress Test Suite
# Runs deep stress loops: 100-cycle endurance, 500MB payload integrity,
# extreme UTF-8 filenames, concurrent I/O resistance, and leaks profiling.
# Strictly operates on isolated loopback disk images (/tmp/*.img)
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="/Library/Application Support/NTFSAssistant/ntfs-mount-helper"
MKNTFS="${REPO_DIR}/bin/mkntfs"
NTFSFIX="${REPO_DIR}/bin/ntfsfix"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

pass() {
    echo -e "  ${GREEN}✔ PASS:${NC} $1"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

fail() {
    echo -e "  ${RED}✖ FAIL:${NC} $1 - $2"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

cleanup() {
    for dev in $(hdiutil info | grep -E "endurance_.*\.img" | awk '{print $1}'); do
        hdiutil detach "$dev" -force >/dev/null 2>&1 || true
    done
    rm -f /tmp/endurance_*.img /tmp/endurance_*.bin
}
trap cleanup EXIT

echo "======================================================================"
echo -e "${BLUE}  NTFS Assistant: Extended Multi-Hour Industrial Endurance Suite${NC}"
echo "======================================================================"
echo "Host OS: $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
echo "Timestamp: $(date)"
echo ""

# -----------------------------------------------------------------------------
# SUITE 1: Extreme UTF-8, Emoji, and International Filenames
# -----------------------------------------------------------------------------
echo -e "${CYAN}[Suite 1/5] Extreme UTF-8, Emoji & International Filename Fuzzing${NC}"
IMG_UTF="/tmp/endurance_utf8.img"
rm -f "$IMG_UTF"
dd if=/dev/zero of="$IMG_UTF" bs=1m count=48 2>/dev/null
"$MKNTFS" -Q -F -L "UTF8Test" "$IMG_UTF" >/dev/null

DEV_UTF=$(hdiutil attach -nomount "$IMG_UTF" | awk '{print $1}')
MNT_UTF="/Volumes/UTF8Test"
sudo -n "$HELPER" mount "$DEV_UTF" "$MNT_UTF" $(id -u) $(id -g) "UTF8Test" >/dev/null

# Test cases
FILES=(
    "🚀_Rocket_Crucial_SSD_⚡️_Data.txt:Emoji Payload 1"
    "测试文件_数据安全_保证_CrucialX9.doc:Chinese Characters Payload"
    "ملف_اختبار_البيانات_العربية_NTFS.pdf:Arabic Text Payload"
    "डेटा_सुरक्षा_परीक्षण_दस्तावेज़.dat:Hindi Unicode Payload"
    "File with (spaces) and 'single quotes' and #hash!.log:Special ASCII Chars"
    "Russian_Документ_Проверка_Целостности.txt:Cyrillic Script Payload"
    "Japanese_テスト_データ_整合性.txt:Japanese Kanji/Katakana Payload"
)

ALL_UTF_MATCH=true
for entry in "${FILES[@]}"; do
    FILENAME=$(echo "$entry" | cut -d':' -f1)
    CONTENT=$(echo "$entry" | cut -d':' -f2)
    
    echo "$CONTENT" > "$MNT_UTF/$FILENAME"
    READ_BACK=$(cat "$MNT_UTF/$FILENAME" 2>/dev/null || echo "READ_ERROR")
    if [ "$READ_BACK" != "$CONTENT" ]; then
        ALL_UTF_MATCH=false
        fail "UTF-8 write/read" "Mismatch in '$FILENAME'"
        break
    fi
done

if [ "$ALL_UTF_MATCH" = "true" ]; then
    pass "All international UTF-8, emoji, and punctuation filenames written and verified 100%"
fi

# Test 240-char max filename
LONG_NAME="$(printf 'A%.0s' {1..240}).txt"
echo "Max length test payload" > "$MNT_UTF/$LONG_NAME"
if [ "$(cat "$MNT_UTF/$LONG_NAME")" = "Max length test payload" ]; then
    pass "240-character maximum length filename created and read back successfully"
else
    fail "240-char filename" "Failed to read back long filename"
fi

sudo -n "$HELPER" eject "$DEV_UTF" "$MNT_UTF" >/dev/null
rm -f "$IMG_UTF"

# -----------------------------------------------------------------------------
# SUITE 2: Concurrent Multi-Threaded I/O under Eject Pressure
# -----------------------------------------------------------------------------
echo -e "\n${CYAN}[Suite 2/5] Concurrent Multi-Threaded I/O & Open Handle Rejection${NC}"
IMG_CONC="/tmp/endurance_conc.img"
rm -f "$IMG_CONC"
dd if=/dev/zero of="$IMG_CONC" bs=1m count=64 2>/dev/null
"$MKNTFS" -Q -F -L "ConcTest" "$IMG_CONC" >/dev/null

DEV_CONC=$(hdiutil attach -nomount "$IMG_CONC" | awk '{print $1}')
MNT_CONC="/Volumes/ConcTest"
sudo -n "$HELPER" mount "$DEV_CONC" "$MNT_CONC" $(id -u) $(id -g) "ConcTest" >/dev/null

# Spawn 4 concurrent writer processes with persistent open file handles
WORKER_PIDS=()
for w in {1..4}; do
    python3 -c '
import sys, time
filepath = sys.argv[1]
with open(filepath, "w") as f:
    for step in range(50):
        f.write(f"Worker data step {step}\n")
        f.flush()
        time.sleep(0.08)
' "$MNT_CONC/worker_${w}.log" &
    WORKER_PIDS+=($!)
done

sleep 0.5
# Attempt Safe Eject while all 4 background workers are actively writing
CONC_EJECT_OUT=$(sudo -n "$HELPER" eject "$DEV_CONC" "$MNT_CONC" 2>&1 || true)

if echo "$CONC_EJECT_OUT" | grep -q "EJECT_FAILED_BUSY"; then
    pass "Concurrent safety: Eject strictly refused while parallel threads were writing"
else
    fail "Concurrent eject rejection" "Helper did not block eject as expected: $CONC_EJECT_OUT"
fi

# Wait for all workers to finish cleanly
for pid in "${WORKER_PIDS[@]}"; do
    wait $pid || true
done
sleep 0.5

# Eject cleanly now that processes have completed
CLEAN_CONC_EJECT=$(sudo -n "$HELPER" eject "$DEV_CONC" "$MNT_CONC" 2>&1)
if echo "$CLEAN_CONC_EJECT" | grep -q "EJECT_SUCCESS"; then
    pass "Safe Eject completed with EJECT_SUCCESS after parallel workers terminated"
else
    fail "Eject after parallel finish" "$CLEAN_CONC_EJECT"
fi

# Re-attach and check volume integrity
DEV_CONC_RE=$(hdiutil attach -nomount "$IMG_CONC" | awk '{print $1}')
CONC_CHECK=$(sudo -n "$HELPER" check "$DEV_CONC_RE" 2>&1)
if echo "$CONC_CHECK" | grep -q "STATUS:CLEAN"; then
    pass "Volume integrity intact with STATUS:CLEAN after parallel write stress"
else
    fail "Post-concurrent volume state" "$CONC_CHECK"
fi
hdiutil detach "$DEV_CONC_RE" >/dev/null 2>&1 || true
rm -f "$IMG_CONC"

# -----------------------------------------------------------------------------
# SUITE 3: Large File Payload (500MB) SHA-256 Integrity Verification
# -----------------------------------------------------------------------------
echo -e "\n${CYAN}[Suite 3/5] Large File Payload (500MB) Bit-for-Bit Integrity Check${NC}"
IMG_LARGE="/tmp/endurance_large.img"
rm -f "$IMG_LARGE"
# 1.2GB volume image
dd if=/dev/zero of="$IMG_LARGE" bs=1m count=1200 2>/dev/null
"$MKNTFS" -Q -F -L "LargeTest" "$IMG_LARGE" >/dev/null

DEV_LARGE=$(hdiutil attach -nomount "$IMG_LARGE" | awk '{print $1}')
MNT_LARGE="/Volumes/LargeTest"
sudo -n "$HELPER" mount "$DEV_LARGE" "$MNT_LARGE" $(id -u) $(id -g) "LargeTest" >/dev/null

echo "  -> Generating and streaming 500MB pseudo-random binary payload..."
LARGE_PAYLOAD="$MNT_LARGE/large_500mb_sample.bin"
dd if=/dev/urandom of="$LARGE_PAYLOAD" bs=1m count=500 2>/dev/null
echo "  -> Computing source SHA-256 hash..."
SRC_HASH=$(shasum -a 256 "$LARGE_PAYLOAD" | awk '{print $1}')
echo "     Source SHA256: ${SRC_HASH}"

# Trigger Safe Eject
echo "  -> Ejecting volume and flushing dirty buffers..."
sudo -n "$HELPER" eject "$DEV_LARGE" "$MNT_LARGE" >/dev/null
pass "500MB write payload flushed and safely ejected"

# Re-attach raw disk and verify with ntfsfix
DEV_LARGE_RE=$(hdiutil attach -nomount "$IMG_LARGE" | awk '{print $1}')
CHECK_LARGE=$(sudo -n "$HELPER" check "$DEV_LARGE_RE" 2>&1)
if echo "$CHECK_LARGE" | grep -q "STATUS:CLEAN"; then
    pass "Pre-Mount Guard verified 500MB volume as STATUS:CLEAN after eject"
else
    fail "500MB post-eject check" "$CHECK_LARGE"
fi

# Re-mount and read back payload
sudo -n "$HELPER" mount "$DEV_LARGE_RE" "$MNT_LARGE" $(id -u) $(id -g) "LargeTest" >/dev/null
echo "  -> Computing destination SHA-256 hash..."
DEST_HASH=$(shasum -a 256 "$MNT_LARGE/large_500mb_sample.bin" | awk '{print $1}')
echo "     Destination SHA256: ${DEST_HASH}"

if [ "$SRC_HASH" = "$DEST_HASH" ]; then
    pass "100% BIT-FOR-BIT INTEGRITY VERIFIED: 500MB file matches perfectly (${DEST_HASH:0:16}...)"
else
    fail "Large file integrity" "Hash mismatch: Expected $SRC_HASH, got $DEST_HASH"
fi

sudo -n "$HELPER" eject "$DEV_LARGE_RE" "$MNT_LARGE" >/dev/null
rm -f "$IMG_LARGE"

# -----------------------------------------------------------------------------
# SUITE 4: Memory Leak & Resident Set Size (RSS) Profiling
# -----------------------------------------------------------------------------
echo -e "\n${CYAN}[Suite 4/5] Memory Leak & Process Stability Profiling${NC}"
APP_PID=$(pgrep -x NTFSAssistant | head -n1 || echo "")

if [ -n "$APP_PID" ]; then
    echo "  -> Profiling running NTFSAssistant process (PID ${APP_PID})..."
    
    # Check if process is leaking heap memory in app domain (after report header)
    APP_LEAKS=$(leaks "$APP_PID" 2>&1 | sed -n '/<< TOTAL >>/,$p' | grep -E "NTFSAssistant|DiskManager|NTFSDrive" || true)
    if [ -z "$APP_LEAKS" ]; then
        pass "Zero memory leaks in NTFSAssistant application code"
    else
        fail "Memory leak in app code" "$APP_LEAKS"
    fi
    
    # Measure Resident Set Size (RSS) and Physical Footprint
    RSS_KB=$(ps -o rss= -p "$APP_PID" 2>/dev/null | awk '{print $1}' || echo "0")
    RSS_MB=$((RSS_KB / 1024))
    echo "  -> Resident Set Size (RSS): ${RSS_MB} MB"
    
    # Ensure app stays lightweight (under 100MB resident footprint for native SwiftUI application)
    if [ "$RSS_MB" -lt 100 ]; then
        pass "Memory footprint is optimal and within target bounds (${RSS_MB}MB < 100MB)"
    else
        fail "Memory footprint high" "RSS is ${RSS_MB}MB (exceeds 100MB target)"
    fi
else
    echo "  ⚠ NTFSAssistant app not currently running. Skipping live leaks inspection."
fi

# -----------------------------------------------------------------------------
# SUITE 5: Extended 100-Cycle Endurance Mount / Write / Eject Stress Loop
# -----------------------------------------------------------------------------
echo -e "\n${CYAN}[Suite 5/5] Extended 100-Cycle Endurance Stress Loop${NC}"
IMG_ENDURANCE="/tmp/endurance_100.img"
rm -f "$IMG_ENDURANCE"
dd if=/dev/zero of="$IMG_ENDURANCE" bs=1m count=32 2>/dev/null
"$MKNTFS" -Q -F -L "Endurance100" "$IMG_ENDURANCE" >/dev/null

START_TIME=$(date +%s)
FAILED_CYCLES=0

for cycle in {1..100}; do
    DEV_LOOP=$(hdiutil attach -nomount "$IMG_ENDURANCE" | awk '{print $1}')
    MNT_LOOP="/Volumes/Endurance100"
    
    if ! sudo -n "$HELPER" mount "$DEV_LOOP" "$MNT_LOOP" $(id -u) $(id -g) "Endurance100" >/dev/null 2>&1; then
        FAILED_CYCLES=$((FAILED_CYCLES + 1))
        fail "Cycle $cycle" "Mount failed"
        break
    fi
    
    # Write randomized data and verify immediate read
    PAYLOAD_DATA="Cycle ${cycle} timestamp $(date) random $(head -c 64 /dev/urandom | base64)"
    echo "$PAYLOAD_DATA" > "$MNT_LOOP/cycle_${cycle}.txt"
    
    if [ "$(cat "$MNT_LOOP/cycle_${cycle}.txt" 2>/dev/null)" != "$PAYLOAD_DATA" ]; then
        FAILED_CYCLES=$((FAILED_CYCLES + 1))
        fail "Cycle $cycle" "Data readback failed"
        sudo -n "$HELPER" eject "$DEV_LOOP" "$MNT_LOOP" >/dev/null 2>&1 || true
        break
    fi
    
    if ! sudo -n "$HELPER" eject "$DEV_LOOP" "$MNT_LOOP" >/dev/null 2>&1; then
        FAILED_CYCLES=$((FAILED_CYCLES + 1))
        fail "Cycle $cycle" "Eject failed"
        break
    fi
    
    # Allow kernel disk arbitration to settle between rapid cycles
    sleep 0.1
    
    if [ $((cycle % 10)) -eq 0 ]; then
        echo -n " [${cycle}/100]"
    fi
done
echo ""

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ $FAILED_CYCLES -eq 0 ]; then
    pass "100 consecutive mount -> write -> read -> eject cycles completed flawlessly in ${DURATION}s"
else
    fail "Endurance 100 cycles" "Encountered ${FAILED_CYCLES} cycle failures"
fi

# Final post-endurance volume health verification
DEV_END_FINAL=$(hdiutil attach -nomount "$IMG_ENDURANCE" | awk '{print $1}')
FINAL_CHECK=$(sudo -n "$HELPER" check "$DEV_END_FINAL" 2>&1)
if echo "$FINAL_CHECK" | grep -q "STATUS:CLEAN"; then
    pass "Volume health is 100% CLEAN after 100 complete stress cycles"
else
    fail "Final volume health" "$FINAL_CHECK"
fi
hdiutil detach "$DEV_END_FINAL" >/dev/null 2>&1 || true
rm -f "$IMG_ENDURANCE"

echo ""
echo "======================================================================"
echo -e "Total Endurance Tests: ${TOTAL_TESTS} | Passed: ${GREEN}${PASSED_TESTS}${NC} | Failed: ${RED}${FAILED_TESTS}${NC}"
echo "======================================================================"

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}✔ ALL INDUSTRIAL ENDURANCE & STRESS TESTS PASSED WITH 100% ZERO-DATA-LOSS!${NC}"
    exit 0
else
    echo -e "${RED}✖ ENDURANCE SUITE FAILED${NC}"
    exit 1
fi
