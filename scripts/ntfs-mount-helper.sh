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
        if [ ! -x "${NTFS_FIX}" ]; then
            echo '{"status":"ERROR","message":"ntfsfix binary not found"}'
            exit 1
        fi

        # If currently mounted by macOS, unmount first so ntfsfix doesn't hit "Resource busy"
        WAS_MOUNTED=false
        if /sbin/mount | grep -F "${DEVICE}" >/dev/null 2>&1; then
            WAS_MOUNTED=true
            /usr/sbin/diskutil unmount "${DEVICE}" >/dev/null 2>&1 || true
        fi

        # Run non-destructive inspection (dry-run check)
        CHECK_OUTPUT="$("${NTFS_FIX}" -n "${DEVICE}" 2>&1)" && CHECK_EXIT=0 || CHECK_EXIT=$?
        
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
        if [ ${CHECK_EXIT} -ne 0 ] || [ ${INFO_EXIT} -ne 0 ] || echo "${COMBINED_REPORT}" | grep -Ei "hibernat|fast startup|unclean|refused to mount|dirty|metadata kept|corrupt|unrecoverable|failed|missing|inconsistent|input/output error|scheduled for check" >/dev/null 2>&1; then
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

        # 1. Safely unmount existing native macOS read-only mount first so the device is free
        /usr/sbin/diskutil unmount "${DEVICE}" >/dev/null 2>&1 || true
        /sbin/umount "${MOUNTPOINT}" >/dev/null 2>&1 || true

        # 2. Pre-Mount Integrity Guard: Never mount dirty, fast-startup, or corrupt volumes as R/W
        CHECK_OUTPUT=""
        CHECK_EXIT=0
        if [ -x "${NTFS_FIX}" ]; then
            CHECK_OUTPUT="$("${NTFS_FIX}" -n "${DEVICE}" 2>&1)" && CHECK_EXIT=0 || CHECK_EXIT=$?
        fi
        INFO_OUTPUT=""
        INFO_EXIT=0
        if [ -n "${NTFS_INFO:-}" ] && [ -x "${NTFS_INFO}" ]; then
            INFO_OUTPUT="$("${NTFS_INFO}" -m "${DEVICE}" 2>&1)" && INFO_EXIT=0 || INFO_EXIT=$?
        fi
        COMBINED_REPORT="${CHECK_OUTPUT}
${INFO_OUTPUT}"

        if [ ${CHECK_EXIT} -ne 0 ] || [ ${INFO_EXIT} -ne 0 ] || echo "${COMBINED_REPORT}" | grep -Ei "hibernat|fast startup|unclean|refused to mount|dirty|metadata kept|corrupt|unrecoverable|failed|missing|inconsistent|input/output error|scheduled for check" >/dev/null 2>&1; then
            echo "PRE_MOUNT_GUARD_TRIGGERED: Volume contains Windows Fast Startup, uncommitted journal transactions, or filesystem errors."
            echo "${COMBINED_REPORT}"
            # Fallback to Read-Only instantly
            /usr/sbin/diskutil mount readOnly "${DEVICE}" >/dev/null 2>&1 || true
            exit 2
        fi

        # 3. Ensure mount directory exists with proper permissions
        /bin/mkdir -p "${MOUNTPOINT}"
        /usr/sbin/chown "${TARGET_UID}:${TARGET_GID}" "${MOUNTPOINT}" 2>/dev/null || true

        # 4. Invoke ntfs-3g with safe parameters
        MOUNT_OPTS="local,allow_other,auto_xattr,noatime,uid=${TARGET_UID},gid=${TARGET_GID},umask=0022,volname=${VOLNAME}"
        
        if "${NTFS_3G}" "${DEVICE}" "${MOUNTPOINT}" -o "${MOUNT_OPTS}" >/tmp/ntfs-mount.log 2>&1; then
            # Verify mountpoint is active
            sleep 0.5
            if grep -Ei "falling back to read-only|unsafe state|windows is hibernated|refused to mount|metadata kept" /tmp/ntfs-mount.log >/dev/null 2>&1; then
                echo "PRE_MOUNT_GUARD_TRIGGERED: Volume in unsafe state / hibernated. Automatically mounted Read-Only for safety."
                cat /tmp/ntfs-mount.log
                exit 2
            fi
            if /sbin/mount | grep -F "${MOUNTPOINT}" >/dev/null 2>&1; then
                echo "MOUNT_SUCCESS: Read & Write active on ${MOUNTPOINT}"
                exit 0
            fi
        fi

        # 5. If ntfs-3g failed, trigger Fallback Safety: Revert to native macOS Read-Only
        echo "MOUNT_FAILED: Falling back to native macOS Read-Only..."
        /usr/sbin/diskutil mount readOnly "${DEVICE}" >/dev/null 2>&1 || true
        exit 1
        ;;

    unmount)
        MOUNTPOINT="${2:-}"
        if [ -z "${MOUNTPOINT}" ]; then
            echo '{"status":"ERROR","message":"Missing mountpoint argument"}'
            exit 1
        fi

        # Clean Flush: Flush dirty buffers first
        /bin/sync
        
        # Unmount
        if /usr/sbin/diskutil unmount "${MOUNTPOINT}" >/dev/null 2>&1; then
            /bin/rmdir "${MOUNTPOINT}" 2>/dev/null || true
            echo "UNMOUNT_SUCCESS"
            exit 0
        elif /sbin/umount "${MOUNTPOINT}" >/dev/null 2>&1; then
            /bin/rmdir "${MOUNTPOINT}" 2>/dev/null || true
            echo "UNMOUNT_SUCCESS"
            exit 0
        else
            echo "UNMOUNT_FAILED"
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

        # Clean Flush: Flush all pending writes
        /bin/sync

        # If a mountpoint was specified, unmount it first
        if [ -n "${MOUNTPOINT}" ] && [ -d "${MOUNTPOINT}" ]; then
            /usr/sbin/diskutil unmount "${MOUNTPOINT}" >/dev/null 2>&1 || true
            /sbin/umount "${MOUNTPOINT}" >/dev/null 2>&1 || true
            /bin/rmdir "${MOUNTPOINT}" 2>/dev/null || true
        fi

        # Unmount any active FUSE-T mounts
        while IFS= read -r line; do
            if [ -n "${line}" ]; then
                MP=$(echo "${line}" | awk -F ' on | \\(' '{print $2}')
                if [ -n "${MP}" ] && [ -d "${MP}" ]; then
                    /sbin/umount "${MP}" >/dev/null 2>&1 || /usr/sbin/diskutil unmount "${MP}" >/dev/null 2>&1 || true
                    /bin/rmdir "${MP}" 2>/dev/null || true
                fi
            fi
        done < <(/sbin/mount | grep -F "fuse-t:")

        # Dismount partitions and eject hardware safely
        /usr/sbin/diskutil unmountDisk "${DEVICE}" >/dev/null 2>&1 || true
        /usr/sbin/diskutil unmount "${DEVICE}" >/dev/null 2>&1 || true
        
        sleep 0.5

        if /usr/sbin/diskutil eject "${DEVICE}" 2>&1; then
            echo "EJECT_SUCCESS"
            exit 0
        else
            echo "EJECT_FAILED"
            exit 1
        fi
        ;;

    remount-ro)
        DEVICE="${2:-}"
        if [ -z "${DEVICE}" ]; then
            echo '{"status":"ERROR","message":"Missing device argument"}'
            exit 1
        fi

        /bin/sync
        /usr/sbin/diskutil unmount "${DEVICE}" >/dev/null 2>&1 || true
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
