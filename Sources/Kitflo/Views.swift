import AppKit
import AVFoundation
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home = "Home", notes = "Notes", dictionary = "Dictionary", snippets = "Snippets", style = "Style", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house"
        case .notes: "record.circle"
        case .dictionary: "character.book.closed"
        case .snippets: "scissors"
        case .style: "textformat"
        case .settings: "gearshape"
        }
    }
}

extension Color {
    static let paper = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.11, green: 0.105, blue: 0.1, alpha: 1) : NSColor(red: 0.975, green: 0.965, blue: 0.945, alpha: 1) })
    static let card = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 0.16, alpha: 1) : .white })
}

struct MainView: View {
    @Bindable var store = Store.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 15, weight: .bold))
                    Text("Kitflo").font(.system(size: 17, weight: .semibold, design: .serif))
                }
                .padding(.horizontal, 10).padding(.top, 40).padding(.bottom, 18)
                ForEach(Page.allCases) { p in
                    Button { store.page = p } label: {
                        Label(p.rawValue, systemImage: p.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(store.page == p ? Color.primary.opacity(0.08) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                EngineBadge().padding(10)
            }
            .frame(width: 190)
            .padding(.horizontal, 10)

            ScrollView {
                Group {
                    switch store.page {
                    case .home: HomePage()
                    case .notes: MeetingsPage()
                    case .dictionary: DictionaryPage()
                    case .snippets: SnippetsPage()
                    case .style: StylePage()
                    case .settings: SettingsPage()
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(36)
                .frame(maxWidth: .infinity)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.card).shadow(color: .black.opacity(0.06), radius: 8))
            .padding([.vertical, .trailing], 10)
        }
        .background(Color.paper)
        .ignoresSafeArea()
        .frame(minWidth: 780, minHeight: 520)
    }
}

struct EngineBadge: View {
    let flow = Flow.shared
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(flow.ready ? .green : .orange).frame(width: 7, height: 7)
            Text(flow.ready ? "Local engine ready" : "Loading models…").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Title: View {
    let text: String, sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 30, weight: .regular, design: .serif))
            Text(sub).foregroundStyle(.secondary)
        }
        .padding(.bottom, 20)
    }
}

// MARK: Home

struct HomePage: View {
    let store = Store.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Title(text: "Welcome back, \(NSFullUserName().split(separator: " ").first.map(String.init) ?? "there")",
                  sub: "Hold \(store.s.hotkey.rawValue) and speak in any app. Tap it once for hands-free.")
            SetupWarnings()
            HStack(spacing: 12) {
                Stat(value: "\(store.streak)", label: "day streak", icon: "flame")
                Stat(value: "\(store.weekWords)", label: "words this week", icon: "text.word.spacing")
                Stat(value: "\(store.wpm)", label: "avg WPM", icon: "speedometer")
            }
            Text("History").font(.headline).padding(.top, 6)
            if store.s.history.isEmpty {
                Text("Nothing yet. Put your cursor in any text field, hold the key and talk.")
                    .foregroundStyle(.secondary).padding(.vertical, 30)
            }
            LazyVStack(spacing: 0) {
                ForEach(store.s.history.prefix(200)) { e in
                    HistoryRow(e: e)
                    Divider()
                }
            }
        }
    }
}

struct Stat: View {
    let value: String, label: String, icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, design: .serif))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.paper))
    }
}

struct HistoryRow: View {
    let e: Entry
    @State private var showRaw = false
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(e.date, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(showRaw ? e.raw : e.text).textSelection(.enabled)
                Text(e.app).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { showRaw.toggle() } label: { Image(systemName: showRaw ? "sparkles" : "waveform") }
                .buttonStyle(.borderless).help(showRaw ? "Show cleaned text" : "Show raw transcript")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(e.text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy")
        }
        .padding(.vertical, 12)
    }
}

/// Shows the two setup problems that silently stop auto-paste.
struct SetupWarnings: View {
    let store = Store.shared
    @State private var tick = 0
    var body: some View {
        VStack(spacing: 8) {
            if !AXIsProcessTrusted() {
                Warning(text: "Kitflo can't paste yet. Turn it on in Privacy & Security → Accessibility.",
                        button: "Open Accessibility",
                        url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
            if store.s.hotkey == .fn && store.fnKeyConflicts {
                Warning(text: "Releasing 🌐 fn opens a macOS popup that steals the paste. Set “Press 🌐 key to” → Do Nothing.",
                        button: "Open Keyboard",
                        url: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
            }
        }
        .id(tick)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
    }
}

struct Warning: View {
    let text: String, button: String, url: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            Button(button) { NSWorkspace.shared.open(URL(string: url)!) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }
}

// MARK: Dictionary

struct DictionaryPage: View {
    @Bindable var store = Store.shared
    @State private var word = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Title(text: "Dictionary", sub: "Names, brands and jargon Kitflo should always spell your way.")
            HStack {
                TextField("Add a word, e.g. TrackingFlo", text: $word).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            FlowLayout {
                ForEach(store.s.words, id: \.self) { w in
                    HStack(spacing: 6) {
                        Text(w)
                        Button { store.s.words.removeAll { $0 == w }; Flow.shared.refresh() } label: { Image(systemName: "xmark").font(.caption2) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.paper))
                }
            }
        }
    }
    private func add() {
        let w = word.trimmingCharacters(in: .whitespaces)
        if !w.isEmpty && !store.s.words.contains(w) { store.s.words.append(w); Flow.shared.refresh() }
        word = ""
    }
}

/// Wrapping row layout for word chips.
struct FlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 600, subviews).size
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in arrange(b.width, subviews).points.enumerated() {
            subviews[i].place(at: CGPoint(x: b.minX + p.x, y: b.minY + p.y), proposal: .unspecified)
        }
    }
    private func arrange(_ width: CGFloat, _ views: Subviews) -> (points: [CGPoint], size: CGSize) {
        var pts: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for v in views {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + 8; row = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += s.width + 8; row = max(row, s.height); maxX = max(maxX, x)
        }
        return (pts, CGSize(width: maxX, height: y + row))
    }
}

// MARK: Snippets

struct SnippetsPage: View {
    @Bindable var store = Store.shared
    @State private var trigger = ""
    @State private var expansion = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Title(text: "Snippets", sub: "Say a short cue, get the full text. Say “my calendar link” → your Calendly URL.")
            VStack(spacing: 8) {
                TextField("When I say…", text: $trigger).textFieldStyle(.roundedBorder)
                TextField("Type this", text: $expansion, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button("Add snippet") {
                    store.s.snippets.append(Snippet(trigger: trigger, expansion: expansion)); trigger = ""; expansion = ""
                }.disabled(trigger.isEmpty || expansion.isEmpty) }
            }
            ForEach(store.s.snippets) { sn in
                HStack(alignment: .top) {
                    Text("“\(sn.trigger)”").fontWeight(.medium).frame(width: 180, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(sn.expansion).foregroundStyle(.secondary).lineLimit(3)
                    Spacer()
                    Button { store.s.snippets.removeAll { $0.id == sn.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.paper))
            }
        }
    }
}

// MARK: Style

struct StylePage: View {
    @Bindable var store = Store.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Title(text: "Style", sub: "How your words should read once Kitflo tidies them up.")
            ForEach(Style.allCases) { st in
                Button { store.s.style = st } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(st.rawValue).font(.headline)
                            Text(st.hint).font(.callout).foregroundStyle(.secondary)
                            Text(example(st)).font(.system(.callout, design: .serif)).padding(.top, 4)
                        }
                        Spacer()
                        Image(systemName: store.s.style == st ? "checkmark.circle.fill" : "circle").font(.title3)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.paper))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(store.s.style == st ? Color.primary : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Toggle("AI cleanup (removes ums, fixes grammar, applies corrections)", isOn: $store.s.aiCleanup).padding(.top, 8)
        }
    }
    private func example(_ s: Style) -> String {
        switch s {
        case .formal: "Hi Priya, are we still meeting at 6 PM tomorrow? Let me know."
        case .casual: "Hey Priya, are we still on for 6 tomorrow? Let me know."
        case .veryCasual: "hey priya still on for 6 tomorrow? lmk"
        }
    }
}

// MARK: Settings

struct SettingsPage: View {
    @Bindable var store = Store.shared
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenOK = CGPreflightScreenCaptureAccess()
    private let languages = [("en-IN", "English (India)"), ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("en-AU", "English (Australia)"),
                             ("es-ES", "Spanish"), ("fr-FR", "French"), ("de-DE", "German"), ("it-IT", "Italian"), ("pt-BR", "Portuguese"),
                             ("ja-JP", "Japanese"), ("ko-KR", "Korean"), ("zh-CN", "Chinese")]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Title(text: "Settings", sub: "Everything runs on this Mac. Nothing you say leaves it.")
            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 10) {
                    perm("Microphone", ok: micOK) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    perm("Accessibility (to read the key and paste)", ok: axTrusted) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    HStack {
                        Text("Switch on in System Settings but still shown as off here?").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Fix permissions") { Permissions.fix() }
                        Button("Restart Kitflo") { RecorderCard.relaunch() }
                    }
                    perm("Screen Recording (only for meeting notes)", ok: screenOK) {
                        if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
                    }
                }.padding(8)
            }
            GroupBox("Dictation") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Push-to-talk key", selection: $store.s.hotkey) {
                        ForEach(Hotkey.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if store.s.hotkey == .fn {
                        Text("Tip: in System Settings → Keyboard, set “Press 🌐 key to” → Do Nothing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Language", selection: $store.s.language) {
                        ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .onChange(of: store.s.language) { Flow.shared.refresh() }
                    Picker("Speech engine", selection: $store.s.engine) {
                        ForEach(Engine.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: store.s.engine) { Flow.shared.refresh() }
                    Text(store.s.engine == .parakeet
                         ? "NVIDIA Parakeet on the Neural Engine. One-time 0.7 GB download; Apple is used until it finishes, and for Japanese, Korean and Chinese."
                         : "No download. Often mishears names and tech words from your Dictionary.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Sound effects", isOn: $store.s.sounds)
                }.padding(8)
            }
            GroupBox("Engine") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.s.engine == .parakeet ? "Speech: NVIDIA Parakeet TDT 0.6B v3 + CTC dictionary boost (Neural Engine, FluidAudio)" : "Speech: Apple on-device SpeechAnalyzer (Neural Engine, live streaming)")
                    Text("Cleanup: Qwen2.5 1.5B Instruct (Q4, Metal via llama.cpp)")
                    Text("Models folder: ~/Library/Application Support/Kitflo/models").foregroundStyle(.secondary)
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            HStack {
                Button("Clear history", role: .destructive) { store.s.history.removeAll() }
                Spacer()
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            axTrusted = AXIsProcessTrusted()
            micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            screenOK = CGPreflightScreenCaptureAccess()
        }
    }

    private func perm(_ name: String, ok: Bool, open: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(ok ? .green : .orange)
            Text(name)
            Spacer()
            if !ok { Button("Open Settings", action: open) }
        }
    }
}
