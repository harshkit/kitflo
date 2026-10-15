import AppKit
import AVFoundation
import SwiftUI

@main
enum Main {
    static func main() {
        migrateFromOpenFlo()
        let args = CommandLine.arguments
        if args.contains("--selftest") { Post.selfTest(); return }
        if args.contains("--record-test") {
            Task { await MeetingRecorder.shared.recordTest(); exit(0) }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--meeting"), i + 2 < args.count {
            Task { await MeetingNotes.cli(args[i + 1], args[i + 2]); exit(0) }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--file"), i + 1 < args.count {
            Task { await Flow.shared.runFile(args[i + 1]); exit(0) }
            RunLoop.main.run()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)   // shows in the Dock; the menu bar icon stays too
        app.run()
    }
}

/// One-time move from the old OpenFlo name: data, models and recordings carry over to the Kitflo folders.
/// The bundle ID stays com.openflo.app, so macOS permissions are kept.
func migrateFromOpenFlo() {
    let fm = FileManager.default
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let movies = fm.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    for base in [support, movies] {
        let old = base.appending(path: "OpenFlo"), new = base.appending(path: "Kitflo")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new) }
    }
    // Saved recordings point at files that just moved.
    let store = support.appending(path: "Kitflo/store.json")
    if let text = try? String(contentsOf: store, encoding: .utf8), text.contains("Movies\\/OpenFlo") || text.contains("Movies/OpenFlo") {
        let fixed = text.replacingOccurrences(of: "Movies\\/OpenFlo", with: "Movies\\/Kitflo").replacingOccurrences(of: "Movies/OpenFlo", with: "Movies/Kitflo")
        try? fixed.write(to: store, atomically: true, encoding: .utf8)
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
        status.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Kitflo")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Kitflo", action: #selector(openWindow), keyEquivalent: "o")
        menu.addItem(withTitle: "Record Meeting Notes", action: #selector(newNote), keyEquivalent: "n")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kitflo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu

        NSApp.mainMenu = Self.mainMenu()
        overlay = OverlayPanel()
        Flow.shared.boot()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        installHotkey()
        let sig = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Log.write("launch v\(sig) accessibility=\(trusted) screenRecording=\(CGPreflightScreenCaptureAccess()) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) camera=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue) path=\(Bundle.main.bundlePath)")
        if !trusted || Store.shared.s.history.isEmpty { openWindow() }
    }

    /// Standard app + Edit menus: Quit, and ⌘C/⌘V/⌘A inside Kitflo's own text fields (Notes needs these).
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(), app = NSMenu()
        app.addItem(withTitle: "About Kitflo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Kitflo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Kitflo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)
        let editItem = NSMenuItem(), edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    func applicationWillTerminate(_ n: Notification) {
        LLM.stop()
        MeetingRecorder.shared.shutdown()   // never leave a screen/mic capture running after quit
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openWindow(); return true
    }

    private func installHotkey() {
        let handler: (NSEvent) -> Void = { [weak self] e in self?.flagsChanged(e) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) { monitors.append(l) }
        // Any other key while the hotkey is held means a shortcut (e.g. ⌥← to jump words), not dictation: cancel.
        let typed: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.keyIsDown, Flow.shared.phase == .listening, !Flow.shared.locked else { return }
            Flow.shared.cancel()
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: typed) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { typed($0); return $0 }) { monitors.append(l) }
        // Safety net: a missed key-up event must never leave the mic on. Check the real key state twice a second.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.keyIsDown else { return }
            if !Store.shared.s.hotkey.isDown(CGEventSource.flagsState(.combinedSessionState).rawValue) {
                Log.write("hotkey release was missed; stopping")
                self.keyIsDown = false
                Flow.shared.keyUp()
            }
        }
    }

    private func flagsChanged(_ e: NSEvent) {
        let key = Store.shared.s.hotkey
        guard e.keyCode == key.keyCode else { return }
        let down = key.isDown(UInt64(e.modifierFlags.rawValue))
        guard down != keyIsDown else { return }
        keyIsDown = down
        if down { overlay.reposition(); Flow.shared.keyDown() } else { Flow.shared.keyUp() }
    }

    @objc func newNote() {
        Store.shared.meetingID = nil
        Store.shared.page = .notes
        openWindow()
    }

    @objc func openWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.title = "Kitflo"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
