import Foundation
import SwiftUI

public enum MountMode: String, CaseIterable, Codable, Sendable {
    case readWrite = "Read & Write"
    case readOnly = "Read-Only (Protected)"
    case dirtyUnsafe = "Dirty / Unsafe to Write"
    case unmounted = "Unmounted"
    
    public var badgeColor: Color {
        switch self {
        case .readWrite:
            return .green
        case .readOnly:
            return .orange
        case .dirtyUnsafe:
            return .red
        case .unmounted:
            return .gray
        }
    }
    
    public var iconName: String {
        switch self {
        case .readWrite:
            return "pencil.and.outline"
        case .readOnly:
            return "lock.fill"
        case .dirtyUnsafe:
            return "exclamationmark.triangle.fill"
        case .unmounted:
            return "eject"
        }
    }
}

public enum HealthState: String, Codable, Sendable {
    case clean = "Clean Volume"
    case dirty = "Dirty / Fast Startup Detected"
    case unknown = "Not Inspected"
}

public struct NTFSDrive: Identifiable, Equatable, Sendable {
    public let id: String                 // BSD Name e.g. "disk4s1"
    public var bsdName: String            // "disk4s1"
    public var parentDevice: String       // "disk4"
    public var name: String               // e.g. "Crucial X9"
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var mountPoint: String?
    public var isMounted: Bool
    public var isInternal: Bool
    public var filesystem: String         // "NTFS"
    public var mountMode: MountMode
    public var healthState: HealthState
    public var lastHealthReport: String?
    public var isBusy: Bool
    public var statusMessage: String?
    public var isSimulated: Bool
    public var isVirtual: Bool
    
    public init(
        id: String,
        bsdName: String,
        parentDevice: String,
        name: String,
        totalBytes: Int64,
        freeBytes: Int64 = 0,
        mountPoint: String? = nil,
        isMounted: Bool = false,
        isInternal: Bool = false,
        filesystem: String = "NTFS",
        mountMode: MountMode = .readOnly,
        healthState: HealthState = .unknown,
        lastHealthReport: String? = nil,
        isBusy: Bool = false,
        statusMessage: String? = nil,
        isSimulated: Bool = false,
        isVirtual: Bool = false
    ) {
        self.id = id
        self.bsdName = bsdName
        self.parentDevice = parentDevice
        self.name = name
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.mountPoint = mountPoint
        self.isMounted = isMounted
        self.isInternal = isInternal
        self.filesystem = filesystem
        self.mountMode = mountMode
        self.healthState = healthState
        self.lastHealthReport = lastHealthReport
        self.isBusy = isBusy
        self.statusMessage = statusMessage
        self.isSimulated = isSimulated
        self.isVirtual = isVirtual
    }
    
    public var isCrucialX9: Bool {
        let lower = name.lowercased()
        return lower.contains("crucial") || lower.contains("x9")
    }
    
    public var isLowDiskSpace: Bool {
        return isMounted && freeBytes > 0 && freeBytes < 200 * 1024 * 1024 // < 200MB free
    }
    
    public var capacityFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .decimal
        return formatter.string(fromByteCount: totalBytes)
    }
    
    public var freeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .decimal
        return formatter.string(fromByteCount: freeBytes)
    }
}
