import AppKit
import AVFoundation
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { Post.selfTest(); return }
        if let i = args.firstIndex(of: "--file"), i + 1 < args.count {
            Task { await Flow.shared.runFile(args[i + 1]); exit(0) }
            RunLoop.main.run()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private var overlay: OverlayPanel!
    private var window: NSWindow?
    private var monitors: [Any] = []
    private var keyIsDown = false

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "OpenFlo")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open OpenFlo", action: #selector(openWindow), keyEquivalent: "o")
        menu.addItem(withTitle: "New Note", action: #selector(newNote), keyEquivalent: "n")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit OpenFlo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu

        overlay = OverlayPanel()
        Flow.shared.boot()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        installHotkey()
        if !trusted || Store.shared.s.history.isEmpty { openWindow() }
    }

    func applicationWillTerminate(_ n: Notification) { LLM.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openWindow(); return true
    }

    private func installHotkey() {
        let handler: (NSEvent) -> Void = { [weak self] e in self?.flagsChanged(e) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) { monitors.append(l) }
    }

    private func flagsChanged(_ e: NSEvent) {
        let key = Store.shared.s.hotkey
        guard e.keyCode == key.keyCode else { return }
        let flag: NSEvent.ModifierFlags = switch key { case .fn: .function; case .rightOption: .option; case .rightCommand: .command }
        let down = e.modifierFlags.contains(flag)
        guard down != keyIsDown else { return }
        keyIsDown = down
        if down { overlay.reposition(); Flow.shared.keyDown() } else { Flow.shared.keyUp() }
    }

    @objc func newNote() {
        Store.shared.newNote()
        openWindow()
    }

    @objc func openWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.title = "OpenFlo"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
