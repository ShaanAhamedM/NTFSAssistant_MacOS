#!/bin/bash
# ==============================================================================
# NTFS Assistant Privileged Mount Helper
# Non-destructive, safe filesystem operations for NTFS drives on macOS.
# Strictly enforces Zero Data Loss and Pre-Mount Integrity Guard.
# ==============================================================================

set -eo pipefail

# Locate binaries (check bundled or standard paths)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Priority lookup for ntfs-3g and ntfsfix
if [ -x "${APP_DIR}/bin/ntfs-3g" ]; then
    NTFS_3G="${APP_DIR}/bin/ntfs-3g"
    NTFS_FIX="${APP_DIR}/bin/ntfsfix"
    NTFS_INFO="${APP_DIR}/bin/ntfsinfo"
    GO_NFSV4="${APP_DIR}/bin/go-nfsv4"
elif [ -x "/usr/local/bin/ntfs-3g" ]; then
    NTFS_3G="/usr/local/bin/ntfs-3g"
    NTFS_FIX="/usr/local/bin/ntfsfix"
    NTFS_INFO="/usr/local/bin/ntfsinfo"
    GO_NFSV4="/usr/local/bin/go-nfsv4"
elif [ -x "/opt/homebrew/bin/ntfs-3g" ]; then
    NTFS_3G="/opt/homebrew/bin/ntfs-3g"
    NTFS_FIX="/opt/homebrew/bin/ntfsfix"
    NTFS_INFO="/opt/homebrew/bin/ntfsinfo"
    GO_NFSV4="/usr/local/bin/go-nfsv4"
else
    NTFS_3G="$(which ntfs-3g 2>/dev/null || true)"
    NTFS_FIX="$(which ntfsfix 2>/dev/null || true)"
    NTFS_INFO="$(which ntfsinfo 2>/dev/null || true)"
    GO_NFSV4="$(which go-nfsv4 2>/dev/null || true)"
fi

# Export FUSE_NFSSRV_PATH if go-nfsv4 is found
if [ -x "${GO_NFSV4}" ]; then
    export FUSE_NFSSRV_PATH="${GO_NFSV4}"
fi

# Set library search paths
export DYLD_FALLBACK_LIBRARY_PATH="${APP_DIR}/lib:/usr/local/lib:/Library/Application Support/fuse-t/lib:/opt/homebrew/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"

ACTION="${1:-}"

validate_device() {
    local dev="$1"
    if [[ ! "${dev}" =~ ^/dev/(r?disk[0-9]+(s[0-9]+)?)$ ]] && [[ ! "${dev}" =~ ^/dev/(disk[0-9]+)$ ]]; then
        echo '{"status":"ERROR","message":"Invalid device node format"}'
        exit 1
    fi
}

validate_mountpoint() {
    local mp="$1"
    if [ -z "${mp}" ] || [[ ! "${mp}" =~ ^/Volumes/.+$ ]] || [[ "${mp}" == *"/.."* ]] || [[ "${mp}" == "/Volumes" ]] || [[ "${mp}" == "/Volumes/" ]]; then
        echo '{"status":"ERROR","message":"Invalid mountpoint (must reside under /Volumes/)"}'
        exit 1
    fi
}

validate_numeric() {
    local val="$1"
    local name="$2"
    if [[ ! "${val}" =~ ^[0-9]+$ ]]; then
        echo "{\"status\":\"ERROR\",\"message\":\"Invalid numeric value for ${name}\"}"
        exit 1
    fi
}

usage() {
    echo "Usage: $0 {check|mount|unmount|eject|remount-ro|status} [args...]"
    exit 1
}

case "${ACTION}" in
    check)
        DEVICE="${2:-}"
        if [ -z "${DEVICE}" ]; then
            echo '{"status":"ERROR","message":"Missing device argument"}'
            exit 1
        fi
        validate_device "${DEVICE}"
        if [ ! -x "${NTFS_FIX}" ]; then
            echo '{"status":"ERROR","message":"ntfsfix binary not found"}'
            exit 1
        fi

        # If currently mounted by macOS, unmount first so ntfsfix doesn't hit "Resource busy"
        WAS_MOUNTED=false
        if /sbin/mount | grep -F "${DEVICE}" >/dev/null 2>&1; then
            WAS_MOUNTED=true
            for attempt in 1 2 3; do
                /usr/sbin/diskutil unmount "${DEVICE}" >/dev/null 2>&1 || true
                if ! /sbin/mount | grep -F "${DEVICE}" >/dev/null 2>&1; then
                    break
                fi
                sleep 0.3
                if [ ${attempt} -ge 2 ]; then
                    /usr/sbin/diskutil unmount force "${DEVICE}" >/dev/null 2>&1 || true
                    sleep 0.4
                fi
            done
        fi

        # Run non-destructive inspection (dry-run check)
        CHECK_OUTPUT=""
        CHECK_EXIT=0
        for fix_attempt in 1 2 3; do
            CHECK_OUTPUT="$("${NTFS_FIX}" -n "${DEVICE}" 2>&1)" && CHECK_EXIT=0 || CHECK_EXIT=$?
            if [ ${CHECK_EXIT} -eq 0 ]; then
                break
            fi
            if echo "${CHECK_OUTPUT}" | grep -qi "resource busy"; then
                sleep 0.4
                /usr/sbin/diskutil unmount force "${DEVICE}" >/dev/null 2>&1 || true
                continue
            fi
            break
        done
        
        # If ntfsinfo is available, also inspect volume flags and state
        INFO_OUTPUT=""
        INFO_EXIT=0
        if [ -n "${NTFS_INFO:-}" ] && [ -x "${NTFS_INFO}" ]; then
            INFO_OUTPUT="$("${NTFS_INFO}" -m "${DEVICE}" 2>&1)" && INFO_EXIT=0 || INFO_EXIT=$?
        fi
        
        COMBINED_REPORT="${CHECK_OUTPUT}
${INFO_OUTPUT}"

        # Restore mount if it was previously mounted
        if [ "${WAS_MOUNTED}" = "true" ]; then
            /usr/sbin/diskutil mount readOnly "${DEVICE}" >/dev/null 2>&1 || true
        fi

        # Check for indicators of Windows Fast Startup, hibernation, unclean unmount, or corrupt volume
        if [ ${CHECK_EXIT} -ne 0 ] || [ ${INFO_EXIT} -ne 0 ] || echo "${COMBINED_REPORT}" | grep -Ei "hibernat|fast startup|unclean|refused to mount|dirty|metadata kept|corrupt|unrecoverable|inconsistent|input/output error|scheduled for check" >/dev/null 2>&1; then
            echo "STATUS:DIRTY"
            echo "${COMBINED_REPORT}"
            exit 2
        else
            echo "STATUS:CLEAN"
            echo "${CHECK_OUTPUT}"
            exit 0
        fi
        ;;

    mount)
        DEVICE="${2:-}"
        MOUNTPOINT="${3:-}"
        TARGET_UID="${4:-$(id -u)}"
        TARGET_GID="${5:-$(id -g)}"
        VOLNAME="${6:-NTFS Disk}"

        if [ -z "${DEVICE}" ] || [ -z "${MOUNTPOINT}" ]; then
            echo '{"status":"ERROR","message":"Missing device or mountpoint"}'
            exit 1
        fi
        validate_device "${DEVICE}"
        validate_mountpoint "${MOUNTPOINT}"
        validate_numeric "${TARGET_UID}" "uid"
        validate_numeric "${TARGET_GID}" "gid"

        # Sanitize volume label to prevent option injection
        VOLNAME="${VOLNAME//[^a-zA-Z0-9 _.-]/}"
        if [ -z "${VOLNAME}" ]; then
            VOLNAME="NTFS Disk"
        fi

        # 1. Safely unmount existing native macOS read-only mount first so the device is free
        for attempt in 1 2 3; do
            if ! /sbin/mount | grep -F "${DEVICE}" >/dev/null 2>&1 && ! /sbin/mount | grep -F "${MOUNTPOINT}" >/dev/null 2>&1; then
                break
            fi
            /usr/sbin/diskutil unmount "${DEVICE}" >/dev/null 2>&1 || true
            /usr/sbin/diskutil unmount force "${DEVICE}" >/dev/null 2>&1 || true
            /usr/sbin/diskutil unmount "${MOUNTPOINT}" >/dev/null 2>&1 || true
            /usr/sbin/diskutil unmount force "${MOUNTPOINT}" >/dev/null 2>&1 || true
            /sbin/umount -f "${MOUNTPOINT}" >/dev/null 2>&1 || true
            sleep 0.3
            if ! /sbin/mount | grep -F "${DEVICE}" >/dev/null 2>&1; then
                break
            fi
        done

        # 2. Pre-Mount Integrity Guard: Never mount dirty, fast-startup, or corrupt volumes as R/W
        CHECK_OUTPUT=""
        CHECK_EXIT=0
        if [ -x "${NTFS_FIX}" ]; then
            for fix_attempt in 1 2 3; do
                CHECK_OUTPUT="$("${NTFS_FIX}" -n "${DEVICE}" 2>&1)" && CHECK_EXIT=0 || CHECK_EXIT=$?
                if [ ${CHECK_EXIT} -eq 0 ]; then
                    break
                fi
                if echo "${CHECK_OUTPUT}" | grep -qi "resource busy"; then
                    sleep 0.4
                    /usr/sbin/diskutil unmount force "${DEVICE}" >/dev/null 2>&1 || true
                    continue
                fi
                break
            done
        fi
        INFO_OUTPUT=""
        INFO_EXIT=0
        if [ -n "${NTFS_INFO:-}" ] && [ -x "${NTFS_INFO}" ]; then
            INFO_OUTPUT="$("${NTFS_INFO}" -m "${DEVICE}" 2>&1)" && INFO_EXIT=0 || INFO_EXIT=$?
        fi
        COMBINED_REPORT="${CHECK_OUTPUT}
${INFO_OUTPUT}"

        if [ ${CHECK_EXIT} -ne 0 ] || [ ${INFO_EXIT} -ne 0 ] || echo "${COMBINED_REPORT}" | grep -Ei "hibernat|fast startup|unclean|refused to mount|dirty|metadata kept|corrupt|unrecoverable|inconsistent|input/output error|scheduled for check" >/dev/null 2>&1; then
            echo "PRE_MOUNT_GUARD_TRIGGERED: Volume contains Windows Fast Startup, uncommitted journal transactions, or filesystem errors."
            echo "${COMBINED_REPORT}"
            # Fallback to Read-Only instantly
            /usr/sbin/diskutil mount readOnly "${DEVICE}" >/dev/null 2>&1 || true
            exit 2
        fi

        # 3. Ensure mount directory exists with proper permissions
        /bin/mkdir -p "${MOUNTPOINT}"
        /usr/sbin/chown "${TARGET_UID}:${TARGET_GID}" "${MOUNTPOINT}" 2>/dev/null || true

        # 4. Invoke ntfs-3g with safe parameters and secure temp log
        MOUNT_OPTS="local,allow_other,auto_xattr,noatime,uid=${TARGET_UID},gid=${TARGET_GID},umask=0022,volname=${VOLNAME}"
        MOUNT_LOG="$(mktemp -t ntfs-mount.XXXXXX)"
        trap 'rm -f "${MOUNT_LOG}"' EXIT
        
        if "${NTFS_3G}" "${DEVICE}" "${MOUNTPOINT}" -o "${MOUNT_OPTS}" >"${MOUNT_LOG}" 2>&1; then
            # Verify mountpoint is active (poll up to 3 seconds for fuse-t NFS loopback)
            IS_MOUNTED=false
            for check_idx in {1..15}; do
                sleep 0.2
                if grep -Ei "falling back to read-only|unsafe state|windows is hibernated|refused to mount|metadata kept" "${MOUNT_LOG}" >/dev/null 2>&1; then
                    break
                fi
                if /sbin/mount | grep -F "${MOUNTPOINT}" >/dev/null 2>&1; then
                    IS_MOUNTED=true
                    break
                fi
            done

            if grep -Ei "falling back to read-only|unsafe state|windows is hibernated|refused to mount|metadata kept" "${MOUNT_LOG}" >/dev/null 2>&1; then
                echo "PRE_MOUNT_GUARD_TRIGGERED: Volume in unsafe state / hibernated. Automatically mounted Read-Only for safety."
                cat "${MOUNT_LOG}"
                rm -f "${MOUNT_LOG}"
                exit 2
            fi

            if [ "${IS_MOUNTED}" = "true" ]; then
                echo "MOUNT_SUCCESS: Read & Write active on ${MOUNTPOINT}"
                rm -f "${MOUNT_LOG}"
                exit 0
            fi
        fi

        # 5. If ntfs-3g failed, trigger Fallback Safety: Revert to native macOS Read-Only
        echo "MOUNT_FAILED: Falling back to native macOS Read-Only..."
        cat "${MOUNT_LOG}" 2>/dev/null || true
        rm -f "${MOUNT_LOG}"
        /usr/sbin/diskutil mount readOnly "${DEVICE}" >/dev/null 2>&1 || true
        exit 1
        ;;

    unmount)
        MOUNTPOINT="${2:-}"
        if [ -z "${MOUNTPOINT}" ]; then
            echo '{"status":"ERROR","message":"Missing mountpoint argument"}'
            exit 1
        fi
        validate_mountpoint "${MOUNTPOINT}"

        # 1. Flush pending filesystem buffers
        /bin/sync

        # 2. Attempt graceful unmount with retries
        UNMOUNT_OK=false
        for retry in 1 2 3; do
            if /usr/sbin/diskutil unmount "${MOUNTPOINT}" >/dev/null 2>&1; then
                UNMOUNT_OK=true
                /bin/rmdir "${MOUNTPOINT}" 2>/dev/null || true
                break
            fi
            sleep 0.4
            /bin/sync
        done

        if [ "${UNMOUNT_OK}" = "true" ]; then
            /bin/sync
            echo "UNMOUNT_SUCCESS"
            exit 0
        else
            BUSY_PROCS=$(/usr/sbin/lsof +D "${MOUNTPOINT}" 2>/dev/null | awk 'NR>1 {print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//')
            if [ -n "${BUSY_PROCS}" ]; then
                echo "UNMOUNT_FAILED_BUSY: Mountpoint is busy. Active processes: ${BUSY_PROCS}"
            else
                echo "UNMOUNT_FAILED"
            fi
            exit 1
        fi
        ;;

    eject)
        DEVICE="${2:-}"
        MOUNTPOINT="${3:-}"
        if [ -z "${DEVICE}" ]; then
            echo '{"status":"ERROR","message":"Missing device argument"}'
            exit 1
        fi
        validate_device "${DEVICE}"

        # 1. Flush all pending writes across the OS before beginning eject sequence
        /bin/sync

        DEV_BASE=$(basename "${DEVICE}")
        PARENT_DISK=$(echo "${DEV_BASE}" | sed -E 's/(disk[0-9]+).*/\1/')

        # 2. Discover all active mountpoints for this device / partitions
        ACTIVE_MOUNTS=()
        if [ -n "${MOUNTPOINT}" ]; then
            validate_mountpoint "${MOUNTPOINT}"
            ACTIVE_MOUNTS+=("${MOUNTPOINT}")
        fi

        # Also inspect running ntfs-3g processes for this disk to catch any other partition mountpoints
        while IFS= read -r line; do
            if [ -n "${line}" ]; then
                MP=$(echo "${line}" | awk '{print $3}')
                if [ -n "${MP}" ] && [ -d "${MP}" ]; then
                    ACTIVE_MOUNTS+=("${MP}")
                fi
            fi
        done < <(ps -eo command 2>/dev/null | grep -E "^.*ntfs-3g /dev/${PARENT_DISK}" || true)

        # 3. Cleanly unmount every active mountpoint without destructive force-kills
        for MP in "${ACTIVE_MOUNTS[@]}"; do
            if /sbin/mount | grep -F " on ${MP} " >/dev/null 2>&1; then
                UNMOUNT_OK=false
                for retry in 1 2 3 4; do
                    /bin/sync
                    if /usr/sbin/diskutil unmount "${MP}" >/dev/null 2>&1; then
                        UNMOUNT_OK=true
                        /bin/rmdir "${MP}" 2>/dev/null || true
                        break
                    fi
                    sleep 0.5
                done

                if [ "${UNMOUNT_OK}" != "true" ]; then
                    # Check for busy processes and refuse to corrupt the drive
                    BUSY_PROCS=$(/usr/sbin/lsof +D "${MP}" 2>/dev/null | awk 'NR>1 {print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//')
                    echo "EJECT_FAILED_BUSY: Drive cannot be safely ejected because files are open by: ${BUSY_PROCS:-unknown application}. Please close open files and try again."
                    exit 1
                fi
            elif [ -d "${MP}" ]; then
                /bin/rmdir "${MP}" 2>/dev/null || true
            fi
        done

        # 4. Wait for ntfs-3g daemon to cleanly write volume clean marker and terminate
        WAIT_COUNT=0
        while pgrep -f "ntfs-3g.*/dev/${PARENT_DISK}" >/dev/null 2>&1 && [ ${WAIT_COUNT} -lt 15 ]; do
            sleep 0.2
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done

        # 5. Flush again to ensure clean NTFS metadata is committed to hardware storage
        /bin/sync

        # 6. Dismount remaining partitions on the physical drive cleanly
        /usr/sbin/diskutil unmountDisk "${DEVICE}" >/dev/null 2>&1 || true

        # 7. Issue hardware eject (flushes drive controller write buffer & safely powers down)
        EJECT_OUTPUT=""
        if EJECT_OUTPUT=$(/usr/sbin/diskutil eject "${DEVICE}" 2>&1); then
            echo "EJECT_SUCCESS"
            exit 0
        else
            echo "EJECT_FAILED: ${EJECT_OUTPUT}"
            exit 1
        fi
        ;;

    remount-ro)
        DEVICE="${2:-}"
        if [ -z "${DEVICE}" ]; then
            echo '{"status":"ERROR","message":"Missing device argument"}'
            exit 1
        fi
        validate_device "${DEVICE}"

        /usr/sbin/diskutil unmount "${DEVICE}" >/dev/null 2>&1 || \
        /usr/sbin/diskutil unmount force "${DEVICE}" >/dev/null 2>&1 || true

        if /usr/sbin/diskutil mount readOnly "${DEVICE}" 2>&1; then
            echo "REMOUNT_RO_SUCCESS"
            exit 0
        else
            echo "REMOUNT_RO_FAILED"
            exit 1
        fi
        ;;

    status)
        echo "NTFS Assistant Helper Active"
        echo "NTFS-3G: ${NTFS_3G:-not found}"
        echo "NTFSFIX: ${NTFS_FIX:-not found}"
        echo "GO-NFSV4: ${GO_NFSV4:-not found}"
        exit 0
        ;;

    *)
        usage
        ;;
esac
