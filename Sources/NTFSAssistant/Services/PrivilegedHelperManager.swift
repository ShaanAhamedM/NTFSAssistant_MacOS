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
        
        if let resourcePath = Bundle.main.resourcePath {
            let bundleHelper = "\(resourcePath)/scripts/ntfs-mount-helper"
            if FileManager.default.fileExists(atPath: bundleHelper) {
                return bundleHelper
            }
            let bundleHelperSh = "\(resourcePath)/scripts/ntfs-mount-helper.sh"
            if FileManager.default.fileExists(atPath: bundleHelperSh) {
                return bundleHelperSh
            }
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
                
                let lock = NSLock()
                var hasResumed = false
                
                // Watchdog timer: abort task after 60 seconds if hanging
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                timer.schedule(deadline: .now() + 60.0)
                timer.setEventHandler {
                    lock.lock()
                    if !hasResumed {
                        hasResumed = true
                        lock.unlock()
                        if task.isRunning {
                            task.terminate()
                        }
                        continuation.resume(returning: (-1, "Operation timed out after 60 seconds."))
                    } else {
                        lock.unlock()
                    }
                }
                timer.resume()
                
                do {
                    try task.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    timer.cancel()
                    
                    lock.lock()
                    if !hasResumed {
                        hasResumed = true
                        lock.unlock()
                        let output = String(data: data, encoding: .utf8) ?? ""
                        continuation.resume(returning: (task.terminationStatus, output))
                    } else {
                        lock.unlock()
                    }
                } catch {
                    timer.cancel()
                    lock.lock()
                    if !hasResumed {
                        hasResumed = true
                        lock.unlock()
                        continuation.resume(returning: (-1, error.localizedDescription))
                    } else {
                        lock.unlock()
                    }
                }
            }
        }
    }
    
    public func installHelperViaAdminPrompt(completion: @escaping @MainActor @Sendable (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var scriptCandidates: [String] = []
            if let resPath = Bundle.main.resourcePath {
                scriptCandidates.append("\(resPath)/scripts/setup_environment.sh")
            }
            if let res = Bundle.main.path(forResource: "setup_environment", ofType: "sh", inDirectory: "scripts") {
                scriptCandidates.append(res)
            }
            if let res = Bundle.main.path(forResource: "setup_environment", ofType: "sh") {
                scriptCandidates.append(res)
            }
            scriptCandidates.append("/Library/Application Support/NTFSAssistant/setup_environment.sh")
            scriptCandidates.append(FileManager.default.currentDirectoryPath + "/scripts/setup_environment.sh")
            
            let setupScript = scriptCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/Library/Application Support/NTFSAssistant/setup_environment.sh"
            
            let escapedScript = setupScript
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "'", with: "'\\''")
            
            let appleScriptSource = """
            do shell script "bash '\(escapedScript)'" with administrator privileges
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
