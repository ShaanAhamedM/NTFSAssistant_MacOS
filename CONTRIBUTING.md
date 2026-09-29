# Contributing to NTFS Assistant

Thank you for your interest in contributing to **NTFS Assistant**! We welcome contributions that help improve performance, usability, and stability while upholding our foundational priority: **Zero Data Loss**.

---

## 🛡️ Core Rule: Non-Negotiable Data Safety

This application interacts directly with external storage drives that often contain users' sole copies of personal data. All contributions must strictly adhere to the following safety rules:

1. **No Raw Filesystem Writes**: Never implement or use unverified raw write logic. All filesystem writes must go through `ntfs-3g` connected via `fuse-t`.
2. **Pre-Mount Integrity Guard**: Under no circumstances should write access be granted to a volume with an unclean unmount, Windows Fast Startup flag, or active hibernation state (`hiberfil.sys`).
3. **Clean Flush Sequence**: The unmount and ejection sequences must always flush dirty buffers (`sync`) to persistent media before disconnecting.
4. **Failsafe Fallback**: Any mount failure must safely and immediately revert to Apple's native read-only mount.

---

## 🛠️ Development Setup

### Prerequisites
- macOS 13.0+ (Ventura, Sonoma, Sequoia, Tahoe)
- Xcode Command Line Tools (`xcode-select --install`)
- Swift 5.9+ / 6.0 toolchain
- Homebrew

### Building the Project
Clone the repository and build using Swift Package Manager:
```bash
git clone https://github.com/ShaanAhamedM/NTFSAssistant_MacOS.git
cd NTFSAssistant_MacOS

# Build debug binary
swift build

# Build release binary and package the application bundle
./scripts/package_app.sh
```

### Running Tests
Execute the automated test suite before opening any pull request:
```bash
./scripts/run_all_tests.sh
```

---

## 📋 Pull Request Process

1. **Fork the Repository**: Create a feature branch from `main` (e.g., `git checkout -b feature/better-diagnostics`).
2. **Verify Concurrency & Memory**: Ensure Swift strict concurrency checks pass without data races (`swift build -Xswiftc -strict-concurrency=complete`).
3. **Run Safety Invariant Tests**: Run the full disk simulation suite (`./scripts/run_all_tests.sh`). All tests must pass 100%.
4. **Commit Messages**: Use simple, plain-English commit messages in the active present tense (e.g., `Fix volume name escaping when spaces are present`).
5. **Open Pull Request**: Submit your pull request with a clear description of the problem solved and test results.

---

## 💬 Community and Code of Conduct

Please be respectful, constructive, and helpful in all interactions within this project's issues, discussions, and pull requests.
