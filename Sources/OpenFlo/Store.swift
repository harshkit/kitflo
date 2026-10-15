import AppKit
import Observation

struct Entry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var raw: String
    var text: String
    var app: String
    var seconds: Double
    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

enum Style: String, Codable, CaseIterable, Identifiable {
    case formal = "Formal", casual = "Casual", veryCasual = "Very casual"
    var id: String { rawValue }
    var hint: String {
        switch self {
        case .formal: "Proper capitalization and full punctuation. Polished and professional."
        case .casual: "Normal capitalization and punctuation, friendly and natural."
        case .veryCasual: "Lowercase is fine, minimal punctuation, like texting a friend."
        }
    }
}

enum Hotkey: String, Codable, CaseIterable, Identifiable {
    case fn = "fn (Globe)", rightOption = "Right ⌥ Option", rightCommand = "Right ⌘ Command"
    var id: String { rawValue }
    var keyCode: UInt16 { switch self { case .fn: 63; case .rightOption: 61; case .rightCommand: 54 } }

    /// True when this exact key is held. Uses the right-hand device bits so the left Option/Command key
    /// can't make a right-hand hotkey look "still down" (which kept the mic open).
    func isDown(_ flags: UInt64) -> Bool {
        switch self {
        case .fn: flags & UInt64(NSEvent.ModifierFlags.function.rawValue) != 0
        case .rightOption: flags & 0x40 != 0    // NX_DEVICERALTKEYMASK
        case .rightCommand: flags & 0x10 != 0   // NX_DEVICERCMDKEYMASK
        }
    }
}

enum Engine: String, Codable, CaseIterable, Identifiable {
    case apple, parakeet
    var id: String { rawValue }
    var label: String { self == .apple ? "Apple (built in)" : "Parakeet (more accurate, uses your Dictionary)" }
}

enum RecordMode: String, Codable, CaseIterable, Identifiable {
    case audio = "Audio only", screen = "Audio + Screen", camera = "Audio + Screen + Camera"
    var id: String { rawValue }
    var icon: String { switch self { case .audio: "mic"; case .screen: "display"; case .camera: "video" } }
}

struct Segment: Codable, Hashable {
    var speaker: String
    var start: Double
    var text: String
}

struct Meeting: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var title = "Untitled recording"
    var duration: Double = 0
    var mode: RecordMode = .audio
    var source = "Entire screen"
    var segments: [Segment] = []
    var notes = ""
    var file: String?          // recording on disk (~/Movies/OpenFlo)
    var status: String?        // non-nil while OpenFlo is still processing it
    var screenText: String?    // text read from the screen while recording, used for the notes
}

struct Saved: Codable {
    var history: [Entry] = []
    var words: [String] = []
    var snippets: [Snippet] = []
    var meetings: [Meeting] = []
    var recordingsFolder: String?   // nil = ~/Movies/OpenFlo
    var recordMode: RecordMode = .screen
    var style: Style = .casual
    var hotkey: Hotkey = .fn
    var aiCleanup = true
    var language = "en-IN"
    var sounds = true
    var engine: Engine = .parakeet

    init() {}

    // Every field is optional on disk so adding a setting never wipes an older store.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        history = try c.decodeIfPresent([Entry].self, forKey: .history) ?? []
        words = try c.decodeIfPresent([String].self, forKey: .words) ?? []
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        meetings = try c.decodeIfPresent([Meeting].self, forKey: .meetings) ?? []
        recordingsFolder = try c.decodeIfPresent(String.self, forKey: .recordingsFolder)
        recordMode = try c.decodeIfPresent(RecordMode.self, forKey: .recordMode) ?? .screen
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .casual
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? .fn
        aiCleanup = try c.decodeIfPresent(Bool.self, forKey: .aiCleanup) ?? true
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en-IN"
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? true
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? .parakeet
    }
}

/// Plain-text diagnostics at ~/Library/Logs/OpenFlo.log (permission states, recording start/stop, errors). No speech or text.
enum Log {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Logs/OpenFlo.log")
    static func write(_ line: String) {
        let entry = "\(Date().formatted(.iso8601)) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close() }
        else { try? Data(entry.utf8).write(to: url) }
    }
}

@Observable final class Store {
    static let shared = Store()
    var page: Page = .home        // not saved: which screen the main window shows
    var meetingID: UUID?
    var s = Saved() { didSet { save() } }

    @ObservationIgnored private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "OpenFlo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "store.json")
    }()

    init() {
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(Saved.self, from: d) { s = v }
    }

    /// True when the 🌐/fn key still triggers a macOS action on release (emoji picker, input switch),
    /// which steals focus from the text field right before OpenFlo pastes.
    var fnKeyConflicts: Bool {
        (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int ?? 2) != 0
    }

    private func save() {
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }

    // Stats for the Home screen
    var weekWords: Int {
        let since = Date().addingTimeInterval(-7 * 86400)
        return s.history.filter { $0.date > since }.reduce(0) { $0 + $1.words }
    }
    var wpm: Int {
        let secs = s.history.reduce(0) { $0 + $1.seconds }
        return secs > 0 ? Int(Double(s.history.reduce(0) { $0 + $1.words }) / secs * 60) : 0
    }
    var streak: Int {
        let cal = Calendar.current
        let days = Set(s.history.map { cal.startOfDay(for: $0.date) })
        var d = cal.startOfDay(for: Date()), n = 0
        while days.contains(d) { n += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
        return n
    }
}
