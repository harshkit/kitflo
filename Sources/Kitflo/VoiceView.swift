import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Helpers

extension View {
    func panel() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.paper))
    }
}

func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

struct Chip: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

@MainActor @Observable final class Player: NSObject, AVAudioPlayerDelegate {
    var playing = false
    var progress = 0.0
    var duration = 0.0
    @ObservationIgnored private var p: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    func load(_ url: URL) { set(try? AVAudioPlayer(contentsOf: url)) }
    func load(data: Data) { set(try? AVAudioPlayer(data: data)) }
    private func set(_ new: AVAudioPlayer?) {
        stop(); progress = 0
        p = new; p?.delegate = self; p?.prepareToPlay()
        duration = new?.duration ?? 0
    }
    func toggle() {
        guard let p else { return }
        if p.isPlaying { stop(); return }
        p.play(); playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let s = self, let p = s.p, p.duration > 0 { s.progress = p.currentTime / p.duration } }
        }
    }
    func seek(_ f: Double) { p?.currentTime = f * duration; progress = f }
    func stop() { p?.pause(); timer?.invalidate(); playing = false }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop(); self.seek(0) }
    }
}

struct PlayerBar: View {
    let pl: Player
    var body: some View {
        HStack(spacing: 10) {
            Button { pl.toggle() } label: { Image(systemName: pl.playing ? "pause.fill" : "play.fill").frame(width: 22) }
                .buttonStyle(.borderless).accessibilityLabel(pl.playing ? "Pause" : "Play")
            Slider(value: Binding(get: { pl.progress }, set: { pl.seek($0) }))
            Text(clock(pl.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// Peaks of the source audio; the chosen passage (as 0–1 fractions) is drawn in the accent colour.
struct WaveView: View {
    let peaks: [Double]
    var from = 0.0, to = 1.0
    var body: some View {
        Canvas { ctx, size in
            let n = peaks.count
            guard n > 0 else { return }
            let w = size.width / Double(n)
            for (i, pk) in peaks.enumerated() {
                let f = Double(i) / Double(n), h = max(2, min(1, pk) * size.height)
                let r = CGRect(x: Double(i) * w + 0.5, y: (size.height - h) / 2, width: max(1, w - 1), height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(f >= from && f <= to ? Color.accentColor : Color.secondary.opacity(0.35)))
            }
        }
        .frame(height: 64)
        .accessibilityLabel("Waveform of your recording with the chosen passage highlighted")
    }
}

struct LevelMeter: View {
    let level: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Color.accentColor).frame(width: max(6, g.size.width * level))
            }
        }
        .frame(height: 8).animation(.linear(duration: 0.05), value: level)
        .accessibilityLabel("Microphone level")
    }
}

/// Records a mono wav into voice-tmp with a live level.
@MainActor @Observable final class VoiceRecorder {
    var recording = false
    var level = 0.0
    var seconds = 0.0
    @ObservationIgnored private var rec: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var url: URL?

    /// Returns a plain-words problem, or nil when recording started.
    func start() -> String? {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return "Kitflo needs the microphone. Allow it in System Settings → Privacy & Security → Microphone, then try again."
        }
        try? FileManager.default.createDirectory(at: VoiceEngine.tmpDir, withIntermediateDirectories: true)
        let u = VoiceEngine.tmpDir.appending(path: "rec-\(UUID().uuidString.prefix(8)).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        guard let r = try? AVAudioRecorder(url: u, settings: settings), r.record() else { return "Kitflo couldn't start recording. Check that a microphone is connected." }
        r.isMeteringEnabled = true
        rec = r; url = u; recording = true; seconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let s = self, let r = s.rec else { return }
                r.updateMeters()
                s.level = max(0, min(1, pow(10, Double(r.averagePower(forChannel: 0)) / 40)))
                s.seconds = r.currentTime
            }
        }
        return nil
    }

    func stop() -> URL? {
        timer?.invalidate(); rec?.stop(); rec = nil
        recording = false; level = 0
        return url
    }
}

enum AudioFile {
    /// Video files give up their audio track first; audio files pass through.
    static func audio(from url: URL) async throws -> URL {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true else { return url }
        try? FileManager.default.createDirectory(at: VoiceEngine.tmpDir, withIntermediateDirectories: true)
        let out = VoiceEngine.tmpDir.appending(path: "video-\(UUID().uuidString.prefix(8)).m4a")
        guard let s = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetAppleM4A) else {
            throw VoiceError(message: "Kitflo can't read the sound from this video.")
        }
        do { try await s.export(to: out, as: .m4a) } catch { throw VoiceError(message: "This video has no sound Kitflo can read.") }
        return out
    }

    /// Only real audio or video files from a drop.
    static func accept(_ urls: [URL]) -> URL? {
        urls.first { u in
            guard u.isFileURL, let t = UTType(filenameExtension: u.pathExtension) else { return false }
            return t.conforms(to: .audio) || t.conforms(to: .movie)
        }
    }

    static func pick() -> URL? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .movie]
        return p.runModal() == .OK ? p.url : nil
    }

    static func download(_ src: URL, m4a: Bool) {
        let sp = NSSavePanel()
        sp.nameFieldStringValue = src.deletingPathExtension().lastPathComponent + (m4a ? ".m4a" : ".wav")
        guard sp.runModal() == .OK, let dst = sp.url else { return }
        try? FileManager.default.removeItem(at: dst)
        if !m4a { try? FileManager.default.copyItem(at: src, to: dst); return }
        Task.detached {
            let (code, _) = VoiceEngine.runSync("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", src.path, dst.path])
            if code != 0 { await MainActor.run { NSSound.beep() } }
        }
    }
}

struct DownloadMenu: View {
    let url: URL
    var body: some View {
        Menu {
            Button("WAV (lossless)") { AudioFile.download(url, m4a: false) }
            Button("M4A (smaller)") { AudioFile.download(url, m4a: true) }
        } label: { Label("Download", systemImage: "arrow.down.circle") }
        .menuStyle(.borderlessButton).fixedSize()
    }
}

struct RevealButton: View {
    let url: URL
    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Show in Finder", systemImage: "folder") }
            .buttonStyle(.borderless)
    }
}

struct ErrorLine: View {
    let text: String?
    var body: some View { if let text { Text(text).font(.callout).foregroundStyle(.red) } }
}

/// English, Hindi and Tamil first, then everything else; searchable.
struct LanguagePicker: View {
    @Binding var code: String
    let v = VoiceEngine.shared
    @State private var open = false
    @State private var q = ""
    private static let pinned = ["auto", "en", "hi", "ta"]

    private var items: [VoiceLang] {
        // "auto" lets the engine detect the language, including mixed speech like Hinglish.
        let all = [VoiceLang(code: "auto", name: "Auto (detects mixes like Hinglish)")]
            + (v.languages.isEmpty ? [VoiceLang(code: "en", name: "English"), VoiceLang(code: "hi", name: "Hindi"), VoiceLang(code: "ta", name: "Tamil")] : v.languages)
        if !q.isEmpty { return all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.code == q.lowercased() } }
        return Self.pinned.compactMap { c in all.first { $0.code == c } } + all.filter { !Self.pinned.contains($0.code) }
    }

    var body: some View {
        Button { open = true } label: { HStack(spacing: 6) { Text(v.name(code)); Image(systemName: "chevron.up.chevron.down").font(.caption2) } }
            .accessibilityLabel("Language: \(v.name(code))")
            .popover(isPresented: $open) {
                VStack(spacing: 8) {
                    TextField("Search languages", text: $q).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(items) { l in
                                Button { code = l.code; open = false; q = "" } label: {
                                    HStack { Text(l.name); Spacer(); if l.code == code { Image(systemName: "checkmark") } }
                                        .padding(.vertical, 5).padding(.horizontal, 6).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if q.isEmpty, l.code == Self.pinned.last { Divider() }
                            }
                        }
                    }.frame(height: 260)
                }.padding(12).frame(width: 240)
            }
    }
}

/// Short read-aloud texts. Other languages fall back to English wording; any natural speech works.
enum VoicePrompts {
    static func sentences(_ lang: String) -> [String] { all[lang] ?? all["en"]! }
    static let all: [String: [String]] = [
        "en": ["The quick brown fox jumps over the lazy dog near the old river bridge.",
               "I would like to book a table for two people this Saturday evening.",
               "Please remember to send the report before the meeting starts tomorrow.",
               "On a quiet morning, the sun rose slowly over the green hills.",
               "Can you tell me how to get to the nearest train station from here?",
               "She sells fresh flowers, ripe mangoes and warm bread at the corner market.",
               "Technology works best when it feels simple, calm and almost invisible.",
               "Thank you so much for your help, it really made my day."],
        "hi": ["आज सुबह मौसम बहुत सुहावना था और हल्की ठंडी हवा चल रही थी।",
               "क्या आप मुझे बता सकते हैं कि सबसे नज़दीकी रेलवे स्टेशन कहाँ है?",
               "कृपया कल की बैठक से पहले रिपोर्ट भेजना मत भूलिएगा।",
               "मुझे अपने परिवार के साथ शनिवार की शाम बिताना बहुत अच्छा लगता है।",
               "बाज़ार में ताज़े फल, रंग-बिरंगे फूल और गरम रोटियाँ मिलती हैं।",
               "तकनीक तभी अच्छी लगती है जब वह सरल और शांत हो।",
               "आपकी मदद के लिए बहुत-बहुत धन्यवाद, इससे मेरा दिन बन गया।",
               "धीरे-धीरे सूरज हरी-भरी पहाड़ियों के ऊपर उठ रहा था।"],
        "ta": ["இன்று காலை வானிலை மிகவும் இனிமையாக இருந்தது.",
               "அருகில் உள்ள ரயில் நிலையத்திற்கு எப்படி செல்வது என்று சொல்ல முடியுமா?",
               "நாளைய கூட்டத்திற்கு முன் அறிக்கையை அனுப்ப மறந்துவிடாதீர்கள்.",
               "சனிக்கிழமை மாலை குடும்பத்துடன் நேரம் செலவிடுவது எனக்கு மிகவும் பிடிக்கும்.",
               "சந்தையில் புதிய பழங்களும் வண்ணப் பூக்களும் சூடான ரொட்டியும் கிடைக்கும்.",
               "தொழில்நுட்பம் எளிமையாகவும் அமைதியாகவும் இருக்கும்போது சிறப்பாக இருக்கும்.",
               "உங்கள் உதவிக்கு மிக்க நன்றி, அது என் நாளையே மகிழ்ச்சியாக்கியது.",
               "மெதுவாக சூரியன் பசுமையான மலைகளுக்கு மேலே உதித்துக்கொண்டிருந்தது."],
    ]
}

// MARK: - Page

struct VoicePage: View {
    enum Tab: String, CaseIterable { case speak = "Speak", voices = "Voices", enhance = "Enhance", api = "API" }
    @Bindable var v = VoiceEngine.shared
    @State private var tab = Tab.speak
    @State private var speak = SpeakModel()
    @State private var enhance = EnhanceModel()
    @State private var mem: UInt64?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Title(text: "Voice", sub: "Type text and hear it in your voice. Clone voices, clean up recordings. Everything runs on this Mac.")
            if !v.installed {
                SetupCard()
            } else if v.phase != .ready {
                StartingCard()
            } else {
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                switch tab {
                case .speak: SpeakTab(m: speak)
                case .voices: VoicesTab { id in Store.shared.s.voiceID = id; tab = .speak }
                case .enhance: EnhanceTab(m: enhance)
                case .api: APITab()
                }
            }
            if v.installed, let mem {
                Text("Voice engine: \(ByteCountFormatter.string(fromByteCount: Int64(mem), countStyle: .memory))")
                    .font(.caption).foregroundStyle(.tertiary).padding(.top, 8)
            }
        }
        .onAppear { v.start() }   // lazy: the ~5 GB engine only starts once you open this page
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if Store.shared.page == .voice { v.start() }   // window reopened after the engine slept
        }
        .task {
            while !Task.isCancelled {
                mem = v.memoryBytes()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

struct SetupCard: View {
    let v = VoiceEngine.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up Voice").font(.system(size: 20, design: .serif))
            Text("Voice runs entirely on your Mac. One setup downloads:").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Label("The Python engine, about 2.5 GB (now)", systemImage: "shippingbox")
                Label("The OmniVoice voice model, 3.3 GB (first start)", systemImage: "waveform")
                Label("Whisper, 1.6 GB (the first time you clone a voice)", systemImage: "text.bubble")
            }.font(.callout)
            Text("The OmniVoice model weights are licensed CC-BY-NC: audio you generate is for non-commercial use.")
                .font(.callout).foregroundStyle(.secondary)
            if v.phase == .settingUp {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(v.message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            } else {
                if case .failed(let m) = v.phase { ErrorLine(text: m) }
                Button("Set up voice") { Task { await v.setup() } }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }.panel()
    }
}

struct StartingCard: View {
    let v = VoiceEngine.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .failed(let m) = v.phase {
                ErrorLine(text: m)
                Button("Try again") { v.stop(); v.start() }
            } else if v.phase == .idle {
                Text("The voice engine is asleep to save memory.").foregroundStyle(.secondary)
                Button("Wake it up") { v.start() }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Starting voice engine…") }
                Text(v.message).font(.caption).foregroundStyle(.secondary)
            }
        }.panel()
    }
}

// MARK: - Speak

@MainActor @Observable final class SpeakModel {
    var text = ""
    var speed = 1.0
    var busy = false
    var started = Date()
    var result: SpeakResult?
    var error: String?
    var progress: Double?
    var message = ""
    var recent = VoiceEngine.shared.recent()
    var recentPlaying: URL?
    let player = Player()
    let recentPlayer = Player()

    func generate() {
        let s = Store.shared.s
        busy = true; error = nil; started = Date(); player.stop(); progress = nil; message = ""
        Task {
            do {
                let v = VoiceEngine.shared
                let r: SpeakResult
                if text.count > 400 || s.voicePreset == "studio" {
                    r = try await v.speakJob(voiceID: s.voiceID, language: s.voiceLanguage, text: text, preset: s.voicePreset, speed: speed) { p, m in
                        Task { @MainActor in self.progress = p; self.message = m ?? "" }
                    }
                } else {
                    r = try await v.speak(voiceID: s.voiceID, language: s.voiceLanguage, text: text, preset: s.voicePreset, speed: speed)
                }
                result = r
                player.load(URL(fileURLWithPath: r.path)); player.toggle()
                recent = VoiceEngine.shared.recent()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    func playRecent(_ u: URL) {
        player.stop()
        if recentPlaying != u { recentPlayer.load(u); recentPlaying = u }
        recentPlayer.toggle()
    }
}

struct SpeakTab: View {
    @Bindable var m: SpeakModel
    @Bindable var store = Store.shared
    let v = VoiceEngine.shared
    private static let limit = 5000
    private static let presets = [("fast", "Fast", "Quickest draft. Good for trying lines."),
                                  ("balanced", "Balanced", "Natural quality at a reasonable speed."),
                                  ("studio", "Studio", "Makes three takes and keeps the best. Slowest.")]

    private var missingSample: Bool {
        guard let vp = v.voices.first(where: { $0.id == store.s.voiceID }) else { return false }
        return store.s.voiceLanguage != "auto" && vp.languages[store.s.voiceLanguage] == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Picker("Voice", selection: $store.s.voiceID) {
                    Text("Default voice").tag("")
                    ForEach(v.voices) { Text($0.name).tag($0.id) }
                }.fixedSize()
                HStack(spacing: 6) { Text("Language").foregroundStyle(.secondary); LanguagePicker(code: $store.s.voiceLanguage) }
            }
            if missingSample {
                Label("Add a \(v.name(store.s.voiceLanguage)) sample for a native accent. Until then this voice speaks with its own accent.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .trailing, spacing: 4) {
                TextEditor(text: $m.text).font(.body)
                    .onChange(of: m.text) { _, t in if t.count > Self.limit { m.text = String(t.prefix(Self.limit)) } }.scrollContentBackground(.hidden).padding(8)
                    .frame(minHeight: 150)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.paper))
                Text("\(m.text.count) / \(Self.limit) characters").font(.caption).foregroundStyle(m.text.count >= Self.limit ? .red : .secondary)
                if m.text.count >= Self.limit { Text("That's the limit for one go. Longer text is cut off, so generate the rest as a second part.").font(.caption).foregroundStyle(.red) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Picker("Quality", selection: $store.s.voicePreset) { ForEach(Self.presets, id: \.0) { Text($0.1).tag($0.0) } }
                    .pickerStyle(.segmented).frame(maxWidth: 360)
                Text(Self.presets.first { $0.0 == store.s.voicePreset }?.2 ?? "").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Speed").foregroundStyle(.secondary)
                Slider(value: $m.speed, in: 0.7...1.3, step: 0.05).frame(width: 200)
                Text(String(format: "%.2fx", m.speed)).font(.caption.monospacedDigit())
            }
            if v.training {
                Label("Your voice is training. Speaking is paused until it finishes. You can cancel on the Voices tab.", systemImage: "pause.circle")
                    .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
            }
            HStack(spacing: 12) {
                Button { m.generate() } label: { Text("Generate").padding(.horizontal, 8) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(m.busy || v.training || m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if m.busy {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: .now, by: 1)) { c in
                        Text("Generating… \(clock(c.date.timeIntervalSince(m.started)))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if m.busy, let p = m.progress {
                ProgressView(value: p) { Text(m.message.isEmpty ? "Working…" : m.message).font(.caption).foregroundStyle(.secondary) }
            }
            ErrorLine(text: m.error)
            if let r = m.result { ResultCard(r: r, player: m.player, voiceName: v.name(store.s.voiceLanguage)) }
            recentList
        }
        .onChange(of: store.s.voiceID) { _, _ in warm() }
        .onChange(of: store.s.voiceLanguage) { _, _ in warm() }
    }

    private func warm() {
        let id = store.s.voiceID, lang = store.s.voiceLanguage
        if !id.isEmpty { Task { await v.warm(id, lang) } }
    }

    @ViewBuilder var recentList: some View {
        if !m.recent.isEmpty {
            Text("Recent").font(.headline).padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(m.recent, id: \.self) { u in
                    HStack {
                        Button { m.playRecent(u) } label: { Image(systemName: m.recentPlaying == u && m.recentPlayer.playing ? "pause.fill" : "play.fill") }
                            .buttonStyle(.borderless).accessibilityLabel("Play \(u.lastPathComponent)")
                        Text(u.deletingPathExtension().lastPathComponent).font(.callout).lineLimit(1)
                        Spacer()
                        DownloadMenu(url: u)
                    }.padding(.vertical, 8)
                    Divider()
                }
            }
        }
    }
}

struct ResultCard: View {
    let r: SpeakResult, player: Player, voiceName: String
    private func pct(_ x: Double) -> String { "\(Int((x <= 1 ? x * 100 : x).rounded()))%" }
    var body: some View {
        let url = URL(fileURLWithPath: r.path)
        VStack(alignment: .leading, spacing: 10) {
            PlayerBar(pl: player)
            HStack(spacing: 8) {
                Chip(text: clock(r.duration_s))
                if let m = r.match {
                    Chip(text: "Voice match \(pct(m))")
                        .help("How close this is to your real voice. 100% = as close as your own recordings are to each other.")
                }
                if let c = r.intelligibility { Chip(text: "Clarity \(pct(c))") }
                Spacer()
                DownloadMenu(url: url)
                RevealButton(url: url)
            }
            if r.language_matched == false {
                Text("This voice has no \(voiceName) sample, so it used its own language. Add a sample in Voices for a native accent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.panel()
    }
}

// MARK: - Voices

struct VoicesTab: View {
    var onSpeak: (String) -> Void = { _ in }
    let v = VoiceEngine.shared
    @State private var player = Player()
    @State private var renaming: VoiceProfile?
    @State private var newName = ""
    @State private var deleting: VoiceProfile?
    @State private var error: String?
    @State private var showNew = false
    @State private var addTo: VoiceProfile?
    @State private var proFor: VoiceProfile?
    @State private var removingPro: VoiceProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your voices").font(.headline)
                Spacer()
                Button { addTo = nil; showNew = true } label: { Label("New voice", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            ErrorLine(text: error)
            if v.voices.isEmpty {
                Text("No voices yet. Make one from a short recording of someone speaking, or use the default voice on the Speak tab.")
                    .foregroundStyle(.secondary).padding(.vertical, 24)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(v.voices) { vp in card(vp) }
            }
        }
        .sheet(isPresented: $showNew) { NewVoiceSheet(existing: addTo) }
        .sheet(item: $proFor) { ProSheet(voiceID: $0.id) }
        .confirmationDialog("Remove Pro training from “\(removingPro?.name ?? "")”?", isPresented: Binding(get: { removingPro != nil }, set: { if !$0 { removingPro = nil } })) {
            Button("Remove Pro training", role: .destructive) { if let d = removingPro { run { try await v.proRemove(d.id) } } }
        } message: { Text("The voice keeps working from its samples. You can train it again later.") }
        .alert("Rename voice", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let r = renaming { run { try await v.rename(r.id, to: newName) } } }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete voice", role: .destructive) { if let d = deleting { run { try await v.delete(d.id) } } }
        } message: { Text("This removes the voice and all its language samples from this Mac.") }
    }

    private func run(_ f: @escaping () async throws -> Void) {
        Task { do { try await f(); error = nil } catch { self.error = error.localizedDescription } }
    }

    private func card(_ vp: VoiceProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(vp.name).font(.system(size: 17, design: .serif)).lineLimit(1)
                if vp.pro?.enabled == true { Text("PRO").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.accentColor.opacity(0.2))) }
                Spacer()
                Menu {
                    Button("Rename…") { newName = vp.name; renaming = vp }
                    Button("Add language…") { addTo = vp; showNew = true }
                    if vp.pro != nil {
                        Divider()
                        Toggle("Use Pro voice", isOn: Binding(get: { vp.pro?.enabled == true }, set: { on in run { try await v.proEnable(vp.id, on) } }))
                        Button("Remove Pro training…") { removingPro = vp }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = vp }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More for \(vp.name)")
            }
            FlowRow(spacing: 6) {
                ForEach(vp.languages.keys.sorted(), id: \.self) { code in
                    HStack(spacing: 4) {
                        Text(v.name(code)).font(.caption)
                        Button {
                            run {
                                player.load(data: try await v.preview(vp.id, code)); player.toggle()
                            }
                        } label: { Image(systemName: "play.fill").font(.system(size: 9)) }
                            .buttonStyle(.borderless).accessibilityLabel("Preview \(vp.name) in \(v.name(code))")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .contextMenu { if vp.languages.count > 1 { Button("Remove \(v.name(code))", role: .destructive) { run { try await v.deleteLanguage(vp.id, code) } } } }
                }
            }
            if let r = v.pro, r.voiceID == vp.id, r.kind == .train, r.running {
                Label("Training… \(Int(r.fraction * 100))%", systemImage: "waveform.badge.magnifyingglass").font(.caption).foregroundStyle(.orange)
            }
            Button { onSpeak(vp.id) } label: { Label("Speak with this voice", systemImage: "text.bubble").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            HStack {
                Button { addTo = vp; showNew = true } label: { Label("Add language", systemImage: "plus.circle").font(.caption) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                Spacer()
                Button { proFor = vp } label: { Label(vp.pro == nil ? "Pro training" : "Retrain", systemImage: "sparkles").font(.caption) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }.panel()
    }
}

/// Wraps its children onto new lines when they don't fit.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal.width ?? 300, subviews).size
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (s, p) in zip(subviews, layout(b.width, subviews).points) { s.place(at: CGPoint(x: b.minX + p.x, y: b.minY + p.y), proposal: .unspecified) }
    }
    private func layout(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x = 0.0, y = 0.0, rowH = 0.0, maxW = 0.0, pts: [CGPoint] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y)); x += sz.width + spacing; rowH = max(rowH, sz.height); maxW = max(maxW, x)
        }
        return (CGSize(width: maxW, height: y + rowH), pts)
    }
}

// MARK: New voice sheet

struct NewVoiceSheet: View {
    enum Step { case choose, quick, review, trainIntro, train, training }
    let existing: VoiceProfile?
    let v = VoiceEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.choose
    @State private var lang = Store.shared.s.voiceLanguage
    @State private var rec = VoiceRecorder()
    @State private var player = Player()
    @State private var name = ""
    @State private var consent = false
    @State private var working: String?
    @State private var error: String?
    @State private var prepared: Prepared?
    @State private var transcript = ""
    @State private var idx = 0
    @State private var job: VoiceJob?
    @State private var dropping = false

    init(existing: VoiceProfile?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
    }

    private var prompts: [String] { VoicePrompts.sentences(lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(existing.map { "Add a language to \($0.name)" } ?? "New voice").font(.system(size: 22, design: .serif))
                Spacer()
                Button("Close") { _ = rec.stop(); player.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            if step != .train, step != .training {
                HStack(spacing: 6) { Text("Language of the recording").foregroundStyle(.secondary); LanguagePicker(code: $lang) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch step {
                    case .choose: choose
                    case .quick: quick
                    case .review: review
                    case .trainIntro: trainIntro
                    case .train: train
                    case .training: training
                    }
                    ErrorLine(text: error)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24).frame(width: 580, height: 560)
        .background(Color.card)
        .onDisappear { _ = rec.stop() }
    }

    // Step 1
    private var choose: some View {
        VStack(spacing: 12) {
            option("Quick clone", "Record about 10 seconds, or pick an audio file. Ready in under a minute.", "bolt") { step = .quick }
            option("Train my voice (most accurate)", "Read about 8 short sentences (1–2 minutes). Kitflo picks the best-sounding passage.", "waveform.badge.mic") { step = .trainIntro }
        }
    }

    private func option(_ t: String, _ sub: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).frame(width: 34)
                VStack(alignment: .leading, spacing: 3) { Text(t).font(.headline); Text(sub).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                Spacer()
            }.panel().contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // Quick clone: record or choose a file
    private var quick: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let working { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(working).foregroundStyle(.secondary) }.panel() } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Read this aloud, then keep talking naturally for a few more seconds:").font(.callout).foregroundStyle(.secondary)
                    Text(prompts[0]).font(.system(size: 18, design: .serif))
                    HStack(spacing: 12) {
                        Button {
                            if rec.recording, let u = rec.stop() { Task { await prepare(u) } }
                            else { error = rec.start() }
                        } label: { Label(rec.recording ? "Stop" : "Record", systemImage: rec.recording ? "stop.fill" : "mic.fill") }
                            .buttonStyle(.borderedProminent).tint(rec.recording ? .red : .accentColor)
                        if rec.recording { LevelMeter(level: rec.level); Text(clock(rec.seconds)).font(.caption.monospacedDigit()) }
                    }
                }.panel()
                VStack(spacing: 8) {
                    Text("Or use a recording you already have").font(.callout).foregroundStyle(.secondary)
                    Button("Choose audio file…") { if let u = AudioFile.pick() { Task { await prepare(u) } } }
                    Text("or drop a file here").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(18)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(dropping ? Color.accentColor : .secondary.opacity(0.5)))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let u = AudioFile.accept(urls) else { return false }
                    Task { await prepare(u) }; return true
                } isTargeted: { dropping = $0 }
            }
        }
    }

    private func prepare(_ url: URL) async {
        error = nil
        working = "Finding your best passage… the first time this also downloads Whisper (1.6 GB)."
        defer { working = nil }
        do {
            let audio = try await AudioFile.audio(from: url)
            // Sources of 20 s or more get their top passages test-cloned, which takes longer.
            if let d = try? await AVURLAsset(url: audio).load(.duration).seconds, d >= 20 {
                working = "Testing passages to find your best match… (about 1–2 min)"
            }
            let p = try await v.prepare(audio.path, language: lang)
            prepared = p; transcript = p.ref_text
            player.load(URL(fileURLWithPath: p.ref_path))
            step = .review
        } catch { self.error = error.localizedDescription }
    }

    // Quick clone: review and save
    @ViewBuilder private var review: some View {
        if let p = prepared {
            let src = max(p.source_duration_s, 0.001)
            VStack(alignment: .leading, spacing: 8) {
                Text("Kitflo picked the highlighted passage (\(clock(p.duration_s))) from your recording.").font(.callout).foregroundStyle(.secondary)
                WaveView(peaks: p.waveform, from: p.start / src, to: p.end / src)
                PlayerBar(pl: player)
            }.panel()
            VStack(alignment: .leading, spacing: 6) {
                Text("What was said (fix any mistakes, it helps the clone)").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $transcript).scrollContentBackground(.hidden).padding(6).frame(height: 80)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.paper))
            }
            if let q = p.quality {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recording quality: \(Int(q.score))/100").font(.headline)
                    ForEach(q.checks) { c in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(c.ok ? .green : .orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.message).font(.callout)
                                if !c.ok, let t = c.tip { Text(t).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }.panel()
            }
            identity
            HStack {
                Button("Try again") { prepared = nil; player.stop(); step = .quick }
                Spacer()
                Button(working == nil ? "Save voice" : "Saving…") { Task { await save(p) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!consent || name.trimmingCharacters(in: .whitespaces).isEmpty || transcript.trimmingCharacters(in: .whitespaces).isEmpty || working != nil)
            }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 8) {
            if existing == nil { TextField("Voice name", text: $name).textFieldStyle(.roundedBorder) }
            Toggle("This is my voice, or I have the speaker's permission to clone it", isOn: $consent)
        }
    }

    private func save(_ p: Prepared) async {
        error = nil; working = "Saving…"
        defer { working = nil }
        do {
            let saved = try await v.save(voiceID: existing?.id, name: name.trimmingCharacters(in: .whitespaces), language: lang, refPath: p.ref_path, refText: transcript)
            Store.shared.s.voiceID = saved.id
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    // Train
    private var trainIntro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You'll read 8 short sentences, one at a time. Find a quiet room and speak at your normal pace. Kitflo records continuously, so just move on with Next.")
                .foregroundStyle(.secondary)
            identity
            HStack {
                Button("Back") { step = .choose }
                Spacer()
                Button("Start recording") {
                    if let e = rec.start() { error = e } else { error = nil; idx = 0; step = .train }
                }.buttonStyle(.borderedProminent).disabled(!consent || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var train: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sentence \(idx + 1) of \(prompts.count)").font(.callout).foregroundStyle(.secondary)
            Text(prompts[idx]).font(.system(size: 24, design: .serif)).frame(minHeight: 110, alignment: .topLeading)
            HStack { Image(systemName: "mic.fill").foregroundStyle(.red); LevelMeter(level: rec.level); Text(clock(rec.seconds)).font(.caption.monospacedDigit()) }
            HStack {
                Spacer()
                if idx + 1 < prompts.count {
                    Button("Next") { idx += 1 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Finish") { if let u = rec.stop() { Task { await startTraining(u) } } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }.panel()
    }

    private func startTraining(_ url: URL) async {
        step = .training; job = nil; error = nil
        v.jobs += 1
        defer { v.jobs -= 1 }
        do {
            defer { VoiceEngine.discardTemp(url.path) }   // after the job ends, success or not
            let id = try await v.train(voiceID: existing?.id, name: name.trimmingCharacters(in: .whitespaces), language: lang, audioPath: url.path)
            while true {
                let j = try await v.job(id)
                job = j
                if j.state == "done" { await v.reload(); if let vp = j.result?.voice { Store.shared.s.voiceID = vp.id }; return }
                if j.state == "failed" { error = j.error ?? "Training didn't finish. Try again in a quieter room."; return }
                try await Task.sleep(for: .seconds(1.5))
            }
        } catch { self.error = error.localizedDescription }
    }

    private var training: some View {
        VStack(alignment: .leading, spacing: 12) {
            if job?.state == "done", let vp = job?.result?.voice {
                Label("Your voice is ready", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                Text("“\(vp.name)” now speaks \(vp.languages.keys.sorted().map { v.name($0) }.joined(separator: ", ")). Pick it on the Speak tab.").foregroundStyle(.secondary)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            } else if error == nil {
                Text("Training your voice…").font(.headline)
                ProgressView(value: job?.progress ?? 0)
                Text(job?.message ?? "Starting…").font(.callout).foregroundStyle(.secondary)
                Text("This can take a few minutes. You can close this window; training continues.").font(.caption).foregroundStyle(.tertiary)
            } else {
                Button("Back") { error = nil; step = .trainIntro }
            }
        }.panel()
    }
}

// MARK: - Enhance

@MainActor @Observable final class EnhanceModel {
    var input: URL?
    var level = "clean"
    var busy = false
    var error: String?
    var result: EnhanceResult?
    var showAfter = true
    let before = Player()
    let after = Player()
    var current: Player { showAfter ? after : before }

    func choose(_ u: URL) {
        input = u; result = nil; error = nil
        before.load(u); after.stop()
    }

    func run() {
        guard let input else { return }
        busy = true; error = nil; before.stop(); after.stop()
        Task {
            do {
                let audio = try await AudioFile.audio(from: input)
                before.load(audio)
                let r = try await VoiceEngine.shared.enhance(audio.path, level: level)
                result = r
                after.load(URL(fileURLWithPath: r.path))
                showAfter = true
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    /// Swap between Before and After at the same spot in the clip.
    func select(after wantAfter: Bool) {
        guard wantAfter != showAfter else { return }
        let from = current, to = wantAfter ? after : before
        let was = from.playing
        from.stop(); to.seek(from.progress)
        showAfter = wantAfter
        if was { to.toggle() }
    }
}

struct EnhanceTab: View {
    @Bindable var m: EnhanceModel
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                if let u = m.input { Label(u.lastPathComponent, systemImage: "waveform").lineLimit(1) }
                else { Text("Drop an audio or video file here").foregroundStyle(.secondary) }
                Button(m.input == nil ? "Choose file…" : "Choose another…") { if let u = AudioFile.pick() { m.choose(u) } }
            }
            .frame(maxWidth: .infinity).padding(22)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(dropping ? Color.accentColor : .secondary.opacity(0.5)))
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = AudioFile.accept(urls) else { return false }
                m.choose(u); return true
            } isTargeted: { dropping = $0 }
            VStack(alignment: .leading, spacing: 6) {
                Picker("Level", selection: $m.level) { Text("Clean").tag("clean"); Text("Studio").tag("studio") }
                    .pickerStyle(.segmented).frame(maxWidth: 240)
                Text(m.level == "clean" ? "Removes background noise and evens out loudness." : "Clean, plus a warmer, fuller sound like a treated room.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { m.run() } label: { Text("Enhance").padding(.horizontal, 8) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(m.input == nil || m.busy)
                if m.busy { ProgressView().controlSize(.small); Text("Enhancing…").foregroundStyle(.secondary) }
            }
            ErrorLine(text: m.error)
            if let r = m.result {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: Binding(get: { m.showAfter }, set: { m.select(after: $0) })) {
                        Text("Before").tag(false); Text("After").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
                    PlayerBar(pl: m.current)
                    HStack {
                        Chip(text: clock(r.duration_s))
                        if let a = r.before_lufs, let b = r.after_lufs { Chip(text: String(format: "%.0f → %.0f LUFS", a, b)) }
                        Spacer()
                        DownloadMenu(url: URL(fileURLWithPath: r.path))
                        RevealButton(url: URL(fileURLWithPath: r.path))
                    }
                }.panel()
            }
        }
    }
}

// MARK: - API

struct APITab: View {
    let v = VoiceEngine.shared
    @State private var reveal = false
    @State private var confirm = false
    @State private var copied: String?
    private var base: String { "http://127.0.0.1:\(VoiceEngine.port)/v1" }
    private var shownKey: String { reveal ? v.api.key : "kf_" + String(repeating: "•", count: 32) }

    private func snippets(_ key: String) -> (curl: String, py: String) {
        ("""
        curl \(base)/audio/speech \\
          -H "Authorization: Bearer \(key)" \\
          -H "Content-Type: application/json" \\
          -d '{"model":"kitflo","input":"Hello from Kitflo","voice":"default","response_format":"wav"}' \\
          -o hello.wav
        """, """
        from openai import OpenAI

        client = OpenAI(base_url="\(base)", api_key="\(key)")
        with client.audio.speech.with_streaming_response.create(
            model="kitflo", voice="default", input="Hello from Kitflo", response_format="wav"
        ) as r:
            r.stream_to_file("hello.wav")
        """)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Enable the local voice API", isOn: Binding(get: { v.api.enabled }, set: { v.saveAPI(enabled: $0) })).toggleStyle(.switch)
            Text("Other apps and scripts on this Mac can use your voices with the OpenAI speech format. It only listens on this Mac, never on the network.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                row("Base URL", base, copy: base)
                row("API key", shownKey, copy: v.api.key)
                HStack {
                    Button(reveal ? "Hide key" : "Show key") { reveal.toggle() }
                    Button("Regenerate…") { confirm = true }
                }
            }.panel()
            snippet("curl", snippets(shownKey).curl, copy: snippets(v.api.key).curl)
            snippet("Python (OpenAI SDK)", snippets(shownKey).py, copy: snippets(v.api.key).py)
        }
        .onAppear { v.ensureKey() }
        .confirmationDialog("Make a new API key?", isPresented: $confirm) {
            Button("Regenerate key", role: .destructive) { v.saveAPI(regenerate: true) }
        } message: { Text("Anything using the old key stops working until you update it.") }
    }

    private func row(_ label: String, _ value: String, copy: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).font(.system(.callout, design: .monospaced)).lineLimit(1).textSelection(.enabled)
            Spacer()
            copyButton(copy, id: label)
        }
    }

    private func copyButton(_ text: String, id: String) -> some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            copied = id
            Task { try? await Task.sleep(for: .seconds(1.5)); if copied == id { copied = nil } }
        } label: { Image(systemName: copied == id ? "checkmark" : "doc.on.doc") }
            .buttonStyle(.borderless).accessibilityLabel("Copy \(id)")
    }

    private func snippet(_ title: String, _ shown: String, copy: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.headline); Spacer(); copyButton(copy, id: title) }
            ScrollView(.horizontal) { Text(shown).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
        }.panel()
    }
}

// MARK: - Pro training

struct ProSheet: View {
    let voiceID: String
    let v = VoiceEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var player = Player()
    @State private var playing: String?
    @State private var picks: [Int: String] = [:]
    @State private var revealed = false

    private var voice: VoiceProfile? { v.voices.first { $0.id == voiceID } }
    private var run: ProRun? { v.pro?.voiceID == voiceID ? v.pro : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Pro training: \(voice?.name ?? "voice")").font(.system(size: 22, design: .serif))
                Spacer()
                Button("Close") { player.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                    ErrorLine(text: v.proError)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24).frame(width: 600, height: 600).background(Color.card)
    }

    @ViewBuilder private var content: some View {
        if let run {
            switch (run.kind, run.job?.state ?? "running") {
            case (.scan, "running"): scanning(run)
            case (.scan, "done"): report(run)
            case (.train, "running"): training(run)
            case (.train, "done"): abTest(run)
            default: failed(run)
            }
        } else { intro }
    }

    // Intro
    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pro training teaches the voice model your voice itself, like professional voice cloning services. It sounds closer to you than a quick clone, especially over long text.")
            VStack(alignment: .leading, spacing: 8) {
                Label("30 minutes or more of only your voice: no music, no one else talking. Natural, varied speech works best (calls, voice notes, videos).", systemImage: "mic")
                Label("A few minutes to scan your files, then about 1–2 hours of training. Keep your Mac plugged in. Speaking is paused while it trains.", systemImage: "clock")
                Label("About 100 MB of disk per voice. Your audio never leaves this Mac.", systemImage: "internaldrive")
            }.font(.callout).foregroundStyle(.secondary)
            Button("Choose folder…") { chooseFolder() }.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.message = "Choose a folder with recordings of this voice (subfolders are included)."
        guard p.runModal() == .OK, let u = p.url else { return }
        v.proScan(voiceID, folder: u.path)
    }

    // Scan
    private func scanning(_ run: ProRun) -> some View {
        let d = run.job?.detail
        return VStack(alignment: .leading, spacing: 10) {
            Text("Scanning your files…").font(.headline)
            ProgressView(value: Double(d?.files_done ?? 0), total: Double(max(d?.files_total ?? 1, 1)))
            Text("File \((d?.files_done ?? 0) + 1) of \(d?.files_total ?? 0)  ·  \(String(format: "%.1f", d?.kept_minutes ?? 0)) minutes of your voice kept so far")
                .font(.callout).foregroundStyle(.secondary)
            if let f = d?.file { Text(f).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            Button("Cancel") { Task { await v.proCancel() } }
        }.panel()
    }

    private static let reasons = ["other_speaker": "someone else's voice", "music_or_noise": "music or background noise",
                                  "clipping": "distorted (too loud) audio", "no_speech": "silence or unclear speech"]

    private func report(_ run: ProRun) -> some View {
        let r = run.job?.result
        let kept = r?.kept_minutes ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.1), lineWidth: 8)
                    Circle().trim(from: 0, to: min(1, kept / 30)).stroke(r?.enough == true ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(Int(kept))").font(.system(size: 22, design: .serif))
                }.frame(width: 80, height: 80)
                    .accessibilityElement(children: .ignore).accessibilityLabel("\(Int(kept)) of 30 minutes")
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(String(format: "%.1f", kept)) of 30 minutes of your voice").font(.headline)
                    let dropped = (r?.dropped ?? [:]).filter { $0.value >= 0.05 }.sorted { $0.value > $1.value }
                    ForEach(dropped, id: \.key) { k, m in
                        Text("\(String(format: "%.1f", m)) min left out: \(Self.reasons[k] ?? k)").font(.callout).foregroundStyle(.secondary)
                    }
                    if let f = r?.files_failed, f > 0 { Text("\(f) file\(f == 1 ? "" : "s") couldn't be read").font(.callout).foregroundStyle(.secondary) }
                }
            }
            if r?.enough != true {
                Label("Training works best with 30+ minutes. You can still try.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let s = r?.samples, !s.isEmpty {
                Text("Clips Kitflo kept").font(.headline)
                ForEach(Array(s.prefix(5).enumerated()), id: \.offset) { i, path in sample(path, "Kept clip \(i + 1)", nil) }
            }
            if let s = r?.rejected_samples, !s.isEmpty {
                Text("Clips left out").font(.headline)
                ForEach(Array(s.prefix(3).enumerated()), id: \.offset) { i, x in
                    sample(x.path, "Left out \(i + 1)", Self.reasons[x.reason] ?? x.reason)
                }
            }
            HStack {
                Button("Scan another folder") { player.stop(); v.pro = nil }
                Spacer()
                Button("Start training") {
                    player.stop()
                    if let d = r?.dataset_id { v.proTrain(voiceID, dataset: d) }
                }.buttonStyle(.borderedProminent).disabled(r?.dataset_id == nil || kept < 1)
            }
        }
    }

    private func sample(_ path: String, _ label: String, _ reason: String?) -> some View {
        HStack {
            Button {
                if playing != path { player.load(URL(fileURLWithPath: path)); playing = path }
                player.toggle()
            } label: { Image(systemName: playing == path && player.playing ? "pause.fill" : "play.fill") }
                .buttonStyle(.borderless).accessibilityLabel("Play \(label)")
            Text(label).font(.callout)
            if let reason { Text("(\(reason))").font(.callout).foregroundStyle(.secondary) }
        }
    }

    // Training
    private func training(_ run: ProRun) -> some View {
        let d = run.job?.detail
        return VStack(alignment: .leading, spacing: 12) {
            Text("Training your voice…").font(.headline)
            ProgressView(value: run.fraction)
            Text("Step \(d?.step ?? 0) of \(d?.steps ?? 0)" + (d?.eta_s.map { "  ·  about \(Self.eta($0)) left" } ?? "")).font(.callout).foregroundStyle(.secondary)
            Sparkline(values: v.proLoss).frame(height: 50).accessibilityLabel("Training loss, going down is good")
            Text(run.job?.message ?? "").font(.caption).foregroundStyle(.tertiary)
            Text("Keep your Mac plugged in. You can close this window; training continues. Speaking is paused until it finishes.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Cancel training") { Task { await v.proCancel() } }
        }.panel()
    }

    private static func eta(_ s: Double) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(m, 1)) min"
    }

    private func failed(_ run: ProRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(run.kind == .scan ? "The scan didn't finish." : "Training didn't finish.").font(.headline)
            Text(run.job?.error ?? "It was cancelled. Your voice still works as before.").foregroundStyle(.secondary)
            Button("Back") { v.pro = nil }
        }.panel()
    }

    // Blind A/B test
    private struct Pair { let k: Int; let a: String; let b: String }

    private func pairs(_ dir: String) -> [Pair] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".wav") }
        return names.filter { $0.hasPrefix("A-") }.sorted().compactMap { a in
            let tail = String(a.dropFirst(2))
            guard names.contains("B-" + tail), let k = Int(tail.dropLast(4)) else { return nil }
            return Pair(k: k, a: dir + "/" + a, b: dir + "/B-" + tail)
        }
    }

    /// Which letter is the Pro take, and the sentence, per pair: from the job result, else ab.json beside the ab folder.
    private func abPairs(_ r: ProJob.Result?) -> [Int: ProJob.Pair] {
        var list = r?.pairs
        if list == nil, let dir = r?.ab_dir {
            let u = URL(fileURLWithPath: dir).deletingLastPathComponent().appending(path: "ab.json")
            struct F: Decodable { let pairs: [ProJob.Pair]? }
            list = (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode(F.self, from: $0) }?.pairs
        }
        return Dictionary(uniqueKeysWithValues: (list ?? []).map { ($0.k, $0) })
    }

    private func abTest(_ run: ProRun) -> some View {
        let r = run.job?.result
        let ps = r?.ab_dir.map(pairs) ?? []
        let letters = abPairs(r)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Training finished. Which sounds more like you?").font(.headline)
            Text("Listen to each pair. Kitflo doesn't say which is which until you've chosen.").font(.callout).foregroundStyle(.secondary)
            ForEach(ps, id: \.k) { p in
                if let t = letters[p.k]?.text { Text("“\(t)”").font(.callout).foregroundStyle(.secondary) }
                HStack(spacing: 14) {
                    Text("Pair \(p.k)").frame(width: 50, alignment: .leading)
                    ForEach([("A", p.a), ("B", p.b)], id: \.0) { l, path in
                        Button { if playing != path { player.load(URL(fileURLWithPath: path)); playing = path }; player.toggle() } label: {
                            Label(l, systemImage: playing == path && player.playing ? "pause.fill" : "play.fill")
                        }.accessibilityLabel("Play \(l) of pair \(p.k)")
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { picks[p.k] ?? "" }, set: { picks[p.k] = $0 })) {
                        Text("Choose").tag(""); Text("A sounds more like me").tag("A"); Text("B sounds more like me").tag("B")
                    }.labelsHidden().frame(width: 190).disabled(revealed)
                }
            }.panel()
            if !revealed {
                Button("Reveal") { player.stop(); revealed = true }
                    .buttonStyle(.borderedProminent).disabled(ps.isEmpty || picks.filter { $0.value != "" }.count < ps.count)
            } else {
                reveal(r, ps, letters)
            }
        }
    }

    @ViewBuilder private func reveal(_ r: ProJob.Result?, _ ps: [Pair], _ letters: [Int: ProJob.Pair]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if letters.isEmpty {
                Text("Thanks for listening.").font(.headline)
            } else {
                let n = ps.filter { picks[$0.k] != nil && picks[$0.k] == letters[$0.k]?.pro }.count
                Text("You picked Pro \(n)/\(ps.count)").font(.headline)
            }
            if let b = r?.scores?["base"], let p = r?.scores?["pro"] {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow { Text(""); Text("Before").foregroundStyle(.secondary); Text("Pro").foregroundStyle(.secondary) }
                    GridRow { Text("Voice match"); Text(pct(b.match)); Text(pct(p.match)) }
                    GridRow { Text("Naturalness"); Text(b.utmos.map { String(format: "%.1f / 5", $0) } ?? "–"); Text(p.utmos.map { String(format: "%.1f / 5", $0) } ?? "–") }
                    GridRow { Text("Accuracy"); Text(pct(b.cer.map { 1 - $0 })); Text(pct(p.cer.map { 1 - $0 })) }
                }.font(.callout)
            }
            Text("Use the Pro voice from now on?").font(.headline).padding(.top, 6)
            HStack {
                Button("Yes, use Pro") { finish(true) }.buttonStyle(.borderedProminent)
                Button("No, keep the quick clone") { finish(false) }
            }
        }.panel()
    }

    private func pct(_ x: Double?) -> String { x.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }

    private func finish(_ on: Bool) {
        Task { try? await v.proEnable(voiceID, on); v.pro = nil; dismiss() }
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            if values.count > 1, let lo = values.min(), let hi = values.max() {
                Path { p in
                    for (i, x) in values.enumerated() {
                        let pt = CGPoint(x: g.size.width * Double(i) / Double(values.count - 1), y: g.size.height * (1 - (hi > lo ? (x - lo) / (hi - lo) : 0.5)))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }.stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
    }
}
