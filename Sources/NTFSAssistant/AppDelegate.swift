import Cocoa
import SwiftUI
import UserNotifications

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    
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
