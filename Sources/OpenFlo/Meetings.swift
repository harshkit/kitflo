import AppKit
import AVFoundation
import FluidAudio
import Observation
import ScreenCaptureKit

/// What to record: the whole screen, one app (e.g. Zoom) or one window (e.g. a Brave window on the right tab).
enum CaptureSource: Hashable, Identifiable {
    case screen
    case app(bundleID: String, name: String)
    case window(id: CGWindowID, name: String)
    var id: String { label }
    var label: String {
        switch self {
        case .screen: "Entire screen"
        case .app(_, let name): name
        case .window(_, let name): name
        }
    }
}

// MARK: - Recorder: ScreenCaptureKit for screen + system audio + mic, written straight to a movie file

@Observable final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = MeetingRecorder()

    var recording = false
    var startedAt = Date()
    var level: Float = 0
    var liveText = ""
    var error: String?
    var apps: [CaptureSource] = []
    var windows: [CaptureSource] = []

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: SCRecordingOutput?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private let queue = DispatchQueue(label: "openflo.meeting.audio")
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var mic = Track()
    @ObservationIgnored private var sys = Track()
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var camera: CameraBubble?
    @ObservationIgnored private var mode = RecordMode.audio
    @ObservationIgnored private var sourceLabel = ""

    /// One 16 kHz mono track, placed by timestamp so mic and system audio stay in sync even when one goes quiet.
    struct Track {
        var samples: [Float] = []
        var converter: AVAudioConverter?
        var inFormat: AVAudioFormat?
    }
    static let rate = 16000.0
    @ObservationIgnored private var t0: CMTime?

    /// Lists apps and windows you can record from.
    func refreshSources() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            await MainActor.run { error = "Allow Screen Recording for OpenFlo in System Settings → Privacy & Security." }
            return
        }
        let mine = Bundle.main.bundleIdentifier
        let apps = content.applications
            .filter { app in app.bundleIdentifier != mine && content.windows.contains { $0.owningApplication?.processID == app.processID && $0.frame.width > 200 } }
            .map { CaptureSource.app(bundleID: $0.bundleIdentifier, name: $0.applicationName) }
            .sorted { $0.label < $1.label }
        let windows = content.windows
            .filter { $0.owningApplication?.bundleIdentifier != mine && $0.frame.width > 200 && $0.frame.height > 150 && $0.windowLayer == 0 }
            .map { w in CaptureSource.window(id: w.windowID, name: "\(w.owningApplication?.applicationName ?? "Window") — \(w.title?.isEmpty == false ? w.title! : "Untitled")") }
        await MainActor.run { self.apps = apps; self.windows = windows; error = nil }
    }

    func start(mode: RecordMode, source: CaptureSource, micOn: Bool, systemOn: Bool) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw Fail("No display found") }
            let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }

            if mode == .camera {
                await MainActor.run { camera = CameraBubble() }
                try await Task.sleep(for: .milliseconds(400))   // let the bubble appear so it can be captured
            }
            let fresh = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let bubble = fresh.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier && $0.title == CameraBubble.title }

            let filter: SCContentFilter
            switch source {
            case .screen:
                // Everything except OpenFlo's own windows; the camera bubble is the one exception.
                filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: bubble)
            case .app(let id, _):
                guard let app = content.applications.first(where: { $0.bundleIdentifier == id }) else { throw Fail("That app is no longer open") }
                let wins = fresh.windows.filter { $0.owningApplication?.processID == app.processID }
                filter = mode == .camera ? SCContentFilter(display: display, including: wins + bubble)
                                         : SCContentFilter(display: display, including: [app], exceptingWindows: [])
            case .window(let wid, _):
                guard let w = fresh.windows.first(where: { $0.windowID == wid }) else { throw Fail("That window is no longer open") }
                filter = mode == .camera ? SCContentFilter(display: display, including: [w] + bubble) : SCContentFilter(desktopIndependentWindow: w)
            }

            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = systemOn
            cfg.excludesCurrentProcessAudio = true
            cfg.captureMicrophone = micOn
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            if mode == .audio {
                cfg.width = 2; cfg.height = 2
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            } else {
                let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
                cfg.width = Int(filter.contentRect.width) * scale
                cfg.height = Int(filter.contentRect.height) * scale
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                cfg.showsCursor = true
                cfg.queueDepth = 8
            }

            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            if systemOn { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            if micOn { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
            if mode != .audio {
                let url = Self.folder.appending(path: "OpenFlo \(Self.stamp()).mov")
                let rc = SCRecordingOutputConfiguration()
                rc.outputURL = url
                rc.outputFileType = .mov
                rc.videoCodecType = .hevc
                let out = SCRecordingOutput(configuration: rc, delegate: RecordingDelegate.shared)
                try s.addRecordingOutput(out)
                output = out
                fileURL = url
            } else {
                fileURL = nil
            }
            lock.withLock { mic = Track(); sys = Track(); t0 = nil }
            try await s.startCapture()
            stream = s
            self.mode = mode
            sourceLabel = source.label
            await MainActor.run {
                recording = true; startedAt = Date(); liveText = ""; error = nil
            }
            startLiveTranscript()
        } catch {
            await MainActor.run {
                camera?.close(); camera = nil
                self.error = (error as? Fail)?.message ?? "Couldn't start recording. Allow Screen Recording (and Microphone) for OpenFlo in System Settings → Privacy & Security, then try again."
            }
        }
    }

    /// Stops, saves the meeting immediately, then transcribes, labels speakers and writes notes in the background.
    func stop() async {
        guard let s = stream else { return }
        liveTask?.cancel()
        try? await s.stopCapture()
        stream = nil; output = nil
        let (m, y) = lock.withLock { (mic.samples, sys.samples) }
        let duration = Double(max(m.count, y.count)) / Self.rate
        var file = fileURL?.path
        if mode == .audio, let url = try? Self.saveAudio(Self.mix(m, y)) { file = url.path }
        let meeting = Meeting(title: "Recording · \(Date().formatted(date: .abbreviated, time: .shortened))", duration: duration,
                              mode: mode, source: sourceLabel, file: file, status: "Transcribing…")
        await MainActor.run {
            camera?.close(); camera = nil
            recording = false; level = 0
            Store.shared.s.meetings.insert(meeting, at: 0)
            Store.shared.meetingID = meeting.id
        }
        await MeetingNotes.process(id: meeting.id, mic: m, system: y)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone, sb.isValid, let pcm = Self.pcm(sb) else { return }
        let pts = sb.presentationTimeStamp
        lock.withLock {
            if t0 == nil { t0 = pts }
            var track = type == .audio ? sys : mic
            if track.converter == nil || track.inFormat != pcm.format {
                track.inFormat = pcm.format
                track.converter = AVAudioConverter(from: pcm.format, to: Self.monoFormat)
                track.converter?.downmix = true   // stereo system audio → mono, both channels kept
            }
            guard let conv = track.converter,
                  let out = AVAudioPCMBuffer(pcmFormat: Self.monoFormat, frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * Self.rate / pcm.format.sampleRate) + 32)
            else { return }
            var fed = false
            conv.convert(to: out, error: nil) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return pcm
            }
            let chunk = UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
            // Place by timestamp: pad silence if this track skipped time (e.g. no system audio playing).
            let at = Int((pts - t0!).seconds * Self.rate)
            if at > track.samples.count { track.samples += [Float](repeating: 0, count: at - track.samples.count) }
            track.samples += chunk
            if type == .audio { sys = track } else { mic = track }
            let peak = chunk.reduce(0) { max($0, abs($1)) }
            DispatchQueue.main.async { self.level = self.level * 0.6 + min(1, peak * 2) * 0.4 }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.error = "Recording stopped: \(error.localizedDescription)" }
        Task { await stop() }
    }

    // MARK: Live transcript (rough, no speakers; the final pass replaces it)

    private func startLiveTranscript() {
        liveTask = Task.detached { [weak self] in
            var done = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                // Copy only the new audio since the last pass, not the whole recording.
                let (m, y, end) = self.lock.withLock { () -> ([Float], [Float], Int) in
                    let mc = self.mic.samples.count, yc = self.sys.samples.count
                    return (Array(self.mic.samples[min(done, mc)..<mc]), Array(self.sys.samples[min(done, yc)..<yc]), max(mc, yc))
                }
                guard end - done > Int(Self.rate * 3) else { continue }
                let slice = Self.mix(m, y)
                done = end
                if let text = try? await MeetingNotes.transcribe(slice), !text.isEmpty {
                    await MainActor.run { self.liveText += (self.liveText.isEmpty ? "" : " ") + text }
                }
            }
        }
    }

    // MARK: Helpers

    static let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

    static var folder: URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appending(path: "OpenFlo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"; return f.string(from: Date())
    }

    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        let n = max(a.count, b.count)
        return (0..<n).map { i in max(-1, min(1, (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0))) }
    }

    static func saveAudio(_ samples: [Float]) throws -> URL {
        let url = folder.appending(path: "OpenFlo \(stamp()).m4a")
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1])
        let buf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buf)
        return url
    }

    /// CMSampleBuffer (ScreenCaptureKit audio) → AVAudioPCMBuffer.
    static func pcm(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = sb.formatDescription?.audioStreamBasicDescription,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: desc.mSampleRate, channels: desc.mChannelsPerFrame) else { return nil }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList) == noErr else { return nil }
        return buf
    }

    struct Fail: Error { let message: String; init(_ m: String) { message = m } }
}

final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {
    static let shared = RecordingDelegate()
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async { MeetingRecorder.shared.error = "Saving the video failed: \(error.localizedDescription)" }
    }
}

// MARK: - Camera bubble (a floating round webcam view that gets captured with the screen)

final class CameraBubble {
    static let title = "OpenFlo Camera"
    private let panel: NSPanel
    private let session = AVCaptureSession()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 220), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = Self.title
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        view.wantsLayer = true
        view.layer?.cornerRadius = 110
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 3
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        if let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
            session.addInput(input)
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer?.addSublayer(preview)
            DispatchQueue.global().async { [session] in session.startRunning() }
        }
        panel.contentView = view
        if let f = NSScreen.main?.visibleFrame { panel.setFrameOrigin(NSPoint(x: f.minX + 32, y: f.minY + 32)) }
        panel.orderFrontRegardless()
    }

    func close() {
        session.stopRunning()
        panel.close()
    }
}

// MARK: - After recording: who said what, then notes

enum MeetingNotes {
    static let diarizer = Task { () throws -> DiarizerManager in
        var config = DiarizerConfig.default
        config.clusteringThreshold = 0.6   // a bit more willing to split similar voices on a call
        let d = DiarizerManager(config: config)
        d.initialize(models: try await DiarizerModels.downloadIfNeeded())
        return d
    }

    static func transcribe(_ samples: [Float]) async throws -> String {
        guard samples.count > Int(MeetingRecorder.rate * 0.5) else { return "" }
        let asr = try await ParakeetSession.asr.value
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(samples, decoderState: &state).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func process(id: UUID, mic: [Float], system: [Float]) async {
        func update(_ change: @escaping (inout Meeting) -> Void) async {
            await MainActor.run {
                if let i = Store.shared.s.meetings.firstIndex(where: { $0.id == id }) { change(&Store.shared.s.meetings[i]) }
            }
        }
        let segments = await analyze(mic: mic, system: system) { status in await update { $0.status = status } }
        await update { $0.segments = segments; $0.status = "Writing notes…" }
        let (title, notes) = await write(segments)
        await update { m in
            m.notes = notes
            if let title { m.title = title }
            m.status = nil
        }
    }

    /// Who said what. "You" vs everyone else comes from which track the sound is on (mic or system audio), which is
    /// certain; the speaker model only has to tell the other people apart within the system audio.
    static func analyze(mic: [Float], system: [Float], status: (String) async -> Void) async -> [Segment] {
        let rate = MeetingRecorder.rate, n = max(mic.count, system.count)
        guard n > Int(rate) else { return [] }
        await status("Finding speakers…")

        // 1. Turns by source, from 100 ms frames: silent, mic louder, or system louder.
        let hop = Int(rate / 10)
        func rms(_ x: [Float], _ a: Int) -> Float {
            let b = min(a + hop, x.count); guard a < b else { return 0 }
            var s: Float = 0; for i in a..<b { s += x[i] * x[i] }; return sqrt(s / Float(b - a))
        }
        var labels: [Int] = []   // 0 silence, 1 mic, 2 system
        for f in stride(from: 0, to: n, by: hop) {
            let m = rms(mic, f), y = rms(system, f)
            labels.append(max(m, y) < 0.008 ? 0 : (m > y ? 1 : 2))
        }
        var turns: [(src: Int, start: Double, end: Double)] = []
        var i = 0
        while i < labels.count {
            guard labels[i] != 0 else { i += 1; continue }
            let src = labels[i]; var j = i, gap = 0
            // Extend through brief pauses and brief flickers to the other source (echo, overlap); stop at a real pause.
            while j + 1 < labels.count, gap < 5 { j += 1; gap = labels[j] == src ? 0 : gap + 1 }
            let end = j - gap
            if end - i >= 3 { turns.append((src, Double(i) / 10, Double(end + 1) / 10)) }
            i = end + 1
        }

        // 2. Tell remote speakers apart (system track), or in-room speakers when there is only a mic.
        let both = !mic.isEmpty && !system.isEmpty && mic.contains { $0 != 0 } && system.contains { $0 != 0 }
        let diarTrack = both || system.contains { $0 != 0 } ? system : mic
        var diar: [(id: String, s: Double, e: Double)] = []
        do {
            let r = try await diarizer.value.performCompleteDiarization(diarTrack)
            diar = r.segments.map { ($0.speakerId, Double($0.startTimeSeconds), Double($0.endTimeSeconds)) }
            if CommandLine.arguments.contains("--meeting") { print("diarizer:", diar.map { "\($0.id) \($0.s)-\($0.e)" }) }
        } catch {
            if CommandLine.arguments.contains("--meeting") { print("diarizer error:", error) }
        }
        func speaker(_ a: Double, _ b: Double) -> String {
            var best = ("?", 0.0)
            for d in diar { let o = min(b, d.e) - max(a, d.s); if o > best.1 { best = (d.id, o) } }
            return best.0
        }
        // Split turns of the diarized track wherever the speaker model hears a different person.
        var pieces: [(src: Int, who: String, start: Double, end: Double)] = []
        for t in turns {
            let diarized = (t.src == 2) == (diarTrack == system)
            guard diarized else { pieces.append((t.src, "You", t.start, t.end)); continue }
            // Only cut where there's an actual pause: the speaker model works in 10 s chunks and can flip mid-sentence.
            func pause(_ c: Double) -> Bool { let f = Int(c * 10); return (max(0, f - 3)...min(labels.count - 1, f + 3)).contains { labels[$0] == 0 } }
            var cuts = diar.flatMap { [$0.s, $0.e] }.filter { $0 > t.start + 0.5 && $0 < t.end - 0.5 && pause($0) }.sorted()
            cuts = [t.start] + cuts + [t.end]
            for k in 0..<cuts.count - 1 where cuts[k + 1] - cuts[k] > 0.3 {
                pieces.append((t.src, speaker(cuts[k], cuts[k + 1]), cuts[k], cuts[k + 1]))
            }
        }
        // Name remote speakers by how much they talked: Speaker 1 talks most.
        var talk: [String: Double] = [:]
        for p in pieces where p.who != "You" { talk[p.who, default: 0] += p.end - p.start }
        var names: [String: String] = ["You": both ? "You" : "Speaker 1"]
        for (k, id) in talk.keys.sorted(by: { talk[$0]! > talk[$1]! }).enumerated() { names[id] = "Speaker \(k + 1)" }

        // 3. Transcribe each piece from its own track (cleaner than the mix), merging back-to-back lines by the same person.
        var segments: [Segment] = []
        for (k, p) in pieces.enumerated() {
            await status("Transcribing… \(Int(Double(k) / Double(max(pieces.count, 1)) * 100))%")
            let track = p.src == 1 ? mic : system
            let a = max(0, Int((p.start - 0.15) * rate)), b = min(track.count, Int((p.end + 0.15) * rate))
            guard b - a > Int(rate * 0.4), let heard = try? await transcribe(Array(track[a..<b])), !heard.isEmpty else { continue }
            let text = Post.applyVocabulary(heard, Store.shared.s.words)
            let who = names[p.who] ?? "Speaker"
            if let last = segments.last, last.speaker == who { segments[segments.count - 1].text += " " + text }
            else { segments.append(Segment(speaker: who, start: p.start, text: text)) }
        }
        return segments
    }

    /// `OpenFlo --meeting mic.wav system.wav`: runs the same analysis on files and prints it (test mode).
    static func cli(_ micPath: String, _ sysPath: String) async {
        func load(_ p: String) -> [Float] {
            guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: p)),
                  let inBuf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
                  (try? f.read(into: inBuf)) != nil,
                  let conv = AVAudioConverter(from: f.processingFormat, to: MeetingRecorder.monoFormat),
                  let out = AVAudioPCMBuffer(pcmFormat: MeetingRecorder.monoFormat, frameCapacity: AVAudioFrameCount(Double(f.length) * MeetingRecorder.rate / f.processingFormat.sampleRate) + 32)
            else { return [] }
            var fed = false
            conv.convert(to: out, error: nil) { _, st in if fed { st.pointee = .endOfStream; return nil }; fed = true; st.pointee = .haveData; return inBuf }
            return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        }
        LLM.port = 8180
        LLM.start()
        while !(await LLM.ready()) { try? await Task.sleep(for: .milliseconds(300)) }
        let t = Date()
        let segs = await analyze(mic: load(micPath), system: load(sysPath)) { print($0) }
        print(String(format: "analysis %.1fs", Date().timeIntervalSince(t)))
        print(transcriptText(segs))
        let t2 = Date()
        let (title, notes) = await write(segs)
        print(String(format: "notes %.1fs", Date().timeIntervalSince(t2)))
        print("TITLE:", title ?? "-"); print(notes)
        LLM.stop()
    }

    static func transcriptText(_ segments: [Segment]) -> String {
        segments.map { "[\(clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Local LLM notes. Long meetings are summarized in parts first, then combined.
    static func write(_ segments: [Segment]) async -> (String?, String) {
        guard !segments.isEmpty else { return (nil, "No speech was detected in this recording.") }
        // ponytail: ~6k-char parts keep each call inside the 1.5B model's 4k context; a bigger model would give richer notes on long calls.
        var parts: [String] = [], cur = ""
        for line in transcriptText(segments).split(separator: "\n") {
            if cur.count + line.count > 6000 { parts.append(cur); cur = "" }
            cur += line + "\n"
        }
        if !cur.isEmpty { parts.append(cur) }

        var digest = parts.first!
        if parts.count > 1 {
            var points: [String] = []
            for p in parts {
                points.append(await LLM.chat(system: "You summarize part of a meeting transcript. List the important points, decisions and action items (with who owns them) as short bullet points. Use the speaker names exactly as written. Only use facts from the transcript.",
                                             user: p, maxTokens: 400) ?? "")
            }
            digest = points.joined(separator: "\n")
        }
        let out = await LLM.chat(system: """
            You write meeting notes from a transcript (or from bullet points summarizing it). Use only facts that appear in it, and the speaker names exactly as written. Reply in this exact format:
            Title: <a short title, max 8 words>
            ## Summary
            <2–4 sentences>
            ## Key points
            - ...
            ## Decisions
            - ... (or "- None")
            ## Action items
            - <owner>: <task> (or "- None")
            """, user: digest, maxTokens: 700) ?? ""
        guard !out.isEmpty else { return (nil, "Couldn't write notes: the local AI engine isn't running. Open Settings to check it, then press Regenerate.") }
        var lines = out.components(separatedBy: "\n")
        var title: String?
        if let first = lines.first, first.lowercased().hasPrefix("title:") {
            title = first.dropFirst(6).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"*"))
            lines.removeFirst()
        }
        return (title?.isEmpty == false ? title : nil, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func regenerate(_ id: UUID) {
        guard let m = Store.shared.s.meetings.first(where: { $0.id == id }) else { return }
        if let i = Store.shared.s.meetings.firstIndex(where: { $0.id == id }) { Store.shared.s.meetings[i].status = "Writing notes…" }
        Task {
            let (title, notes) = await write(m.segments)
            await MainActor.run {
                if let i = Store.shared.s.meetings.firstIndex(where: { $0.id == id }) {
                    Store.shared.s.meetings[i].notes = notes
                    if let title { Store.shared.s.meetings[i].title = title }
                    Store.shared.s.meetings[i].status = nil
                }
            }
        }
    }
}

extension LLM {
    /// One chat call to the local model; nil if the server isn't reachable.
    static func chat(system: String, user: String, maxTokens: Int) async -> String? {
        let payload: [String: Any] = ["messages": [["role": "system", "content": system], ["role": "user", "content": user]],
                                      "temperature": 0.2, "max_tokens": maxTokens, "cache_prompt": true]
        var req = URLRequest(url: url.appending(path: "v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 120
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let msg = ((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        else { return nil }
        return msg.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
