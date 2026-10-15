import Foundation
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
}

struct Note: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var text = ""
    var title: String { text.split(separator: "\n").first.map(String.init) ?? "New note" }
}

struct Saved: Codable {
    var history: [Entry] = []
    var words: [String] = []
    var snippets: [Snippet] = []
    var notes: [Note] = []
    var style: Style = .casual
    var hotkey: Hotkey = .fn
    var aiCleanup = true
    var language = "en-IN"
    var sounds = true

    init() {}

    // Every field is optional on disk so adding a setting never wipes an older store.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        history = try c.decodeIfPresent([Entry].self, forKey: .history) ?? []
        words = try c.decodeIfPresent([String].self, forKey: .words) ?? []
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .casual
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? .fn
        aiCleanup = try c.decodeIfPresent(Bool.self, forKey: .aiCleanup) ?? true
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en-IN"
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? true
    }
}

@Observable final class Store {
    static let shared = Store()
    var page: Page = .home        // not saved: which screen the main window shows
    var noteID: UUID?
    var s = Saved() { didSet { save() } }

    @ObservationIgnored private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "OpenFlo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "store.json")
    }()

    init() {
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(Saved.self, from: d) { s = v }
    }

    func newNote() {
        let n = Note()
        s.notes.insert(n, at: 0)
        noteID = n.id
        page = .notes
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
