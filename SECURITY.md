# Security Policy

The security and integrity of your data are our highest priorities.

## Supported Versions

| Version | Supported          |
| :---    | :---               |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

---

## 🔒 Security Architecture

**NTFS Assistant** relies on a least-privilege architecture:
1. **User-Space UI & Daemon**: The Menu Bar app runs completely unprivileged under the user's desktop session.
2. **Minimal Privileged Helper**: Only filesystem mount, unmount, health check, and ejection commands are delegated to `/Library/Application Support/NTFSAssistant/ntfs-mount-helper`.
3. **Restricted Sudoers Rule**: The `/etc/sudoers.d/ntfs-assistant` rule strictly grants execution rights for the helper script and required mount binaries, disallowing arbitrary root commands.
4. **No Kernel Extensions**: Utilizes `fuse-t`, which operates entirely in user space via the native macOS NFS client, preserving Apple's System Integrity Protection (SIP).

---

## 🚨 Reporting a Vulnerability or Data Corruption Risk

If you discover a security vulnerability or a condition under which data loss could occur:

1. **Do NOT report it in public GitHub Issues.**
2. Email the maintainer directly at: `115361854+ShaanAhamedM@users.noreply.github.com` with the subject:
   `[SECURITY] NTFS Assistant Vulnerability Report`
3. Include:
   - Steps to reproduce the issue.
   - macOS version, architecture, and disk model.
   - Diagnostic output or system logs (`log show --predicate 'process == "NTFSAssistant"'`).
4. **Response Timeline**:
   - Initial acknowledgement within 48 hours.
   - Status update or patch timeline within 7 days.
   - Coordinated public disclosure once a safe patch is released.
