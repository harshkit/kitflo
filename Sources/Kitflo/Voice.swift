import AppKit
import AVFoundation
import CryptoKit
import Observation
import UniformTypeIdentifiers

// MARK: - Voice sidecar (Python, OmniVoice) — contract in voice/API.md

struct VoiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct VoiceLang: Codable, Hashable, Identifiable {
    let code: String, name: String
    var id: String { code }
}

struct VoiceLangInfo: Codable, Hashable {
    var ref_text: String?
    var duration_s: Double?
}

struct ProInfo: Codable, Hashable {
    var enabled: Bool?
}

struct VoiceProfile: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var languages: [String: VoiceLangInfo] = [:]
    var pro: ProInfo?
}

/// Scan and Pro-training jobs (voice/PRO.md): progress in `detail`, outcome in `result`.
struct ProJob: Decodable {
    struct Detail: Decodable {
        var file: String?
        var files_done: Int?
        var files_total: Int?
        var kept_minutes: Double?
        var step: Int?
        var steps: Int?
        var loss: Double?
        var eta_s: Double?
    }
    struct Rejected: Decodable { let path: String; let reason: String }
    struct Pair: Decodable { let k: Int; let text: String?; let pro: String }
    struct Score: Decodable { var match: Double?; var utmos: Double?; var cer: Double? }
    struct Result: Decodable {
        var dataset_id: String?
        var files_total: Int?
        var files_failed: Int?
        var kept_minutes: Double?
        var dropped_minutes: Double?
        var dropped: [String: Double]?
        var samples: [String]?
        var rejected_samples: [Rejected]?
        var enough: Bool?
        var voice: VoiceProfile?
        var scores: [String: Score]?
        var ab_dir: String?
        var pairs: [Pair]?
    }
    let state: String
    let progress: Double?
    let message: String?
    let detail: Detail?
    let result: Result?
    let error: String?
}

struct ProRun {
    enum Kind { case scan, train }
    let kind: Kind
    let voiceID: String
    var jobID: String?
    var job: ProJob?
    var running: Bool { job == nil || job?.state == "running" }
    /// 0–1 while training; falls back to the job's own progress.
    var fraction: Double {
        if let d = job?.detail, let s = d.step, let n = d.steps, n > 0 { return Double(s) / Double(n) }
        return job?.progress ?? 0
    }
}

struct PrepCheck: Codable, Identifiable {
    let id: String
    let ok: Bool
    let message: String
    let tip: String?
}

struct PrepQuality: Codable {
    let score: Double
    let checks: [PrepCheck]
}

struct Prepared: Codable {
    let ref_path: String
    let ref_text: String
    let start: Double, end: Double
    let duration_s: Double
    let source_duration_s: Double
    let language: String?
    let waveform: [Double]
    let quality: PrepQuality?
}

struct VoiceJob: Codable {
    struct Result: Codable { let voice: VoiceProfile }
    let state: String
    let progress: Double?
    let message: String?
    let result: Result?
    let error: String?
}

struct SpeakResult: Codable {
    let path: String
    let duration_s: Double
    let takes: Int?
    let similarity: Double?
    let match: Double?   // 0–1, how close to the real voice
    let intelligibility: Double?
    let language_matched: Bool?
}

struct EnhanceResult: Codable {
    let path: String
    let duration_s: Double
    let before_lufs: Double?
    let after_lufs: Double?
}

struct VoiceAPIConfig: Codable {
    var enabled = false
    var key = ""
}

@MainActor @Observable final class VoiceEngine {
    static let shared = VoiceEngine()
    enum Phase: Equatable { case idle, settingUp, starting, ready, failed(String) }

    nonisolated static let port = 8180
    nonisolated static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Kitflo")
    nonisolated static let env = support.appending(path: "voice-env")
    nonisolated static let python = env.appending(path: "bin/python")
    nonisolated static let outDir = support.appending(path: "voice-out")
    nonisolated static let tmpDir = support.appending(path: "voice-tmp")
    nonisolated static let apiFile = support.appending(path: "voice-api.json")
    nonisolated static let logFile = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Logs/Kitflo-voice.log")
    let base = URL(string: "http://127.0.0.1:\(VoiceEngine.port)")!
    /// Fresh secret each launch so websites in your browser can't use the local sidecar.
    let appKey = UUID().uuidString

    var phase = Phase.idle
    var message = ""
    var installed = FileManager.default.isExecutableFile(atPath: VoiceEngine.python.path)
    var pro: ProRun?             // current Pro scan or training; polled here so it survives closing the sheet
    var proLoss: [Double] = []
    var proError: String?
    var training = false         // the engine is fine-tuning a voice: speaking is paused
    var voices: [VoiceProfile] = []
    var languages: [VoiceLang] = []
    var api = VoiceEngine.loadAPI()
    @ObservationIgnored private var proc: Process?
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var lastUse = Date()
    @ObservationIgnored private var inflight = 0
    @ObservationIgnored var jobs = 0   // polled jobs (speak, training) between their short requests
    @ObservationIgnored private var lastVisible = Date()

    // MARK: Install and lifecycle

    /// Repo `voice/` when running from `swift run`, the app bundle's copy otherwise.
    static var dir: URL? {
        var c = [Bundle.main.resourceURL?.appending(path: "voice")].compactMap { $0 }
        var up = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<6 { if let u = up { c.append(u.appending(path: "voice")); up = u.deletingLastPathComponent() } }
        c.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "voice"))
        return c.first { FileManager.default.fileExists(atPath: $0.appending(path: "pyproject.toml").path) }
    }

    nonisolated static func findUV() -> String? {
        let home = NSHomeDirectory()
        var paths = ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        let (code, out) = runSync("/usr/bin/which", ["uv"])
        if code == 0 { paths.append(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func runSync(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    /// Runs a tool, passing each output line (stdout and stderr) to `line`; returns exit code and the last bit of output.
    nonisolated static func run(_ exe: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil,
                                line: @escaping @Sendable (String) -> Void) async -> (Int32, String) {
        final class Tail: @unchecked Sendable {
            private let lock = NSLock()
            private var s = ""
            func add(_ t: String) { lock.lock(); s = String((s + t).suffix(600)); lock.unlock() }
            var text: String { lock.lock(); defer { lock.unlock() }; return s }
        }
        let tail = Tail(), p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        if let env { p.environment = env }
        p.standardOutput = pipe
        p.standardError = pipe
        let eat: @Sendable (Data) -> Void = { d in
            let text = String(decoding: d, as: UTF8.self)
            tail.add(text)
            // uv redraws progress with \r; show the latest non-empty piece.
            if let l = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last, !l.trimmingCharacters(in: .whitespaces).isEmpty { line(String(l)) }
        }
        pipe.fileHandleForReading.readabilityHandler = { h in eat(h.availableData) }
        return await withCheckedContinuation { c in
            p.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                eat(pipe.fileHandleForReading.readDataToEndOfFile())
                c.resume(returning: (p.terminationStatus, tail.text))
            }
            do { try p.run() } catch { c.resume(returning: (-1, error.localizedDescription)) }
        }
    }

    private func fail(_ m: String) { phase = .failed(m) }

    /// One-time install of the Python engine (uv sync into voice-env). Models download on first use.
    func setup() async {
        guard phase != .settingUp else { return }
        phase = .settingUp
        guard let dir = Self.dir else { return fail("Kitflo can't find its voice files. Reinstall the app and try again.") }
        message = "Looking for uv…"
        var uv = Self.findUV()
        if uv == nil {
            guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return fail("Kitflo needs the free tool “uv” to install the voice engine. Install Homebrew from brew.sh (or run the installer at astral.sh/uv), then press Set up voice again.")
            }
            message = "Installing uv with Homebrew…"
            _ = await Self.run(brew, ["install", "uv"]) { l in Task { @MainActor in self.message = l } }
            uv = Self.findUV()
            if uv == nil { return fail("Homebrew couldn't install uv. Run “brew install uv” in Terminal to see why, then try again.") }
        }
        message = "Installing the Python engine (about 2.5 GB). This takes a few minutes…"
        var e = ProcessInfo.processInfo.environment
        e["UV_PROJECT_ENVIRONMENT"] = Self.env.path
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        let (code, tail) = await Self.run(uv!, ["sync", "--frozen", "--no-install-project", "--managed-python"], cwd: dir, env: e) { l in
            Task { @MainActor in self.message = l }
        }
        guard code == 0 else {
            try? FileManager.default.removeItem(at: Self.env)   // a half-built environment would look installed
            let why = tail.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? ""
            return fail("The install didn't finish. Check your internet connection and free disk space (about 8 GB), then try again. \(why)")
        }
        installed = FileManager.default.isExecutableFile(atPath: Self.python.path)
        phase = .idle
        start()
    }

    func startIfEnabled() { if api.enabled, installed { start() } }

    /// Starts the sidecar (if it isn't running) and follows /health until the model is loaded.
    func start() {
        guard installed, !polling, phase != .ready, phase != .settingUp else { return }
        guard let dir = Self.dir else { return fail("Kitflo can't find its voice files. Reinstall the app and try again.") }
        polling = true
        lastUse = Date(); lastVisible = Date()
        phase = .starting
        message = "Starting voice engine…"
        if proc?.isRunning != true { launch(dir) }
        Task {
            defer { polling = false }
            while true {
                if proc?.isRunning != true { return fail("The voice engine stopped unexpectedly. Details are in ~/Library/Logs/Kitflo-voice.log.") }
                if let h = await health() {
                    if h.status == "ready" { phase = .ready; await reload(); watchIdle(); return }
                    if h.status == "training" { phase = .ready; training = true; await reload(); watchIdle(); return }
                    if h.status == "error" { return fail(h.error ?? "The voice model couldn't load. Details are in ~/Library/Logs/Kitflo-voice.log.") }
                    message = "Loading the voice model… the first start downloads 3.3 GB."
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// A sidecar left over from a crash holds the port with an old key; kill it and wait (up to 3 s) for it to go.
    nonisolated static func killStale() {
        let pattern = "voice-env/bin/python -I .*voice/server.py --port \(port)"
        _ = runSync("/usr/bin/pkill", ["-f", pattern])
        for _ in 0..<30 where runSync("/usr/bin/pgrep", ["-f", pattern]).0 == 0 { Thread.sleep(forTimeInterval: 0.1) }
    }

    /// Recordings and extracted video audio are private; delete them as soon as they've been used.
    nonisolated static func discardTemp(_ path: String) {
        let u = URL(fileURLWithPath: path)
        guard u.deletingLastPathComponent().standardizedFileURL == tmpDir.standardizedFileURL,
              u.lastPathComponent.hasPrefix("rec-") || u.lastPathComponent.hasPrefix("video-") else { return }
        try? FileManager.default.removeItem(at: u)
    }

    /// With the API off, the ~5 GB engine stops after 3 idle minutes, or 60 s after you leave the Voice page
    /// (never mid-request or mid-job), and starts again on next use.
    private func watchIdle() {
        Task {
            while phase == .ready {
                try? await Task.sleep(for: .seconds(10))
                if let h = await health() { training = h.status == "training" || (pro?.kind == .train && pro?.running == true) }
                let onPage = Store.shared.page == .voice && NSApp.windows.contains { $0.title == "Kitflo" && $0.isVisible }
                if onPage { lastVisible = Date() }
                guard !api.enabled, !training, inflight == 0, jobs == 0 else { continue }
                if Date().timeIntervalSince(lastUse) > 180 || Date().timeIntervalSince(lastVisible) > 60 { stop(); return }
            }
        }
    }

    /// Memory the sidecar is using (phys_footprint, what Activity Monitor shows).
    func memoryBytes() -> UInt64? {
        guard let pid = proc?.processIdentifier, proc?.isRunning == true else { return nil }
        var ru = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &ru) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
        return r == 0 ? ru.ri_phys_footprint : nil
    }

    private func launch(_ dir: URL) {
        Self.killStale()
        try? FileManager.default.removeItem(at: Self.tmpDir)
        for d in [Self.outDir, Self.tmpDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let p = Process()
        p.executableURL = Self.python
        p.arguments = ["-I", dir.appending(path: "server.py").path, "--port", "\(Self.port)", "--data", Self.support.path]
        var e = ProcessInfo.processInfo.environment
        e["KITFLO_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)   // the sidecar exits if Kitflo dies
        e["KITFLO_APP_KEY"] = appKey   // env, not argv: other local processes can read argv with ps
        p.environment = e
        FileManager.default.createFile(atPath: Self.logFile.path, contents: nil)
        let log = try? FileHandle(forWritingTo: Self.logFile)
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        do { try p.run() } catch { return fail("The voice engine couldn't start: \(error.localizedDescription)") }
        proc = p
    }

    func stop() {
        proc?.terminate()
        proc = nil
        if phase != .settingUp { phase = .idle }
    }

    struct Health: Codable { let status: String; let error: String?; let proof: String? }

    /// nil unless the answer comes from the engine Kitflo started: it must sign a fresh nonce with our per-launch key,
    /// so another process squatting on the port can't impersonate it and receive the key or recordings.
    func health() async -> Health? {
        let nonce = UUID().uuidString
        var req = URLRequest(url: base.appending(path: "health").appending(queryItems: [URLQueryItem(name: "nonce", value: nonce)]))
        req.timeoutInterval = 3
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let h = try? JSONDecoder().decode(Health.self, from: d) else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: SymmetricKey(data: Data(appKey.utf8)))
        let expected = mac.map { String(format: "%02x", $0) }.joined()
        return h.proof == expected ? h : nil
    }

    func ready() async -> Bool { await health()?.status == "ready" }

    func reload() async {
        if let l = try? await fetchLanguages() { languages = l }
        if let v = try? await fetchVoices() {
            voices = v
            if !Store.shared.s.voiceID.isEmpty, !v.contains(where: { $0.id == Store.shared.s.voiceID }) { Store.shared.s.voiceID = "" }
        }
    }

    func name(_ code: String) -> String { code == "auto" ? "Auto" : languages.first { $0.code == code }?.name ?? code.uppercased() }

    // MARK: API key (the sidecar re-reads voice-api.json on every request)

    nonisolated static func loadAPI() -> VoiceAPIConfig {
        if let d = try? Data(contentsOf: apiFile), let c = try? JSONDecoder().decode(VoiceAPIConfig.self, from: d), !c.key.isEmpty { return c }
        return VoiceAPIConfig()   // no key and no file until the API tab is first shown
    }

    /// Created 0600 from the start (temp file, then rename), so the key is never readable by other users.
    nonisolated static func writeAPI(_ c: VoiceAPIConfig) {
        let fm = FileManager.default, tmp = apiFile.appendingPathExtension("tmp")
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? fm.removeItem(at: tmp)
        guard let d = try? JSONEncoder().encode(c),
              fm.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]) else { return }
        if fm.fileExists(atPath: apiFile.path) { _ = try? fm.replaceItemAt(apiFile, withItemAt: tmp) } else { try? fm.moveItem(at: tmp, to: apiFile) }
    }

    nonisolated static func newKey() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return "kf_" + String((0..<32).map { _ in chars.randomElement()! })
    }

    /// Creates and saves the key the first time it is needed (API tab shown, or the toggle turned on).
    func ensureKey() { if api.key.isEmpty { saveAPI() } }

    func saveAPI(enabled: Bool? = nil, regenerate: Bool = false) {
        if let enabled { api.enabled = enabled }
        if api.key.isEmpty { api.key = Self.newKey() }
        if regenerate { api.key = Self.newKey() }
        Self.writeAPI(api)
        if api.enabled { start() }
    }

    // MARK: Client

    private func raw(_ method: String, _ path: String, _ body: (any Encodable)? = nil, timeout: TimeInterval = 10800) async throws -> Data {
        var req = URLRequest(url: URL(string: base.absoluteString + path)!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("Bearer \(appKey)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        lastUse = Date(); inflight += 1
        defer { inflight -= 1; lastUse = Date() }
        let d: Data, r: URLResponse
        do { (d, r) = try await URLSession.shared.data(for: req) } catch let e as URLError {
            if proc?.isRunning != true, phase == .ready { phase = .idle; start() }   // heal after a crash
            throw VoiceError(message: e.code == .timedOut ? "The voice engine took too long. Try shorter text or the Fast preset."
                                                          : "Can't reach the voice engine. It may still be starting; wait a moment and try again.")
        }
        let status = (r as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
            throw VoiceError(message: msg ?? "The voice engine reported an error (HTTP \(status)).")
        }
        return d
    }

    private func call<T: Decodable>(_ method: String, _ path: String, _ body: (any Encodable)? = nil, timeout: TimeInterval = 10800) async throws -> T {
        let d = try await raw(method, path, body, timeout: timeout)
        do { return try JSONDecoder().decode(T.self, from: d) } catch { throw VoiceError(message: "The voice engine sent a reply Kitflo couldn't read. Update Kitflo and try again.") }
    }

    func fetchLanguages() async throws -> [VoiceLang] {
        struct R: Decodable { let languages: [VoiceLang] }
        let r: R = try await call("GET", "/languages", timeout: 10)
        return r.languages
    }

    func fetchVoices() async throws -> [VoiceProfile] {
        struct R: Decodable { let voices: [VoiceProfile] }
        let r: R = try await call("GET", "/voices", timeout: 30)
        return r.voices
    }

    struct VoiceBox: Decodable { let voice: VoiceProfile }

    func rename(_ id: String, to name: String) async throws {
        struct B: Encodable { let name: String }
        let _: VoiceBox = try await call("PATCH", "/voices/\(id)", B(name: name), timeout: 30)
        await reload()
    }

    func delete(_ id: String) async throws {
        _ = try await raw("DELETE", "/voices/\(id)", timeout: 30)
        await reload()
    }

    func deleteLanguage(_ id: String, _ code: String) async throws {
        let _: VoiceBox = try await call("DELETE", "/voices/\(id)/languages/\(code)", timeout: 30)
        await reload()
    }

    func preview(_ id: String, _ code: String) async throws -> Data {
        try await raw("GET", "/voices/\(id)/preview?lang=\(code)", timeout: 60)
    }

    func prepare(_ audioPath: String, language: String?) async throws -> Prepared {
        struct B: Encodable { let audio_path: String; let language: String? }
        defer { Self.discardTemp(audioPath) }
        return try await call("POST", "/voices/prepare", B(audio_path: audioPath, language: language))
    }

    func save(voiceID: String?, name: String, language: String, refPath: String, refText: String) async throws -> VoiceProfile {
        struct B: Encodable { let voice_id: String?; let name: String; let language: String; let ref_path: String; let ref_text: String; let consent = true }
        let r: VoiceBox = try await call("POST", "/voices/save", B(voice_id: voiceID, name: name, language: language, ref_path: refPath, ref_text: refText), timeout: 300)
        await reload()
        return r.voice
    }

    func train(voiceID: String?, name: String, language: String, audioPath: String) async throws -> String {
        struct B: Encodable { let voice_id: String?; let name: String; let language: String; let audio_path: String; let consent = true }
        struct R: Decodable { let job_id: String }
        let r: R = try await call("POST", "/voices/train", B(voice_id: voiceID, name: name, language: language, audio_path: audioPath))
        return r.job_id
    }

    func job(_ id: String) async throws -> VoiceJob { try await call("GET", "/jobs/\(id)", timeout: 30) }

    func speak(voiceID: String, language: String, text: String, preset: String, speed: Double) async throws -> SpeakResult {
        struct B: Encodable { let voice_id: String; let language: String; let text: String; let preset: String; let speed: Double }
        return try await call("POST", "/speak", B(voice_id: voiceID, language: language, text: text, preset: preset, speed: speed))
    }

    struct SpeakJob: Decodable {
        let state: String
        let progress: Double?
        let message: String?
        let result: SpeakResult?
        let error: String?
    }

    /// Long text or Studio: runs as a job so progress can be shown; same result as /speak.
    func speakJob(voiceID: String, language: String, text: String, preset: String, speed: Double,
                  progress: @escaping (Double?, String?) -> Void) async throws -> SpeakResult {
        struct B: Encodable { let voice_id: String; let language: String; let text: String; let preset: String; let speed: Double }
        struct R: Decodable { let job_id: String }
        let r: R = try await call("POST", "/speak/jobs", B(voice_id: voiceID, language: language, text: text, preset: preset, speed: speed), timeout: 60)
        jobs += 1
        defer { jobs -= 1 }
        while true {
            let j: SpeakJob = try await call("GET", "/jobs/\(r.job_id)", timeout: 30)
            progress(j.progress, j.message)
            if j.state == "done", let res = j.result { return res }
            if j.state == "failed" || j.state == "done" { throw VoiceError(message: j.error ?? "The voice engine couldn't finish this one. Try again, or use the Fast preset.") }
            try await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: Pro training (voice/PRO.md)

    private struct JobID: Decodable { let job_id: String }

    private func startPro(_ kind: ProRun.Kind, _ voiceID: String, _ path: String, _ body: any Encodable) {
        guard pro?.running != true else { return }
        pro = ProRun(kind: kind, voiceID: voiceID); proLoss = []; proError = nil
        jobs += 1   // keeps the idle / leave-page stop away while the job runs
        if kind == .train { training = true }
        Task {
            defer { jobs -= 1; if kind == .train { training = false } }
            do {
                let r: JobID = try await call("POST", path, body, timeout: 120)
                pro?.jobID = r.job_id
                while true {
                    let j: ProJob = try await call("GET", "/jobs/\(r.job_id)", timeout: 30)
                    pro?.job = j
                    if j.state == "running" {
                        if let l = j.detail?.loss, proLoss.count < 400 { proLoss.append(l) }
                        try await Task.sleep(for: .seconds(2))
                    } else { break }
                }
                await reload()
            } catch { proError = error.localizedDescription; pro = nil }
        }
    }

    func proScan(_ voiceID: String, folder: String) {
        struct B: Encodable { let voice_id: String; let folder: String }
        startPro(.scan, voiceID, "/pro/scan", B(voice_id: voiceID, folder: folder))
    }

    func proTrain(_ voiceID: String, dataset: String) {
        struct B: Encodable { let voice_id: String; let dataset_id: String }
        startPro(.train, voiceID, "/pro/train", B(voice_id: voiceID, dataset_id: dataset))
    }

    func proCancel() async {
        struct B: Encodable { let job_id: String }
        guard let id = pro?.jobID else { return }
        _ = try? await raw("POST", "/pro/cancel", B(job_id: id), timeout: 30)
    }

    func proEnable(_ id: String, _ on: Bool) async throws {
        struct B: Encodable { let enabled: Bool }
        let _: VoiceBox = try await call("POST", "/voices/\(id)/pro/enabled", B(enabled: on), timeout: 60)
        await reload()
    }

    func proRemove(_ id: String) async throws {
        let _: VoiceBox = try await call("DELETE", "/voices/\(id)/pro", timeout: 60)
        await reload()
    }

    /// Loads a voice's prompt in the background so the first Generate is fast. Errors are ignored.
    func warm(_ id: String, _ language: String) async {
        struct B: Encodable { let language: String }
        _ = try? await raw("POST", "/voices/\(id)/warm", B(language: language), timeout: 600)
    }

    func enhance(_ audioPath: String, level: String) async throws -> EnhanceResult {
        struct B: Encodable { let audio_path: String; let level: String }
        return try await call("POST", "/enhance", B(audio_path: audioPath, level: level))
    }

    /// Newest generated and enhanced files in voice-out.
    func recent() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.outDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.filter { $0.pathExtension == "wav" }.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        return dated.sorted { $0.1 > $1.1 }.prefix(10).map(\.0)
    }

    // MARK: --voice-selftest

    func selfTest() async -> Bool {
        func report(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL") \(what)") }
        guard installed else { report(false, "voice engine not installed (open Kitflo → Voice → Set up voice)"); return false }
        start()
        for _ in 0..<900 where !(await ready()) {
            if case .failed(let m) = phase { report(false, "engine: \(m)"); return false }
            try? await Task.sleep(for: .seconds(1))
        }
        let up = await ready()
        report(up, "health ready")
        guard up else { return false }
        guard let langs = try? await fetchLanguages(), langs.contains(where: { $0.code == "en" }) else { report(false, "languages"); return false }
        report(true, "languages (\(langs.count))")
        do {
            let r = try await speak(voiceID: "", language: "en", text: "Kitflo voice self test.", preset: "fast", speed: 1.0)
            let ok = FileManager.default.fileExists(atPath: r.path) && r.duration_s > 0.3
            report(ok, "speak \(String(format: "%.1f", r.duration_s)) s → \(r.path)")
            return ok
        } catch { report(false, "speak: \(error.localizedDescription)"); return false }
    }
}
