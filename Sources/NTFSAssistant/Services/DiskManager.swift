import Foundation
import Cocoa
@preconcurrency import DiskArbitration
import Combine
import UserNotifications

public final class DiskManager: ObservableObject, @unchecked Sendable {
    public static let shared = DiskManager()
    
    @Published public var drives: [NTFSDrive] = []
    @Published public var isScanning: Bool = false
    @Published public var autoMountEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoMountEnabled, forKey: "autoMountEnabled")
        }
    }
    @Published public var safeModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(safeModeEnabled, forKey: "safeModeEnabled")
        }
    }
    @Published public var alertMessage: String? = nil
    @Published public var showAlert: Bool = false
    
    private var daSession: DASession?
    private var cancellables = Set<AnyCancellable>()
    private var scanTimer: Timer?
    private let queue = DispatchQueue(label: "com.ntfsassistant.diskmanager", qos: .userInitiated)
    private var workspaceObservers: [NSObjectProtocol] = []
    
    // Tracking user actions and active mount tasks to prevent duplicate operations and race conditions
    private var userEjectedDevices = Set<String>()
    private var pendingMounts = Set<String>()
    private var connectionDebounceWorkItems: [String: DispatchWorkItem] = [:]
    
    private init() {
        if UserDefaults.standard.object(forKey: "autoMountEnabled") != nil {
            self.autoMountEnabled = UserDefaults.standard.bool(forKey: "autoMountEnabled")
        } else {
            self.autoMountEnabled = true
        }
        
        if UserDefaults.standard.object(forKey: "safeModeEnabled") != nil {
            self.safeModeEnabled = UserDefaults.standard.bool(forKey: "safeModeEnabled")
        } else {
            self.safeModeEnabled = true
        }
        
        setupDiskArbitration()
        setupWorkspaceNotifications()
        startPeriodicScan()
        scanDrives()
    }
    
    deinit {
        scanTimer?.invalidate()
        for (_, item) in connectionDebounceWorkItems {
            item.cancel()
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
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
        let obs1 = center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scanDrives()
        }
        let obs2 = center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scanDrives()
        }
        let obs3 = center.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scanDrives()
        }
        let obs4 = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            // Flush all pending filesystem caches to hardware NAND prior to system sleep
            let syncTask = Process()
            syncTask.launchPath = "/bin/sync"
            try? syncTask.run()
        }
        let obs5 = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Refresh disk states and verify mount connections after system wake
            self?.scanDrives()
        }
        workspaceObservers.append(contentsOf: [obs1, obs2, obs3, obs4, obs5])
    }
    
    private func startPeriodicScan() {
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.scanDrives()
        }
    }
    
    private func handleDiskAppeared(disk: DADisk) {
        if let desc = DADiskCopyDescription(disk) as? [String: Any],
           let bsdName = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String {
            connectionDebounceWorkItems[bsdName]?.cancel()
            
            queue.async { [weak self] in
                self?.inspectAndAddDisk(bsdName: bsdName, triggeredByConnect: true)
            }
        }
    }
    
    private func handleDiskDisappeared(disk: DADisk) {
        if let desc = DADiskCopyDescription(disk) as? [String: Any],
           let bsdName = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String {
            connectionDebounceWorkItems[bsdName]?.cancel()
            connectionDebounceWorkItems.removeValue(forKey: bsdName)
            
            let parentDevice = bsdName.components(separatedBy: "s").first ?? bsdName
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.drives.removeAll { $0.bsdName == bsdName || $0.parentDevice == bsdName || $0.bsdName == parentDevice }
                self.userEjectedDevices.remove(bsdName)
                self.userEjectedDevices.remove(parentDevice)
                self.pendingMounts.remove(bsdName)
                self.pendingMounts.remove(parentDevice)
            }
        }
    }
    
    private func handleDiskChanged(disk: DADisk) {
        scanDrives()
    }
    
    // MARK: - Drive Scanning & Inspection
    public func scanDrives() {
        queue.async { [weak self] in
            autoreleasepool {
                guard let self = self else { return }
                
                // Concurrency guard: avoid stacking redundant scans
                if self.isScanning { return }
                self.isScanning = true
                defer { self.isScanning = false }
            
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
                                let content = part["Content"] as? String ?? ""
                                // Fast filter: Skip macOS APFS containers, recovery, EFI, and HFS system partitions
                                if content.hasPrefix("Apple_") || content == "EFI" {
                                    continue
                                }
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
                        var updatedList: [NTFSDrive] = []
                        for discovered in finalDiscovered {
                            if let existingIndex = self.drives.firstIndex(where: { $0.bsdName == discovered.bsdName }) {
                                var drive = discovered
                                let wasBusy = self.drives[existingIndex].isBusy
                                let prevMode = self.drives[existingIndex].mountMode
                                
                                drive.isBusy = wasBusy
                                drive.statusMessage = self.drives[existingIndex].statusMessage
                                drive.healthState = self.drives[existingIndex].healthState
                                drive.lastHealthReport = self.drives[existingIndex].lastHealthReport
                                
                                // Do not overwrite an active or in-progress state with a transient scan mode
                                if wasBusy {
                                    drive.mountMode = prevMode
                                }
                                
                                updatedList.append(drive)
                                
                                // AUTOMOUNT: Intercept read-only or unmounted external physical NTFS drives automatically
                                if self.autoMountEnabled &&
                                   !drive.isInternal &&
                                   !drive.isVirtual &&
                                   !wasBusy &&
                                   !self.userEjectedDevices.contains(drive.bsdName) &&
                                   !self.userEjectedDevices.contains(drive.parentDevice) &&
                                   !self.pendingMounts.contains(drive.bsdName) &&
                                   drive.healthState != .dirty {
                                    if drive.mountMode == .readOnly || drive.mountMode == .unmounted {
                                        drive.isBusy = true
                                        drive.statusMessage = "Mounting Read & Write..."
                                        self.triggerAutoMount(for: drive)
                                    }
                                }
                            } else {
                                var newDrive = discovered
                                if self.autoMountEnabled &&
                                   !newDrive.isInternal &&
                                   !newDrive.isVirtual &&
                                   !self.userEjectedDevices.contains(newDrive.bsdName) &&
                                   !self.userEjectedDevices.contains(newDrive.parentDevice) &&
                                   !self.pendingMounts.contains(newDrive.bsdName) &&
                                   newDrive.healthState != .dirty {
                                    if newDrive.mountMode == .readOnly || newDrive.mountMode == .unmounted {
                                        newDrive.isBusy = true
                                        newDrive.statusMessage = "Mounting Read & Write..."
                                        updatedList.append(newDrive)
                                        self.triggerAutoMount(for: newDrive)
                                        continue
                                    }
                                }
                                updatedList.append(newDrive)
                            }
                        }
                        
                        let simulated = self.drives.filter { $0.isSimulated }
                        let targetList = updatedList + simulated
                        if self.drives != targetList {
                            self.drives = targetList
                        }
                    }
                }
            } catch {
                print("Error scanning disks: \(error)")
            }
            }
        }
    }
    
    private func evaluatePartition(bsdName: String, parentDevice: String) -> NTFSDrive? {
        return autoreleasepool {
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
            let isVirtual = ((info["VirtualOrPhysical"] as? String)?.lowercased() == "virtual") ||
                            ((info["DeviceNode"] as? String)?.contains("diskimages") == true)
            
            // Strictly detect NTFS volumes
            let isNTFS = fileSystemType.lowercased().contains("ntfs") ||
                         fileSystemName.lowercased().contains("ntfs") ||
                         typeBundle.lowercased().contains("ntfs")
            
            if !isNTFS {
                return nil
            }
            
            let devNode = "/dev/\(bsdName)"
            
            // 1. Authoritative check: Is ntfs-3g actively running for this partition?
            var ntfs3gMountPoint: String? = nil
            let psTask = Process()
            psTask.launchPath = "/bin/ps"
            psTask.arguments = ["-eo", "command"]
            let psPipe = Pipe()
            psTask.standardOutput = psPipe
            try? psTask.run()
            let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
            psTask.waitUntilExit()
            let psOutput = String(data: psData, encoding: .utf8) ?? ""
            let psLines = psOutput.components(separatedBy: "\n")
            
            for line in psLines {
                if line.contains("ntfs-3g") && line.contains(devNode) {
                    let parts = line.components(separatedBy: " ")
                    if let devIndex = parts.firstIndex(where: { $0 == devNode || $0.hasSuffix(bsdName) }),
                       devIndex + 1 < parts.count {
                        var mp = parts[devIndex + 1]
                        var nextIdx = devIndex + 2
                        while nextIdx < parts.count && !parts[nextIdx].hasPrefix("-o") {
                            mp += " " + parts[nextIdx]
                            nextIdx += 1
                        }
                        if mp.hasPrefix("/Volumes") {
                            ntfs3gMountPoint = mp
                        }
                    }
                    break
                }
            }
            
            // 2. Check /sbin/mount for active mounts
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
            if detectedMountPoint?.isEmpty == true {
                detectedMountPoint = nil
            }
            var currentMode: MountMode = .unmounted
            
            if let mp = ntfs3gMountPoint {
                // Confirmed active ntfs-3g Read & Write mount!
                isMounted = true
                detectedMountPoint = mp
                currentMode = .readWrite
            } else {
                // Check if device is mounted natively by macOS
                for line in mountLines {
                    if line.contains("\(devNode) on ") || line.hasPrefix("\(devNode) ") {
                        isMounted = true
                        if let onRange = line.range(of: " on "),
                           let parenRange = line.range(of: " (", range: onRange.upperBound..<line.endIndex) {
                            detectedMountPoint = String(line[onRange.upperBound..<parenRange.lowerBound])
                        }
                        if line.contains("read-only") {
                            currentMode = .readOnly
                        } else {
                            currentMode = .readWrite
                        }
                        break
                    }
                }
                
                // Fallback check: diskutil info MountPoint
                if !isMounted, let mp = detectedMountPoint, !mp.isEmpty, mp != "/", FileManager.default.fileExists(atPath: mp) {
                    isMounted = true
                    let writable = (info["WritableVolume"] as? Bool) ?? (info["Writable"] as? Bool ?? true)
                    currentMode = writable ? .readWrite : .readOnly
                }
            }
            
            // Determine accurate volume name
            var volumeName = (info["VolumeName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if volumeName.isEmpty {
                volumeName = (info["MediaName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            if volumeName.isEmpty, let mp = detectedMountPoint, !mp.isEmpty, mp != "/" {
                volumeName = URL(fileURLWithPath: mp).lastPathComponent
            }
            if volumeName.isEmpty {
                volumeName = "NTFS Volume (\(bsdName))"
            }
            
            // Determine capacity and free space accurately
            var totalBytes = info["TotalSize"] as? Int64 ?? (info["Size"] as? Int64 ?? 1_000_000_000_000)
            var freeBytes = info["FreeSpace"] as? Int64 ?? 0
            
            if isMounted, let mp = detectedMountPoint, FileManager.default.fileExists(atPath: mp) {
                if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: mp) {
                    if let size = attrs[.systemSize] as? Int64, size > 0 {
                        totalBytes = size
                    }
                    if let free = attrs[.systemFreeSize] as? Int64 {
                        freeBytes = free
                    }
                }
            }
            
            return NTFSDrive(
                id: bsdName,
                bsdName: bsdName,
                parentDevice: parentDevice,
                name: volumeName,
                totalBytes: totalBytes,
                freeBytes: freeBytes,
                mountPoint: detectedMountPoint,
                isMounted: isMounted,
                isInternal: isInternal,
                filesystem: "NTFS",
                mountMode: currentMode,
                healthState: .unknown,
                isBusy: false,
                statusMessage: nil,
                isSimulated: false,
                isVirtual: isVirtual
            )
        } catch {
            return nil
        }
        }
    }
    
    private func inspectAndAddDisk(bsdName: String, triggeredByConnect: Bool) {
        let parentDevice = bsdName.components(separatedBy: "s").first ?? bsdName
        guard let drive = evaluatePartition(bsdName: bsdName, parentDevice: parentDevice) else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Check if drive is internal or a virtual disk image - do not automount
            if drive.isInternal || drive.isVirtual {
                if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                    self.drives[idx] = drive
                } else {
                    self.drives.append(drive)
                }
                return
            }
            
            // Check if drive was explicitly ejected by user
            if self.userEjectedDevices.contains(drive.bsdName) || self.userEjectedDevices.contains(drive.parentDevice) {
                if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                    self.drives[idx] = drive
                } else {
                    self.drives.append(drive)
                }
                return
            }
            
            // If already Read & Write, record it
            if drive.mountMode == .readWrite {
                if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                    self.drives[idx] = drive
                } else {
                    self.drives.append(drive)
                }
                return
            }
            
            // If drive is in Read-Only or Unmounted mode and autoMount is enabled, trigger immediately
            if self.autoMountEnabled && !self.pendingMounts.contains(drive.bsdName) {
                if drive.mountMode == .readOnly || drive.mountMode == .unmounted {
                    var initialDrive = drive
                    initialDrive.isBusy = true
                    initialDrive.statusMessage = "Mounting Read & Write..."
                    if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                        self.drives[idx] = initialDrive
                    } else {
                        self.drives.append(initialDrive)
                    }
                    self.triggerAutoMount(for: drive)
                    return
                }
            }
            
            // Default add or update
            if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                self.drives[idx] = drive
            } else {
                self.drives.append(drive)
            }
        }
    }
    
    // MARK: - Automount & R/W Mount Workflow
    public func userRequestedMount(drive: NTFSDrive) {
        userEjectedDevices.remove(drive.bsdName)
        userEjectedDevices.remove(drive.parentDevice)
        Task {
            await mountReadWrite(drive: drive, isAutoMount: false)
        }
    }
    
    public func triggerAutoMount(for drive: NTFSDrive) {
        guard !pendingMounts.contains(drive.bsdName) else { return }
        Task {
            await mountReadWrite(drive: drive, isAutoMount: true)
        }
    }
    
    @discardableResult
    public func mountReadWrite(drive: NTFSDrive, isAutoMount: Bool = false) async -> Bool {
        if pendingMounts.contains(drive.bsdName) {
            return false
        }
        pendingMounts.insert(drive.bsdName)
        defer {
            pendingMounts.remove(drive.bsdName)
        }
        
        setBusy(for: drive.bsdName, isBusy: true, statusMessage: "Mounting Read & Write...")
        
        if drive.isSimulated {
            try? await Task.sleep(nanoseconds: 800_000_000)
            DispatchQueue.main.async {
                if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                    self.drives[idx].mountMode = .readWrite
                    self.drives[idx].isMounted = true
                    self.drives[idx].mountPoint = "/Volumes/\(self.drives[idx].name)"
                    self.drives[idx].isBusy = false
                    self.drives[idx].statusMessage = nil
                    self.notifyUser(title: "\(self.drives[idx].name) (Simulated)", message: "Mounted with full Read & Write access.")
                }
            }
            return true
        }
        
        let devicePath = "/dev/\(drive.bsdName)"
        let volumeName = drive.name.isEmpty ? "NTFS Volume" : drive.name
        let mountPoint = drive.mountPoint ?? "/Volumes/\(volumeName)"
        let uid = String(getuid())
        let gid = String(getgid())
        let helper = PrivilegedHelperManager.shared
        
        let result = await helper.executeHelper(arguments: ["mount", devicePath, mountPoint, uid, gid, volumeName])
        
        if result.status == 0 {
            DispatchQueue.main.async {
                if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                    self.drives[idx].mountMode = .readWrite
                    self.drives[idx].isMounted = true
                    self.drives[idx].mountPoint = mountPoint
                    self.drives[idx].healthState = .clean
                    self.drives[idx].isBusy = false
                    self.drives[idx].statusMessage = nil
                }
                self.notifyUser(title: "\(volumeName) Ready", message: "Mounted with full Read & Write access.")
            }
            // Delay scan slightly to let system and FUSE-T settle
            try? await Task.sleep(nanoseconds: 500_000_000)
            scanDrives()
            return true
        } else if result.status == 2 {
            DispatchQueue.main.async {
                if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                    self.drives[idx].mountMode = .dirtyUnsafe
                    self.drives[idx].healthState = .dirty
                    self.drives[idx].lastHealthReport = result.output
                    self.drives[idx].isBusy = false
                    self.drives[idx].statusMessage = nil
                }
                self.showIntegrityGuardAlert(driveName: volumeName, report: result.output)
            }
            scanDrives()
            return false
        } else {
            DispatchQueue.main.async {
                if let idx = self.drives.firstIndex(where: { $0.bsdName == drive.bsdName }) {
                    self.drives[idx].mountMode = .readOnly
                    self.drives[idx].isBusy = false
                    self.drives[idx].statusMessage = nil
                }
                self.notifyUser(title: "\(volumeName) Protected", message: "R/W mount failed. Safely reverted to native Read-Only access.")
            }
            scanDrives()
            return false
        }
    }
    
    // MARK: - Safe Eject Sequence
    public func safeEject(drive: NTFSDrive) async -> Bool {
        setBusy(for: drive.bsdName, isBusy: true, statusMessage: "Ejecting...")
        
        if drive.isSimulated {
            try? await Task.sleep(nanoseconds: 500_000_000)
            DispatchQueue.main.async {
                self.drives.removeAll { $0.bsdName == drive.bsdName }
                self.notifyUser(title: "Safe Eject", message: "\(drive.name) safely ejected.")
            }
            return true
        }
        
        let devicePath = "/dev/\(drive.parentDevice)"
        let mountPoint = drive.mountPoint ?? "/Volumes/\(drive.name)"
        let helper = PrivilegedHelperManager.shared
        
        let result = await helper.executeHelper(arguments: ["eject", devicePath, mountPoint])
        
        DispatchQueue.main.async {
            self.setBusy(for: drive.bsdName, isBusy: false)
            if result.status == 0 {
                self.userEjectedDevices.insert(drive.bsdName)
                self.userEjectedDevices.insert(drive.parentDevice)
                self.connectionDebounceWorkItems[drive.bsdName]?.cancel()
                self.connectionDebounceWorkItems.removeValue(forKey: drive.bsdName)
                self.drives.removeAll { $0.bsdName == drive.bsdName || $0.parentDevice == drive.parentDevice }
                self.notifyUser(title: "Safe Eject & Sync", message: "\(drive.name) has been safely flushed and ejected. You can now unplug it.")
            } else {
                let failureReason: String
                if result.output.contains("EJECT_FAILED_BUSY") || result.output.contains("files are open by:") {
                    let busyPart = result.output.components(separatedBy: "files are open by:").last?.components(separatedBy: ".").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !busyPart.isEmpty {
                        failureReason = "Could not eject \(drive.name). Files are in use by: \(busyPart). Please close open files or apps and try again."
                    } else {
                        failureReason = "Could not eject \(drive.name). A file or application is currently using it."
                    }
                } else {
                    failureReason = "Could not eject \(drive.name). Please close any open files and try again."
                }
                self.notifyUser(title: "Eject Warning", message: failureReason)
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
    
    private func setBusy(for bsdName: String, isBusy: Bool, statusMessage: String? = nil) {
        DispatchQueue.main.async {
            if let idx = self.drives.firstIndex(where: { $0.bsdName == bsdName }) {
                self.drives[idx].isBusy = isBusy
                if let msg = statusMessage {
                    self.drives[idx].statusMessage = msg
                } else if !isBusy {
                    self.drives[idx].statusMessage = nil
                }
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
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
                isSimulated: true,
                isVirtual: false
            )
            if !self.drives.contains(where: { $0.id == sim.id }) {
                self.drives.append(sim)
            }
        }
    }
    
    public func removeSimulatedDrive() {
        DispatchQueue.main.async { [weak self] in
            self?.drives.removeAll { $0.isSimulated }
        }
    }
}
