import AppKit
import SwiftUI

/// The Notes tab: record a meeting (audio, screen, camera), get who-said-what and AI notes.
struct MeetingsPage: View {
    @Bindable var store = Store.shared
    var body: some View {
        if let id = store.meetingID, store.s.meetings.contains(where: { $0.id == id }) {
            MeetingDetail(id: id)
        } else {
            VStack(alignment: .leading, spacing: 22) {
                Title(text: "Notes", sub: "Record a meeting, call or anything on screen. Kitflo works out who said what and writes the notes, all on this Mac.")
                RecorderCard()
                if !store.s.meetings.isEmpty {
                    Text("Recordings").font(.headline).padding(.top, 6)
                    LazyVStack(spacing: 0) {
                        ForEach(store.s.meetings) { m in
                            Button { store.meetingID = m.id } label: { MeetingRow(m: m) }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

struct RecorderCard: View {
    @Bindable var rec = MeetingRecorder.shared
    private var mode: RecordMode { store.s.recordMode }
    @State private var micOn = true
    @State private var systemOn = true
    @State private var starting = false
    @State private var screenOK = CGPreflightScreenCaptureAccess()
    @Bindable private var store = Store.shared

    /// Screen Recording is needed for system audio and video. Asking (CGRequestScreenCaptureAccess) is what puts
    /// Kitflo into the list in System Settings; macOS only applies a new grant after the app restarts.
    private var permission: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Kitflo needs Screen Recording to capture system audio and the screen.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
            HStack {
                Button("Allow Screen Recording") {
                    if !CGRequestScreenCaptureAccess() {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                Button("Fix permissions") { Permissions.fix() }
                Button("Restart Kitflo") { Self.relaunch() }
            }
            Text("Turn Kitflo on in the list, then press Restart Kitflo so macOS applies it. If the switch keeps turning off, press Fix permissions first.").font(.caption).foregroundStyle(.secondary)
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if rec.recording { live } else { setup }
            if !screenOK && (mode != .audio || systemOn) { permission }
            if let e = rec.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.paper))
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in screenOK = CGPreflightScreenCaptureAccess() }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ForEach(RecordMode.allCases) { m in
                    Button { store.s.recordMode = m } label: {
                        VStack(spacing: 8) {
                            Image(systemName: m.icon).font(.system(size: 20))
                            Text(m.rawValue).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 74)
                        .background(RoundedRectangle(cornerRadius: 12).fill(mode == m ? Color.primary.opacity(0.08) : Color.card))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(mode == m ? Color.primary : Color.primary.opacity(0.1), lineWidth: mode == m ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                Text("Record from").frame(width: 92, alignment: .leading)
                Label(rec.pickedLabel, systemImage: rec.pickedLabel == "Entire screen" ? "display" : "macwindow")
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.card))
                Button("Choose screen, app or window…") { rec.choose() }
                if rec.pickedLabel != "Entire screen" { Button("Entire screen") { rec.useEntireScreen() } }
                Spacer()
            }
            HStack(spacing: 10) {
                Text("Save to").frame(width: 92, alignment: .leading)
                Label(MeetingRecorder.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.card))
                Button("Change…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                    panel.prompt = "Save recordings here"
                    if panel.runModal() == .OK, let url = panel.url { store.s.recordingsFolder = url.path }
                }
                Button("Open") { NSWorkspace.shared.open(MeetingRecorder.folder) }
                Spacer()
            }
            HStack(spacing: 24) {
                Toggle("Microphone (you)", isOn: $micOn)
                Toggle("System audio (others)", isOn: $systemOn)
            }
            .toggleStyle(.switch)
            Text("Tip: to record one browser tab, choose the window that has that tab open. Picking an app (like Zoom) records only that app's audio and windows.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    starting = true
                    Task { await rec.start(mode: mode, micOn: micOn, systemOn: systemOn); starting = false }
                } label: {
                    Label(starting ? "Starting…" : "Start recording · \(mode.rawValue)", systemImage: "record.circle.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(Capsule().fill(Color.primary))
                }
                .buttonStyle(.plain)
                .disabled(starting || (!micOn && !systemOn))
                Text(mode == .audio ? "No video is saved in this mode — audio, transcript and notes only." : "Saves the video, transcript and notes.")
                    .font(.caption).foregroundStyle(mode == .audio ? Color.orange : Color.secondary)
            }
        }
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    HStack(spacing: 10) {
                        Circle().fill(.red).frame(width: 12, height: 12)
                            .opacity(Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.35)
                        Text(MeetingNotes.clock(ctx.date.timeIntervalSince(rec.startedAt)))
                            .font(.system(size: 28, design: .serif).monospacedDigit())
                    }
                }
                Capsule().fill(Color.primary.opacity(0.15)).frame(width: 140, height: 6)
                    .overlay(alignment: .leading) { Capsule().fill(Color.primary).frame(width: 140 * CGFloat(rec.level), height: 6) }
                    .animation(.easeOut(duration: 0.1), value: rec.level)
                Spacer()
                Button {
                    Task { await rec.stop() }
                } label: {
                    Label("Stop & write notes", systemImage: "stop.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 11)
                        .background(Capsule().fill(.red))
                }
                .buttonStyle(.plain)
            }
            Text("Live transcript").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(rec.liveText.isEmpty ? "Listening… text appears every few seconds." : rec.liveText)
                    .foregroundStyle(rec.liveText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 140)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.card))
        }
    }
}

struct MeetingRow: View {
    let m: Meeting
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: m.mode.icon).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(m.title).fontWeight(.medium).lineLimit(1)
                Text(m.status ?? (m.notes.split(separator: "\n").first { !$0.hasPrefix("#") }.map(String.init) ?? ""))
                    .font(.callout).foregroundStyle(m.status == nil ? Color.secondary : Color.orange).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(m.date, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                Text(MeetingNotes.clock(m.duration)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct MeetingDetail: View {
    @Bindable var store = Store.shared
    let id: UUID   // by ID, not list position: the list changes when a recording is added or deleted
    @State private var tab = 0

    var body: some View {
        if let m = store.s.meetings.first(where: { $0.id == id }) { content(m) }
    }

    private var title: Binding<String> {
        Binding(get: { store.s.meetings.first { $0.id == id }?.title ?? "" },
                set: { new in if let i = store.s.meetings.firstIndex(where: { $0.id == id }) { store.s.meetings[i].title = new } })
    }

    private func content(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button { store.meetingID = nil } label: { Label("All recordings", systemImage: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
                if let f = m.file {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)]) } label: { Label("Show recording", systemImage: "film") }
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("# \(m.title)\n\n\(m.notes)\n\n## Transcript\n\(MeetingNotes.transcriptText(m.segments))", forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { MeetingNotes.regenerate(m.id) } label: { Label("Regenerate", systemImage: "sparkles") }.disabled(m.status != nil || m.segments.isEmpty)
                Button(role: .destructive) {
                    let id = m.id
                    store.meetingID = nil
                    store.s.meetings.removeAll { $0.id == id }
                } label: { Image(systemName: "trash") }
            }
            TextField("Title", text: title)
                .font(.system(size: 28, design: .serif)).textFieldStyle(.plain)
            Text("\(m.date.formatted(date: .abbreviated, time: .shortened)) · \(MeetingNotes.clock(m.duration)) · \(m.mode.rawValue) · \(m.source)")
                .font(.callout).foregroundStyle(.secondary)
            if let status = m.status {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Recording stopped and saved.").fontWeight(.medium)
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.paper))
            }
            Picker("", selection: $tab) { Text("Notes").tag(0); Text("Transcript").tag(1) }
                .pickerStyle(.segmented).frame(width: 240)
            if tab == 0 { NotesText(markdown: m.notes) } else { TranscriptView(segments: m.segments) }
        }
    }
}

/// Renders the small markdown subset the notes use: ## headings, - bullets, **bold**.
struct NotesText: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if markdown.isEmpty { Text("Notes will appear here when processing finishes.").foregroundStyle(.secondary) }
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#") {
                    Text(t.trimmingCharacters(in: CharacterSet(charactersIn: "# "))).font(.system(size: 19, weight: .semibold, design: .serif)).padding(.top, 10)
                } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); Text(inline(String(t.dropFirst(2)))) }
                } else if !t.isEmpty {
                    Text(inline(t))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func inline(_ s: String) -> AttributedString { (try? AttributedString(markdown: s)) ?? AttributedString(s) }
}

struct TranscriptView: View {
    let segments: [Segment]
    private let colors: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo]
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if segments.isEmpty { Text("No transcript yet.").foregroundStyle(.secondary) }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .top, spacing: 12) {
                    Text(MeetingNotes.clock(s.start)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.speaker).font(.caption.weight(.semibold)).foregroundStyle(color(s.speaker))
                        Text(s.text).textSelection(.enabled)
                    }
                }
            }
        }
    }
    private func color(_ speaker: String) -> Color {
        speaker == "You" ? .green : colors[(Int(speaker.split(separator: " ").last ?? "") ?? 0) % colors.count]
    }
}

// MARK: - Floating recording bar (stays out of the recording: Kitflo's own windows are excluded from capture)

final class RecordingBar {
    private let panel: NSPanel
    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingBarView())
        if let f = NSScreen.main?.visibleFrame { panel.setFrameOrigin(NSPoint(x: f.midX - 165, y: f.maxY - 70)) }
        panel.orderFrontRegardless()
    }
    func close() { panel.close() }
}

struct RecordingBarView: View {
    let rec = MeetingRecorder.shared
    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                HStack(spacing: 8) {
                    Circle().fill(rec.paused ? .yellow : .red).frame(width: 10, height: 10)
                        .opacity(rec.paused || Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.35)
                    Text(rec.paused ? "Paused" : MeetingNotes.clock(rec.elapsed(ctx.date)))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                        .frame(width: 62, alignment: .leading)
                }
            }
            Divider().frame(height: 22).overlay(.white.opacity(0.2))
            barButton(rec.micLive ? "mic.fill" : "mic.slash.fill", tint: rec.micLive ? .white : .red, help: rec.micLive ? "Mute mic" : "Unmute mic") { rec.toggleMic() }
            if rec.hasCamera {
                barButton(rec.cameraLive ? "video.fill" : "video.slash.fill", tint: rec.cameraLive ? .white : .red, help: rec.cameraLive ? "Hide camera" : "Show camera") { rec.toggleCamera() }
            }
            barButton(rec.paused ? "play.fill" : "pause.fill", tint: .white, help: rec.paused ? "Resume" : "Pause") { rec.paused ? rec.resume() : rec.pause() }
            Button { Task { await rec.stop() } } label: {
                Label("Stop", systemImage: "stop.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7).background(Capsule().fill(.red))
            }
            .buttonStyle(.plain).help("Stop & write notes")
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }

    private func barButton(_ icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 30, height: 30).background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain).help(help)
    }
}

/// Clears Kitflo's stale permission entries and asks macOS again. Needed when a switch shows "on" but belongs to an
/// older build, so macOS ignores it. The user still approves each prompt; a restart makes macOS apply the grants.
enum Permissions {
    static func fix() {
        let id = Bundle.main.bundleIdentifier ?? "com.openflo.app"
        for service in ["Accessibility", "ScreenCapture"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", service, id]
            try? p.run(); p.waitUntilExit()
        }
        Log.write("permissions reset by user")
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        _ = CGRequestScreenCaptureAccess()
    }
}
