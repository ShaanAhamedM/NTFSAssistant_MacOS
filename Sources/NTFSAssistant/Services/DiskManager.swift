import Foundation
import Cocoa
@preconcurrency import DiskArbitration
import Combine
import UserNotifications

public final class DiskManager: ObservableObject, @unchecked Sendable {
    public static let shared = DiskManager()
    
    @Published public var drives: [NTFSDrive] = []
    @Published public var isScanning: Bool = false
    @Published public var autoMountEnabled: Bool = true
    @Published public var safeModeEnabled: Bool = true
    @Published public var alertMessage: String? = nil
    @Published public var showAlert: Bool = false
    
    private var daSession: DASession?
    private var cancellables = Set<AnyCancellable>()
    private var scanTimer: Timer?
    private let queue = DispatchQueue(label: "com.ntfsassistant.diskmanager", qos: .userInitiated)
    
    private init() {
        setupDiskArbitration()
        setupWorkspaceNotifications()
        startPeriodicScan()
        scanDrives()
    }
    
    deinit {
        scanTimer?.invalidate()
        if let session = daSession {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
    }
    
    // MARK: - Disk Arbitration Setup
    private func setupDiskArbitration() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            print("Failed to initialize DASession")
            return
        }
        self.daSession = session
        
        let diskAppearedCallback: DADiskAppearedCallback = { disk, context in
            guard let context = context else { return }
            let manager = Unmanaged<DiskManager>.fromOpaque(context).takeUnretainedValue()
            manager.handleDiskAppeared(disk: disk)
        }
        
        let diskDisappearedCallback: DADiskDisappearedCallback = { disk, context in
            guard let context = context else { return }
            let manager = Unmanaged<DiskManager>.fromOpaque(context).takeUnretainedValue()
            manager.handleDiskDisappeared(disk: disk)
        }
        
        let diskDescriptionChangedCallback: DADiskDescriptionChangedCallback = { disk, keys, context in
            guard let context = context else { return }
            let manager = Unmanaged<DiskManager>.fromOpaque(context).takeUnretainedValue()
            manager.handleDiskChanged(disk: disk)
        }
        
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, diskAppearedCallback, selfPointer)
        DARegisterDiskDisappearedCallback(session, nil, diskDisappearedCallback, selfPointer)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, diskDescriptionChangedCallback, selfPointer)
        
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }
    
    private func setupWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scanDrives()
        }
        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scanDrives()
        }
        center.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scanDrives()
        }
    }
    
    private func startPeriodicScan() {
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.scanDrives()
        }
    }
    
    private func handleDiskAppeared(disk: DADisk) {
        if let desc = DADiskCopyDescription(disk) as? [String: Any],
           let bsdName = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String {
            queue.async { [weak self] in
                self?.inspectAndAddDisk(bsdName: bsdName, triggeredByConnect: true)
            }
        }
    }
    
    private func handleDiskDisappeared(disk: DADisk) {
        if let desc = DADiskCopyDescription(disk) as? [String: Any],
           let bsdName = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String {
            DispatchQueue.main.async { [weak self] in
                self?.drives.removeAll { $0.bsdName == bsdName || $0.parentDevice == bsdName }
            }
        }
    }
    
    private func handleDiskChanged(disk: DADisk) {
        scanDrives()
    }
    
    // MARK: - Drive Scanning & Inspection
    public func scanDrives() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Run diskutil list -plist to enumerate volumes
            let task = Process()
            task.launchPath = "/usr/sbin/diskutil"
            task.arguments = ["list", "-plist"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                
                if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                   let allDisksAndPartitions = plist["AllDisksAndPartitions"] as? [[String: Any]] {
                    
                    var discoveredDrives: [NTFSDrive] = []
                    
                    for diskEntry in allDisksAndPartitions {
                        let parentDisk = diskEntry["DeviceIdentifier"] as? String ?? ""
                        if let partitions = diskEntry["Partitions"] as? [[String: Any]] {
                            for part in partitions {
                                if let bsdName = part["DeviceIdentifier"] as? String {
                                    if let drive = self.evaluatePartition(bsdName: bsdName, parentDevice: parentDisk) {
                                        discoveredDrives.append(drive)
                                    }
                                }
                            }
                        }
                    }
                    
                    let finalDiscovered = discoveredDrives
                    
                    DispatchQueue.main.async {
                        // Preserve existing drive states or update
                        var updatedList: [NTFSDrive] = []
                        for discovered in finalDiscovered {
                            if let existingIndex = self.drives.firstIndex(where: { $0.bsdName == discovered.bsdName }) {
                                var drive = discovered
                                drive.isBusy = self.drives[existingIndex].isBusy
                                drive.healthState = self.drives[existingIndex].healthState
                                drive.lastHealthReport = self.drives[existingIndex].lastHealthReport
                                updatedList.append(drive)
                            } else {
                                updatedList.append(discovered)
                                // New NTFS drive connected!
                                if self.autoMountEnabled && discovered.mountMode == .readOnly {
                                    self.triggerAutoMount(for: discovered)
                                }
                            }
                        }
                        
                        // Preserve any simulated drives during testing
                        let simulated = self.drives.filter { $0.isSimulated }
                        self.drives = updatedList + simulated
                    }
                }
            } catch {
                print("Error scanning disks: \(error)")
            }
        }
    }
    
    private func evaluatePartition(bsdName: String, parentDevice: String) -> NTFSDrive? {
        let task = Process()
        task.launchPath = "/usr/sbin/diskutil"
        task.arguments = ["info", "-plist", bsdName]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            
            guard let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                return nil
            }
            
            let fileSystemType = info["FilesystemType"] as? String ?? ""
            let fileSystemName = info["FilesystemName"] as? String ?? ""
            let typeBundle = info["Type"] as? String ?? ""
            let isInternal = info["Internal"] as? Bool ?? false
            
            // Strictly detect NTFS volumes
            let isNTFS = fileSystemType.lowercased().contains("ntfs") ||
                         fileSystemName.lowercased().contains("ntfs") ||
                         typeBundle.lowercased().contains("ntfs")
            
            if !isNTFS {
                return nil
            }
            
            let volumeName = info["VolumeName"] as? String ?? (info["MediaName"] as? String ?? "Crucial X9 SSD")
            let totalBytes = info["TotalSize"] as? Int64 ?? 1_000_000_000_000
            let freeBytes = info["FreeSpace"] as? Int64 ?? 0
            
            // Check all active mounts from /sbin/mount (detects both native and fuse-t NFS mounts)
            let mountCheckTask = Process()
            mountCheckTask.launchPath = "/sbin/mount"
            let mountPipe = Pipe()
            mountCheckTask.standardOutput = mountPipe
            try? mountCheckTask.run()
            let mountData = mountPipe.fileHandleForReading.readDataToEndOfFile()
            mountCheckTask.waitUntilExit()
            let mountOutput = String(data: mountData, encoding: .utf8) ?? ""
            let mountLines = mountOutput.components(separatedBy: "\n")
            
            var isMounted = false
            var detectedMountPoint: String? = info["MountPoint"] as? String
            var currentMode: MountMode = .unmounted
            
            let bsdNode = "/dev/\(bsdName)"
            let expectedVolumeMount = "/Volumes/\(volumeName)"
            
            for line in mountLines {
                let containsDevice = line.contains(bsdNode)
                let containsFuseT = (line.hasPrefix("fuse-t:") || line.contains("fuse")) && (line.contains(expectedVolumeMount) || line.contains(volumeName))
                
                if containsDevice || containsFuseT {
                    isMounted = true
                    if let onRange = line.range(of: " on "),
                       let parenRange = line.range(of: " (", range: onRange.upperBound..<line.endIndex) {
                        detectedMountPoint = String(line[onRange.upperBound..<parenRange.lowerBound])
                    } else {
                        detectedMountPoint = expectedVolumeMount
                    }
                    
                    if containsFuseT || line.contains("osxfuse") || line.contains("fuse-t") {
                        currentMode = .readWrite
                    } else if line.contains("read-only") {
                        currentMode = .readOnly
                    } else {
                        currentMode = .readWrite
                    }
                    break
                }
            }
            
            return NTFSDrive(
                id: bsdName,
                bsdName: bsdName,
                parentDevice: parentDevice,
                name: volumeName.isEmpty ? "Crucial X9" : volumeName,
                totalBytes: totalBytes,
                freeBytes: freeBytes,
                mountPoint: detectedMountPoint,
                isMounted: isMounted,
                isInternal: isInternal,
                filesystem: "NTFS",
                mountMode: currentMode,
                healthState: .unknown,
                isSimulated: false
            )
        } catch {
            return nil
        }
    }
    
    private func inspectAndAddDisk(bsdName: String, triggeredByConnect: Bool) {
        let parentDevice = bsdName.components(separatedBy: "s").first ?? bsdName
        if let drive = evaluatePartition(bsdName: bsdName, parentDevice: parentDevice) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                    self.drives[idx] = drive
                } else {
                    self.drives.append(drive)
                    if triggeredByConnect && self.autoMountEnabled && drive.mountMode == .readOnly {
                        self.triggerAutoMount(for: drive)
                    }
                }
            }
        }
    }
    
    // MARK: - Automount & R/W Mount Workflow
    public func triggerAutoMount(for drive: NTFSDrive) {
        Task {
            await mountReadWrite(drive: drive, isAutoMount: true)
        }
    }
    
    public func mountReadWrite(drive: NTFSDrive, isAutoMount: Bool = false) async -> Bool {
        setBusy(for: drive.bsdName, isBusy: true)
        
        // Simulated drive handling
        if drive.isSimulated {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            DispatchQueue.main.async {
                if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                    self.drives[idx].mountMode = .readWrite
                    self.drives[idx].isMounted = true
                    self.drives[idx].mountPoint = "/Volumes/\(self.drives[idx].name)"
                    self.drives[idx].isBusy = false
                    self.notifyUser(title: "Crucial X9 (Simulated)", message: "Mounted with full Read & Write access.")
                }
            }
            return true
        }
        
        let devicePath = "/dev/\(drive.bsdName)"
        let volumeName = drive.name.isEmpty ? "Crucial X9" : drive.name
        let mountPoint = "/Volumes/\(volumeName)"
        let uid = String(getuid())
        let gid = String(getgid())
        let helper = PrivilegedHelperManager.shared
        
        // Helper unmounts read-only mount first, runs Pre-Mount Integrity Guard (ntfsfix -n),
        // and mounts via ntfs-3g if clean. If dirty, helper instantly remounts read-only.
        let result = await helper.executeHelper(arguments: ["mount", devicePath, mountPoint, uid, gid, volumeName])
        
        if result.status == 0 {
            DispatchQueue.main.async {
                if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                    self.drives[idx].mountMode = .readWrite
                    self.drives[idx].isMounted = true
                    self.drives[idx].mountPoint = mountPoint
                    self.drives[idx].healthState = .clean
                    self.drives[idx].isBusy = false
                }
                self.notifyUser(title: "\(volumeName) Ready", message: "Mounted with full Read & Write access.")
            }
            scanDrives()
            return true
        } else if result.status == 2 {
            // Pre-Mount Guard blocked write due to Fast Startup or dirty flag
            DispatchQueue.main.async {
                if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                    self.drives[idx].mountMode = .dirtyUnsafe
                    self.drives[idx].healthState = .dirty
                    self.drives[idx].lastHealthReport = result.output
                    self.drives[idx].isBusy = false
                }
                self.showIntegrityGuardAlert(driveName: volumeName, report: result.output)
            }
            scanDrives()
            return false
        } else {
            // General mount error, fell back to read-only
            DispatchQueue.main.async {
                if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                    self.drives[idx].mountMode = .readOnly
                    self.drives[idx].isBusy = false
                }
                self.notifyUser(title: "\(volumeName) Fallback", message: "R/W mount failed. Safely reverted to native Read-Only access.")
            }
            scanDrives()
            return false
        }
    }
    
    // MARK: - Safe Eject Sequence
    public func safeEject(drive: NTFSDrive) async -> Bool {
        setBusy(for: drive.bsdName, isBusy: true)
        
        if drive.isSimulated {
            try? await Task.sleep(nanoseconds: 800_000_000)
            DispatchQueue.main.async {
                self.drives.removeAll { $0.bsdName == drive.bsdName }
                self.notifyUser(title: "Safe Eject", message: "\(drive.name) safely ejected.")
            }
            return true
        }
        
        let devicePath = "/dev/\(drive.parentDevice)"
        let mountPoint = drive.mountPoint ?? "/Volumes/\(drive.name)"
        let helper = PrivilegedHelperManager.shared
        
        // Eject triggers filesystem sync, unmount, and diskutil eject
        let result = await helper.executeHelper(arguments: ["eject", devicePath, mountPoint])
        
        DispatchQueue.main.async {
            self.setBusy(for: drive.bsdName, isBusy: false)
            if result.status == 0 {
                self.drives.removeAll { $0.bsdName == drive.bsdName }
                self.notifyUser(title: "Safe Eject & Sync", message: "\(drive.name) has been safely flushed and ejected. You can now unplug it.")
            } else {
                self.notifyUser(title: "Eject Warning", message: "Could not eject \(drive.name). A file may still be in use.")
            }
        }
        scanDrives()
        return (result.status == 0)
    }
    
    // MARK: - Health Check Action
    public func checkVolumeHealth(drive: NTFSDrive) async -> (isClean: Bool, output: String) {
        if drive.isSimulated {
            return (true, "Simulated Crucial X9 Volume: 0 errors found. MFT and Boot Sector OK.")
        }
        
        let devicePath = "/dev/\(drive.bsdName)"
        let helper = PrivilegedHelperManager.shared
        let result = await helper.executeHelper(arguments: ["check", devicePath])
        
        let isClean = (result.status == 0)
        return (isClean, result.output)
    }
    
    // MARK: - Finder & UI Helpers
    public func openInFinder(drive: NTFSDrive) {
        if let mp = drive.mountPoint, FileManager.default.fileExists(atPath: mp) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: mp)
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: "/Volumes")
        }
    }
    
    private func setBusy(for bsdName: String, isBusy: Bool) {
        DispatchQueue.main.async {
            if let idx = self.drives.firstIndex(where: { $0.bsdName == bsdName }) {
                self.drives[idx].isBusy = isBusy
            }
        }
    }
    
    private func showIntegrityGuardAlert(driveName: String, report: String) {
        self.alertMessage = """
        [Pre-Mount Integrity Guard Blocked Write Access]
        
        The volume '\(driveName)' contains Windows Fast Startup or uncommitted NTFS journal data.
        
        To prevent irreversible data loss and keep your Crucial X9 completely safe:
        • Write access has been disabled.
        • Drive remains safely accessible in Read-Only mode.
        
        Resolution:
        1. Plug the drive into your Windows PC.
        2. In Windows, go to Power Options > 'Choose what the power buttons do'.
        3. Click 'Change settings that are currently unavailable' and uncheck 'Turn on fast startup'.
        4. Perform a normal Start > Shut Down (not sleep/hibernate).
        """
        self.showAlert = true
    }
    
    private func notifyUser(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    
    // MARK: - Simulation Mode (For verification without physical SSD attached)
    public func simulateCrucialX9() {
        let sim = NTFSDrive(
            id: "sim_crucial_x9",
            bsdName: "disk4s1",
            parentDevice: "disk4",
            name: "Crucial X9",
            totalBytes: 1_000_000_000_000,
            freeBytes: 420_000_000_000,
            mountPoint: "/Volumes/Crucial X9",
            isMounted: true,
            isInternal: false,
            filesystem: "NTFS",
            mountMode: .readOnly,
            healthState: .clean,
            isBusy: false,
            isSimulated: true
        )
        if !drives.contains(where: { $0.id == sim.id }) {
            drives.append(sim)
        }
    }
    
    public func removeSimulatedDrive() {
        drives.removeAll { $0.isSimulated }
    }
}
