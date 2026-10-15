import AppKit
import AVFoundation
import FluidAudio
import Observation
import ScreenCaptureKit
import Vision

// MARK: - Recorder: ScreenCaptureKit for screen + system audio + mic, written straight to a movie file

@Observable final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver {
    static let shared = MeetingRecorder()

    var recording = false
    var startedAt = Date()
    var level: Float = 0
    var liveText = ""
    var error: String?
    var pickedLabel = "Entire screen"
    var paused = false
    var micLive = true
    var cameraLive = true
    var pausedSeconds = 0.0          // total time spent paused, for the on-screen timer
    var pauseStart: Date?
    var hasCamera: Bool { camera != nil }
    func elapsed(_ now: Date) -> Double { now.timeIntervalSince(startedAt) - pausedSeconds - (pauseStart.map { now.timeIntervalSince($0) } ?? 0) }
    @ObservationIgnored private var config = SCStreamConfiguration()
    @ObservationIgnored private var micAttached = false
    @ObservationIgnored private var videoURL: URL?
    @ObservationIgnored var videoStart: CMTime?                       // host time the movie file's first frame was written
    @ObservationIgnored private var pauses: [(CMTime, CMTime?)] = []  // host-time pause intervals, cut out at Stop
    @ObservationIgnored private var pausedAt: CMTime?
    @ObservationIgnored private var pausedTotal = CMTime.zero
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "kitflo.meeting.video")
    @ObservationIgnored private let ocrQueue = DispatchQueue(label: "kitflo.meeting.ocr", qos: .utility)
    @ObservationIgnored private var lastOCR = CMTime.zero
    @ObservationIgnored private var screenLines: [String] = []
    @ObservationIgnored private var bar: RecordingBar?
    @ObservationIgnored private var picked: SCContentFilter?   // nil = entire main screen

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: SCRecordingOutput?
    @ObservationIgnored private let queue = DispatchQueue(label: "kitflo.meeting.audio")
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

    /// Opens macOS's own picker (thumbnails of every screen, window and app) to choose what to record.
    func choose() {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        if let me = Bundle.main.bundleIdentifier { config.excludedBundleIDs = [me] }
        picker.defaultConfiguration = config
        picker.remove(self)
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func useEntireScreen() { picked = nil; pickedLabel = "Entire screen" }

    /// Releases the system picker so macOS stops showing the "being shared" badge on the chosen window.
    private func releasePicker() {
        SCContentSharingPicker.shared.isActive = false
        SCContentSharingPicker.shared.remove(self)
    }

    /// Called on quit: stop any capture right away so nothing keeps the mic or screen after Kitflo exits.
    func shutdown() {
        releasePicker()
        guard let s = stream else { return }
        let done = DispatchSemaphore(value: 0)
        s.stopCapture { _ in done.signal() }
        _ = done.wait(timeout: .now() + 2)
        stream = nil
        Log.write("stopped capture on quit")
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let label: String
        switch filter.style {
        case .window:
            let w = filter.includedWindows.first
            label = [w?.owningApplication?.applicationName, w?.title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " — ")
        case .application:
            label = filter.includedApplications.map(\.applicationName).joined(separator: ", ")
        default:
            let id = filter.includedDisplays.first?.displayID
            label = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }?.localizedName ?? "Screen"
        }
        DispatchQueue.main.async {
            self.picked = filter
            self.pickedLabel = label.isEmpty ? "Selected window" : label
            self.error = nil
            self.releasePicker()
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { self.releasePicker() }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { self.error = "Couldn't open the picker. Allow Screen Recording for Kitflo in System Settings → Privacy & Security." }
    }

    func start(mode: RecordMode, micOn: Bool, systemOn: Bool) async {
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

            // The picked source, or the main screen. Camera mode adds the camera bubble window so it's in the video.
            let filter: SCContentFilter
            switch picked?.style {
            case .window?, .application?:
                let p = picked!
                if mode == .camera {
                    let ids = Set(p.includedWindows.map(\.windowID))
                    let apps = Set(p.includedApplications.map(\.processID))
                    let wins = fresh.windows.filter { ids.contains($0.windowID) || apps.contains($0.owningApplication?.processID ?? -1) }
                    let onDisplay = fresh.displays.first { $0.frame.intersects(wins.first?.frame ?? .zero) } ?? display
                    filter = SCContentFilter(display: onDisplay, including: wins + bubble)
                } else {
                    filter = p
                }
            default:
                // A whole screen: everything except Kitflo's own windows; the camera bubble is the one exception.
                let id = picked?.includedDisplays.first?.displayID ?? display.displayID
                let screen = fresh.displays.first { $0.displayID == id } ?? display
                filter = SCContentFilter(display: screen, excludingApplications: mine, exceptingWindows: bubble)
            }

            var cfg = SCStreamConfiguration()
            Log.write("start mode=\(mode.rawValue) source=\(pickedLabel) mic=\(micOn) system=\(systemOn) screenPerm=\(CGPreflightScreenCaptureAccess())")
            cfg.capturesAudio = systemOn
            cfg.excludesCurrentProcessAudio = true
            cfg.captureMicrophone = micOn
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            if mode == .audio {
                cfg.width = 128; cfg.height = 128
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            } else {
                let scale = CGFloat(filter.pointPixelScale)
                cfg.width = Int(filter.contentRect.width * scale)
                cfg.height = Int(filter.contentRect.height * scale)
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                cfg.showsCursor = true
                cfg.queueDepth = 8
            }

            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            if systemOn { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            // Attach the mic only when it's on: an attached mic output makes macOS open the microphone even if muted.
            if micOn { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue); micAttached = true } else { micAttached = false }
            videoURL = nil; videoStart = nil; pauses = []; screenLines = []; lastOCR = .zero
            if mode != .audio {
                try addVideo(to: s)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)   // for reading on-screen text
            }
            lock.withLock { mic = Track(); sys = Track(); t0 = nil; pausedAt = nil; pausedTotal = .zero }
            do { try await s.startCapture() }
            catch let e as NSError where e.domain == SCStreamErrorDomain && micOn {
                // The mic can be busy for a moment (another app, or Kitflo's dictation). Retry once, then go without it.
                Log.write("mic busy (\(e.code)), retrying")
                try await Task.sleep(for: .seconds(1))
                do { try await s.startCapture() }
                catch {
                    cfg.captureMicrophone = false
                    try await s.updateConfiguration(cfg)
                    try await s.startCapture()
                    await MainActor.run { self.error = "Your microphone was busy, so this recording has system audio only. Use the mic button on the bar to try again." }
                }
            }
            stream = s
            config = cfg
            self.mode = mode
            sourceLabel = pickedLabel
            await MainActor.run {
                recording = true; startedAt = Date(); liveText = ""; error = nil
                paused = false; pausedSeconds = 0; pauseStart = nil; micLive = micOn; cameraLive = true
                bar = RecordingBar()
            }
            Log.write("started ok")
            startLiveTranscript()
        } catch {
            let ns = error as NSError
            Log.write("start FAILED: \(ns.domain) \(ns.code) \(ns.localizedDescription) screenPerm=\(CGPreflightScreenCaptureAccess())")
            await MainActor.run {
                camera?.close(); camera = nil
                if let f = error as? Fail { self.error = f.message }
                else if !CGPreflightScreenCaptureAccess() {
                    self.error = "macOS hasn't given Kitflo Screen Recording yet. Use “Fix permissions” below, allow it, then restart Kitflo."
                } else {
                    self.error = "Couldn't start recording: \(ns.localizedDescription) (\(ns.domain) \(ns.code))"
                }
            }
        }
    }

    /// One continuous movie file. Pause doesn't touch it; the paused stretches are cut out when you press Stop.
    private func addVideo(to s: SCStream) throws {
        let url = Self.folder.appending(path: "Kitflo \(Self.stamp()).mov")
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = url
        rc.outputFileType = .mov
        rc.videoCodecType = .hevc
        let out = SCRecordingOutput(configuration: rc, delegate: RecordingDelegate.shared)
        try s.addRecordingOutput(out)
        output = out
        videoURL = url
    }

    func pause() {
        guard recording, !paused else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lock.withLock { pausedAt = now; pauses.append((now, nil)) }
        paused = true; pauseStart = Date()
        Log.write("paused")
    }

    func resume() {
        guard recording, paused else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lock.withLock {
            if let p = pausedAt { pausedTotal = pausedTotal + (now - p) }
            pausedAt = nil
            if let last = pauses.indices.last { pauses[last].1 = now }
        }
        if let p = pauseStart { pausedSeconds += Date().timeIntervalSince(p) }
        paused = false; pauseStart = nil
        Log.write("resumed")
    }

    func toggleMic() {
        guard let s = stream else { return }
        micLive.toggle()
        if micLive && !micAttached {
            do { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue); micAttached = true }
            catch { micLive = false; self.error = "Couldn't turn the mic on: \(error.localizedDescription)"; return }
        }
        config.captureMicrophone = micLive
        let cfg = config
        Task { try? await s.updateConfiguration(cfg) }
    }

    func toggleCamera() {
        cameraLive.toggle()
        camera?.setVisible(cameraLive)
    }

    /// `Kitflo --record-test`: records the screen 3 s, pauses 1 s, records 3 s more, stops, and reports the files (test mode).
    func recordTest() async {
        await start(mode: CommandLine.arguments.contains("--audio") ? .audio : .screen, micOn: false, systemOn: true)
        print("started:", recording, error ?? "")
        try? await Task.sleep(for: .seconds(3)); pause()
        try? await Task.sleep(for: .seconds(2)); resume()
        try? await Task.sleep(for: .seconds(3))
        if CommandLine.arguments.contains("--stop-paused") { pause(); try? await Task.sleep(for: .seconds(3)) }
        let file = await stop(process: false)
        print("file:", file ?? "nil", "exists:", file.map { FileManager.default.fileExists(atPath: $0) } ?? false)
        if let f = file, let d = try? await AVURLAsset(url: URL(fileURLWithPath: f)).load(.duration) { print("duration:", d.seconds) }
        print((try? String(contentsOf: Log.url, encoding: .utf8))?.split(separator: "\n").suffix(8).joined(separator: "\n") ?? "")
    }

    /// Stops, saves the meeting immediately, then transcribes, labels speakers and writes notes in the background.
    @discardableResult
    func stop(process: Bool = true) async -> String? {
        guard let s = stream else { return nil }
        liveTask?.cancel()
        try? await s.stopCapture()
        stream = nil; output = nil
        await MainActor.run { bar?.close(); bar = nil; releasePicker() }
        let (m, y) = lock.withLock { (mic.samples, sys.samples) }
        let duration = Double(max(m.count, y.count)) / Self.rate
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let cuts = lock.withLock { pauses.map { ($0.0, $0.1 ?? now) } }
        var file = videoURL?.path
        if let url = videoURL {
            await Self.waitUntilWritten(url)   // macOS finishes the movie file a moment after capture stops
            if !cuts.isEmpty, let start = videoStart { file = await Self.cut(url, pauses: cuts, start: start).path }
            let ok = FileManager.default.fileExists(atPath: file ?? "")
            Log.write("video \(ok ? "saved" : "MISSING") \(file ?? "") size=\((try? FileManager.default.attributesOfItem(atPath: file ?? "")[.size] as? Int) ?? -1)")
        }
        let screen = ocrQueue.sync { screenLines.joined(separator: "\n") }
        Log.write("stopped duration=\(Int(duration))s pauses=\(cuts.count) screenLines=\(screen.split(separator: "\n").count)")
        if mode == .audio, let url = try? Self.saveAudio(Self.mix(m, y)) { file = url.path }
        guard process else { await MainActor.run { camera?.close(); camera = nil; recording = false; paused = false; pauseStart = nil }; return file }
        var meeting = Meeting(title: "Recording · \(Date().formatted(date: .abbreviated, time: .shortened))", duration: duration,
                              mode: mode, source: sourceLabel, file: file, status: "Transcribing…")
        meeting.screenText = screen.isEmpty ? nil : screen
        await MainActor.run {
            camera?.close(); camera = nil
            recording = false; level = 0; paused = false; pauseStart = nil
            Store.shared.s.meetings.insert(meeting, at: 0)
            Store.shared.meetingID = meeting.id
        }
        await MeetingNotes.process(id: meeting.id, mic: m, system: y, screen: screen)
        return file
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen { readScreen(sb); return }
        guard type == .audio || type == .microphone, sb.isValid, let pcm = Self.pcm(sb) else { return }
        let pts = sb.presentationTimeStamp
        lock.withLock {
            if pausedAt != nil { return }   // paused: nothing goes into the transcript
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
            let at = Int((pts - t0! - pausedTotal).seconds * Self.rate)
            if at > track.samples.count { track.samples += [Float](repeating: 0, count: at - track.samples.count) }
            track.samples += chunk
            if type == .audio { sys = track } else { mic = track }
            let peak = chunk.reduce(0) { max($0, abs($1)) }
            DispatchQueue.main.async { self.level = self.level * 0.6 + min(1, peak * 2) * 0.4 }
        }
    }

    /// Every ~8 s, reads the text on screen (Apple Vision, on-device) so the notes can cover what you showed.
    private func readScreen(_ sb: CMSampleBuffer) {
        let pts = sb.presentationTimeStamp
        // ScreenCaptureKit also sends "idle" frames (nothing changed) with no image; only complete frames are readable.
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        guard pausedAt == nil, (pts - lastOCR).seconds > 8, let image = sb.imageBuffer else { return }
        lastOCR = pts
        ocrQueue.async { [weak self] in
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate   // runs every ~8 s on a background queue, so accuracy over speed
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cvPixelBuffer: image).perform([req])
            if CommandLine.arguments.contains("--record-test") { print("ocr frame: \(req.results?.count ?? -1) text boxes") }
            let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.3 }.map(\.string)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 3 }
            guard let self else { return }
            for l in lines where !self.screenLines.contains(l) && self.screenLines.count < 600 { self.screenLines.append(l) }
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

    static var defaultFolder: URL { FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appending(path: "Kitflo") }

    static var folder: URL {
        let dir = Store.shared.s.recordingsFolder.map { URL(fileURLWithPath: $0) } ?? defaultFolder
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

    /// Waits (up to ~10 s) until the movie file is complete and readable.
    static func waitUntilWritten(_ url: URL) async {
        for _ in 0..<50 {
            if let d = try? await AVURLAsset(url: url).load(.duration), d.seconds > 0 { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        Log.write("video still not readable after 10 s")
    }

    /// Removes the paused stretches from the movie. Keeps the original unless the trimmed copy is verified good.
    static func cut(_ url: URL, pauses: [(CMTime, CMTime)], start: CMTime) async -> URL {
        let asset = AVURLAsset(url: url)
        guard let total = try? await asset.load(.duration), total > .zero else { Log.write("cut: source unreadable"); return url }
        let comp = AVMutableComposition()
        do { try await comp.insertTimeRange(CMTimeRange(start: .zero, duration: total), of: asset, at: .zero) }
        catch { Log.write("cut: insert failed \(error.localizedDescription)"); return url }
        for (a, b) in pauses.reversed() {
            let s = CMTimeMaximum(.zero, a - start), e = CMTimeMinimum(total, b - start)
            if e > s { comp.removeTimeRange(CMTimeRange(start: s, end: e)) }
        }
        let tmp = url.deletingLastPathComponent().appending(path: ".trim-\(UUID().uuidString).mov")
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return url }
        do {
            try await export.export(to: tmp, as: .mov)
            let d = try await AVURLAsset(url: tmp).load(.duration)
            guard d.seconds > 0.5 else { throw MeetingRecorder.Fail("trimmed file empty") }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            Log.write("cut: removed \(pauses.count) pause(s), \(String(format: "%.1f", total.seconds))s → \(String(format: "%.1f", d.seconds))s")
            return url
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            Log.write("cut failed, kept the full recording: \(error.localizedDescription)")
            return url
        }
    }

    static func saveAudio(_ samples: [Float]) throws -> URL {
        let url = folder.appending(path: "Kitflo \(stamp()).m4a")
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
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        MeetingRecorder.shared.videoStart = CMClockGetTime(CMClockGetHostTimeClock())
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async { MeetingRecorder.shared.error = "Saving the video failed: \(error.localizedDescription)" }
    }
}

// MARK: - Camera bubble (a floating round webcam view that gets captured with the screen)

final class CameraBubble {
    static let title = "Kitflo Camera"
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

    func setVisible(_ on: Bool) {
        if on { panel.alphaValue = 1; DispatchQueue.global().async { [session] in session.startRunning() } }
        else { panel.alphaValue = 0; session.stopRunning() }   // stays in the capture filter, just invisible
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

    static func process(id: UUID, mic: [Float], system: [Float], screen: String = "") async {
        func update(_ change: @escaping (inout Meeting) -> Void) async {
            await MainActor.run {
                if let i = Store.shared.s.meetings.firstIndex(where: { $0.id == id }) { change(&Store.shared.s.meetings[i]) }
            }
        }
        let segments = await analyze(mic: mic, system: system) { status in await update { $0.status = status } }
        await update { $0.segments = segments; $0.status = "Writing notes…" }
        let (title, notes) = await write(segments, screen: screen)
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
        var names: [String: String] = ["You": "You"]
        for (k, id) in talk.keys.sorted(by: { talk[$0]! > talk[$1]! }).enumerated() { names[id] = "Speaker \(k + 1)" }
        // Only a mic and one voice on it: that's you.
        if !both, diarTrack == mic, talk.count == 1, let only = talk.keys.first { names[only] = "You" }

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

    /// `Kitflo --meeting mic.wav system.wav`: runs the same analysis on files and prints it (test mode).
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

    static let notesRules = """
        You turn a meeting or screen recording into accurate notes. Use ONLY what is in the transcript and the on-screen text. \
        Never invent people, products, events or context that are not there. Use the speaker names exactly as written \
        ("You" is the person who recorded). If something isn't mentioned, write "- None". Keep notes short when the recording is short.
        Reply in exactly this format:
        Title: <max 8 words>
        ## Summary
        <1–3 sentences: what this was about and the outcome>
        ## Key points
        - <the important things said or shown>
        ## Action items
        - <who>: <what to do next> (or "- None")
        ## Decisions
        - <decision> (or "- None")
        """

    // A worked example keeps the small model on format and on the facts.
    static let notesShot = ("""
        Transcript:
        [0:00] You: Let's fix the login page first, then do pricing.
        [0:05] Speaker 1: OK, I'll take login, done by Friday.

        On screen:
        Login
        Forgot password?
        Pricing: $9 Starter, $29 Pro
        """, """
        Title: Login and pricing priorities
        ## Summary
        The team agreed to fix the login page before working on pricing.
        ## Key points
        - The login page comes first, pricing after
        - The login screen shown has a Forgot password link
        - Pricing shown: $9 Starter and $29 Pro plans
        ## Action items
        - Speaker 1: Fix the login page by Friday
        - You: Start on pricing once login is done
        ## Decisions
        - Login is the first priority
        """)

    /// Local LLM notes. Long meetings are summarized in parts first, then combined.
    static func write(_ segments: [Segment], screen: String = "") async -> (String?, String) {
        guard !segments.isEmpty || !screen.isEmpty else { return (nil, "No speech was detected in this recording.") }
        // ponytail: ~5k-char parts plus ≤1.5k chars of screen text keep each call inside the 1.5B model's 4k context.
        var parts: [String] = [], cur = ""
        for line in transcriptText(segments).split(separator: "\n") {
            if cur.count + line.count > 5000 { parts.append(cur); cur = "" }
            cur += line + "\n"
        }
        if !cur.isEmpty || parts.isEmpty { parts.append(cur) }

        var digest = parts.first!
        if parts.count > 1 {
            var points: [String] = []
            for p in parts {
                points.append(await LLM.chat(system: "You summarize part of a meeting transcript. List the important points, decisions and action items (with who owns them) as short bullet points. Use the speaker names exactly as written. Only use facts from the transcript.",
                                             user: p, maxTokens: 400) ?? "")
            }
            digest = points.joined(separator: "\n")
        }
        let screenPart = screen.isEmpty ? "" : "\n\nOn screen:\n" + String(screen.prefix(1500))
        let out = await LLM.chat(system: notesRules, user: "Transcript:\n" + (digest.isEmpty ? "(no speech)" : digest) + screenPart,
                                 maxTokens: 700, shots: [notesShot]) ?? ""
        guard !out.isEmpty else { return (nil, "Couldn't write notes: the local AI engine isn't running. Open Settings to check it, then press Regenerate.") }
        var lines = out.components(separatedBy: "\n")
        var title: String?
        if let first = lines.first, first.lowercased().hasPrefix("title:") {
            title = first.dropFirst(6).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"*"))
            lines.removeFirst()
        }
        // Keep the layout consistent even when the small model skips a section or repeats a line.
        var seen = Set<String>()
        lines = lines.filter { l in !l.hasPrefix("- ") || seen.insert(l.lowercased()).inserted }
        var notes = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for section in ["## Summary", "## Key points", "## Action items", "## Decisions"] where !notes.contains(section) {
            notes += "\n\(section)\n- None"
        }
        return (title?.isEmpty == false ? title : nil, notes)
    }

    static func regenerate(_ id: UUID) {
        guard let m = Store.shared.s.meetings.first(where: { $0.id == id }) else { return }
        if let i = Store.shared.s.meetings.firstIndex(where: { $0.id == id }) { Store.shared.s.meetings[i].status = "Writing notes…" }
        Task {
            let (title, notes) = await write(m.segments, screen: m.screenText ?? "")
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
    static func chat(system: String, user: String, maxTokens: Int, shots: [(String, String)] = []) async -> String? {
        var messages = [["role": "system", "content": system]]
        for (q, a) in shots { messages += [["role": "user", "content": q], ["role": "assistant", "content": a]] }
        messages.append(["role": "user", "content": user])
        let payload: [String: Any] = ["messages": messages,
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
