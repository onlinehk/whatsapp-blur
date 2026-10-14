import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let overlay = OverlayController()
    private var scanner: AXScanner!
    private var hotKey: HotKey?
    private let settings = Settings.shared
    private var status = "Starting…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateIcon()

        popover.behavior = .transient

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        scanner = AXScanner { [weak self] snapshot in
            self?.received(snapshot)
        }
        overlay.requestScan = { [weak scanner] delay, rediscover in
            scanner?.refreshSoon(after: delay, rediscover: rediscover)
        }
        scanner.start()

        hotKey = HotKey(keyCode: kVK_ANSI_B, modifiers: controlKey | optionKey) { [weak self] in
            self?.settings.enabled.toggle()
        }

        // The panel and the hotkey both write UserDefaults; keep the icon in step.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    private func received(_ snapshot: Snapshot?) {
        overlay.update(snapshot)

        if !AXIsProcessTrusted() {
            status = "Needs Accessibility permission"
        } else if NSRunningApplication.runningApplications(withBundleIdentifier: AXScanner.bundleID).isEmpty {
            status = "WhatsApp is not running"
        } else if snapshot == nil {
            status = "WhatsApp window not visible"
        } else {
            status = settings.enabled ? "Blurring WhatsApp" : "Paused"
        }
    }

    @objc private func defaultsChanged() {
        DispatchQueue.main.async {
            self.updateIcon()
            self.overlay.render()
        }
    }

    private func updateIcon() {
        let name = settings.enabled ? "eye.slash" : "eye"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "WhatsApp Blur")
        image?.isTemplate = true
        if statusItem.button?.image?.name() != name {
            image?.setName(name)
            statusItem.button?.image = image
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        guard let button = statusItem.button else {
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView(
            status: status,
            needsAccessibility: !AXIsProcessTrusted(),
            openAccessibilitySettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        ))
        // Size the popover before showing it; otherwise it grows upward off the screen.
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.contentSize = hostingController.view.fittingSize
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
