import Cocoa
import SwiftUI
import UserNotifications
import Combine

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables = Set<AnyCancellable>()
    
    nonisolated public override init() {
        super.init()
    }
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon for sleek Menu Bar presence
        NSApp.setActivationPolicy(.accessory)
        
        // Setup Menu Bar Status Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive.fill.badge.checkmark", accessibilityDescription: "NTFS Assistant")
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        // Observe drive state changes to update Menu Bar icon dynamically
        DiskManager.shared.$drives
            .receive(on: DispatchQueue.main)
            .sink { [weak self] drives in
                self?.updateMenuBarIcon(drives: drives)
            }
            .store(in: &cancellables)
        
        // Setup Popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 420)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView())
        self.popover = popover
        
        // Request Notification Permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }
    
    private func updateMenuBarIcon(drives: [NTFSDrive]) {
        guard let button = statusItem.button else { return }
        if drives.isEmpty {
            button.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "NTFS Assistant - No Drives Connected")
        } else if drives.contains(where: { $0.isBusy }) {
            button.image = NSImage(systemSymbolName: "externaldrive.badge.timemachine", accessibilityDescription: "NTFS Assistant - Mounting")
        } else if drives.contains(where: { $0.mountMode == .dirtyUnsafe }) {
            button.image = NSImage(systemSymbolName: "externaldrive.badge.xmark", accessibilityDescription: "NTFS Assistant - Dirty / Fast Startup Lock")
        } else if drives.contains(where: { $0.mountMode == .readOnly }) {
            button.image = NSImage(systemSymbolName: "externaldrive.badge.exclamationmark", accessibilityDescription: "NTFS Assistant - Read-Only Protected")
        } else if drives.allSatisfy({ $0.mountMode == .readWrite }) {
            button.image = NSImage(systemSymbolName: "externaldrive.fill.badge.checkmark", accessibilityDescription: "NTFS Assistant - Read & Write Active")
        } else {
            button.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "NTFS Assistant")
        }
    }
    
    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Refresh disk state before showing
            DiskManager.shared.scanDrives()
            PrivilegedHelperManager.shared.refreshStatus()
            
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
