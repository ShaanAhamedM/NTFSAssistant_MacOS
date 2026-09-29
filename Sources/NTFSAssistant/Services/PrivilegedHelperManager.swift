import Foundation

public final class PrivilegedHelperManager: @unchecked Sendable {
    public static let shared = PrivilegedHelperManager()
    
    public private(set) var isHelperInstalled: Bool = false
    public private(set) var isSudoersConfigured: Bool = false
    
    private init() {
        refreshStatus()
    }
    
    public var helperPath: String {
        let systemPath = "/Library/Application Support/NTFSAssistant/ntfs-mount-helper"
        if FileManager.default.fileExists(atPath: systemPath) {
            return systemPath
        }
        
        if let bundleResource = Bundle.main.path(forResource: "ntfs-mount-helper", ofType: "sh", inDirectory: "scripts") {
            return bundleResource
        }
        
        let workspacePath = "/Users/shaanm/NTFSAssistant/scripts/ntfs-mount-helper.sh"
        if FileManager.default.fileExists(atPath: workspacePath) {
            return workspacePath
        }
        
        return systemPath
    }
    
    public func refreshStatus() {
        let systemPath = "/Library/Application Support/NTFSAssistant/ntfs-mount-helper"
        isHelperInstalled = FileManager.default.fileExists(atPath: systemPath)
        
        // Test if passwordless sudo is functional for helper
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments = ["-n", helperPath, "status"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            isSudoersConfigured = (task.terminationStatus == 0)
        } catch {
            isSudoersConfigured = false
        }
    }
    
    public func executeHelper(arguments: [String]) async -> (status: Int32, output: String) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                
                // If passwordless sudo is configured, use sudo -n
                // Otherwise run directly or through sudo
                if self.isSudoersConfigured {
                    task.launchPath = "/usr/bin/sudo"
                    task.arguments = ["-n", self.helperPath] + arguments
                } else {
                    task.launchPath = "/bin/bash"
                    task.arguments = [self.helperPath] + arguments
                }
                
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe
                
                do {
                    try task.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (task.terminationStatus, output))
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                }
            }
        }
    }
    
    public func installHelperViaAdminPrompt(completion: @escaping @MainActor @Sendable (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let scriptCandidates = [
                Bundle.main.path(forResource: "setup_environment", ofType: "sh"),
                "/Library/Application Support/NTFSAssistant/setup_environment.sh",
                FileManager.default.currentDirectoryPath + "/scripts/setup_environment.sh",
                "/Users/shaanm/NTFSAssistant/scripts/setup_environment.sh"
            ]
            let setupScript = scriptCandidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) } ?? "/Library/Application Support/NTFSAssistant/setup_environment.sh"
            
            let appleScriptSource = """
            do shell script "bash '\(setupScript)'" with administrator privileges
            """
            
            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: appleScriptSource) {
                let output = scriptObject.executeAndReturnError(&error)
                if let error = error {
                    let errMsg = error[NSAppleScript.errorMessage] as? String ?? "Authorization failed"
                    DispatchQueue.main.async {
                        completion(false, errMsg)
                    }
                } else {
                    let outString = output.stringValue ?? "Success"
                    self.refreshStatus()
                    DispatchQueue.main.async {
                        completion(true, outString)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completion(false, "Could not initialize AppleScript")
                }
            }
        }
    }
}
