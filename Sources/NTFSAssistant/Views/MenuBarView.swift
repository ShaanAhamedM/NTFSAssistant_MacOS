import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var diskManager = DiskManager.shared
    @State private var selectedHealthReport: (driveName: String, report: String, isClean: Bool)? = nil
    @State private var isShowingHelperSetup = false
    @State private var helperSetupOutput = ""
    @State private var isSettingUpHelper = false
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Content
            ScrollView {
                VStack(spacing: 12) {
                    if diskManager.drives.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(diskManager.drives) { drive in
                            driveCardView(drive: drive)
                        }
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 400)
            
            Divider()
            
            // Footer & Controls
            footerView
        }
        .frame(width: 380)
        .sheet(item: Binding(
            get: { selectedHealthReport.map { IdentifiableReport(driveName: $0.driveName, report: $0.report, isClean: $0.isClean) } },
            set: { selectedHealthReport = $0.map { ($0.driveName, $0.report, $0.isClean) } }
        )) { item in
            HealthReportSheet(driveName: item.driveName, report: item.report, isClean: item.isClean)
        }
        .alert(isPresented: $diskManager.showAlert) {
            Alert(
                title: Text("Integrity Guard"),
                message: Text(diskManager.alertMessage ?? "Operation halted for safety."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
    
    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .resizable()
                .frame(width: 18, height: 16)
                .foregroundColor(.accentColor)
            
            Text("NTFS Assistant")
                .font(.headline)
            
            Spacer()
            
            // Helper status indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(PrivilegedHelperManager.shared.isSudoersConfigured ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(PrivilegedHelperManager.shared.isSudoersConfigured ? "Daemon Active" : "Setup Needed")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(10)
            
            Button {
                diskManager.scanDrives()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Refresh Connected Drives")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Drive Card View
    private func driveCardView(drive: NTFSDrive) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title & Capacity Row
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: drive.isCrucialX9 ? "bolt.horizontal.fill" : "externaldrive")
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(drive.name)
                            .font(.system(size: 13, weight: .semibold))
                        
                        if drive.isCrucialX9 {
                            Text("Crucial SSD")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.2))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }
                        
                        if drive.isSimulated {
                            Text("Simulated")
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.2))
                                .foregroundColor(.purple)
                                .cornerRadius(4)
                        }
                        
                        if drive.isLowDiskSpace {
                            Text("Low Space")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.2))
                                .foregroundColor(.orange)
                                .cornerRadius(4)
                        }
                    }
                    
                    Text("\(drive.capacityFormatted) (\(drive.freeFormatted) free) • /dev/\(drive.bsdName)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Mode Badge
                HStack(spacing: 4) {
                    if drive.isBusy {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 8, height: 8)
                        Text(drive.statusMessage ?? "Mounting...")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.blue)
                    } else {
                        Circle()
                            .fill(drive.mountMode.badgeColor)
                            .frame(width: 8, height: 8)
                        Text(drive.mountMode.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(drive.mountMode.badgeColor)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background((drive.isBusy ? Color.blue : drive.mountMode.badgeColor).opacity(0.12))
                .cornerRadius(6)
            }
            
            // Mount Location
            if let mp = drive.mountPoint {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(mp)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal") {
                        diskManager.openInFinder(drive: drive)
                    }
                    .font(.caption2)
                    .buttonStyle(.link)
                }
            }
            
            // Dirty / Fast Startup Warning Banner
            if drive.mountMode == .dirtyUnsafe {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fast Startup Lock Detected")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.red)
                        Text("Drive was not shut down cleanly on Windows. Write access is blocked to prevent data corruption.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }
            
            // Action Buttons
            HStack(spacing: 6) {
                if drive.mountMode != .readWrite {
                    Button {
                        diskManager.userRequestedMount(drive: drive)
                    } label: {
                        HStack(spacing: 4) {
                            if drive.isBusy {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "pencil.and.outline")
                            }
                            Text("Mount Read/Write")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(drive.isBusy)
                }
                
                Button {
                    Task {
                        _ = await diskManager.safeEject(drive: drive)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "eject.fill")
                        Text("Safe Eject & Sync")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .disabled(drive.isBusy)
                
                Button {
                    Task {
                        let res = await diskManager.checkVolumeHealth(drive: drive)
                        selectedHealthReport = (drive.name, res.output, res.isClean)
                    }
                } label: {
                    Image(systemName: "stethoscope")
                }
                .buttonStyle(.bordered)
                .disabled(drive.isBusy)
                .help("Check Volume Health (ntfsfix dry-run)")
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
    
    // MARK: - Empty State View
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
                .padding(.top, 8)
            
            VStack(spacing: 4) {
                Text("No NTFS Drives Detected")
                    .font(.system(size: 13, weight: .semibold))
                Text("Connect your Crucial X9 SSD via USB-C to auto-mount with Read & Write access.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            
            Divider()
                .padding(.vertical, 4)
            
            HStack {
                Button("Simulate Crucial X9 (Test)") {
                    diskManager.simulateCrucialX9()
                }
                .font(.system(size: 11))
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 16)
    }
    
    // MARK: - Footer
    private var footerView: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle(isOn: $diskManager.autoMountEnabled) {
                    Text("Auto-Mount R/W on Connect")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                
                Spacer()
                
                Toggle(isOn: $diskManager.safeModeEnabled) {
                    Text("Pre-Mount Guard")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .help("Always run ntfsfix non-destructive integrity check before mounting R/W")
            }
            
            HStack {
                if !PrivilegedHelperManager.shared.isSudoersConfigured {
                    Button {
                        isSettingUpHelper = true
                        PrivilegedHelperManager.shared.installHelperViaAdminPrompt { success, output in
                            isSettingUpHelper = false
                            PrivilegedHelperManager.shared.refreshStatus()
                            diskManager.scanDrives()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isSettingUpHelper {
                                ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                            }
                            Text("Configure Privileged Helper...")
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                }
                
                Spacer()
                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// Helper struct for sheet presentation
private struct IdentifiableReport: Identifiable {
    let id = UUID()
    let driveName: String
    let report: String
    let isClean: Bool
}
