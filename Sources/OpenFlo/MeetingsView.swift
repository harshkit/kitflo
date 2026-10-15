import AppKit
import SwiftUI

/// The Notes tab: record a meeting (audio, screen, camera), get who-said-what and AI notes.
struct MeetingsPage: View {
    @Bindable var store = Store.shared
    var body: some View {
        if let i = store.s.meetings.firstIndex(where: { $0.id == store.meetingID }) {
            MeetingDetail(index: i)
        } else {
            VStack(alignment: .leading, spacing: 22) {
                Title(text: "Notes", sub: "Record a meeting, call or anything on screen. OpenFlo works out who said what and writes the notes, all on this Mac.")
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
    @State private var mode: RecordMode = .audio
    @State private var source: CaptureSource = .screen
    @State private var micOn = true
    @State private var systemOn = true
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if rec.recording { live } else { setup }
            if let e = rec.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                if e.contains("Screen Recording") {
                    Button("Open Screen Recording settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.paper))
        .task { await rec.refreshSources() }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ForEach(RecordMode.allCases) { m in
                    Button { mode = m } label: {
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
            HStack {
                Text("Record from")
                Menu(source.label) {
                    Button("Entire screen") { source = .screen }
                    Menu("An app (e.g. Zoom)") { ForEach(rec.apps) { a in Button(a.label) { source = a } } }
                    Menu("A window (e.g. one browser window)") { ForEach(rec.windows) { w in Button(w.label) { source = w } } }
                    Divider()
                    Button("Refresh list") { Task { await rec.refreshSources() } }
                }
                .frame(maxWidth: 320)
                Spacer()
            }
            HStack(spacing: 24) {
                Toggle("Microphone (you)", isOn: $micOn)
                Toggle("System audio (others)", isOn: $systemOn)
            }
            .toggleStyle(.switch)
            if case .window = source {
                Text("Tip: to record one browser tab, pick the window that has that tab open.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    starting = true
                    Task { await rec.start(mode: mode, source: source, micOn: micOn, systemOn: systemOn); starting = false }
                } label: {
                    Label(starting ? "Starting…" : "Start recording", systemImage: "record.circle.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(Capsule().fill(Color.primary))
                }
                .buttonStyle(.plain)
                .disabled(starting || (!micOn && !systemOn))
                Text(mode == .audio ? "Saves audio + transcript + notes" : "Saves video to ~/Movies/OpenFlo + transcript + notes")
                    .font(.caption).foregroundStyle(.secondary)
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
    let index: Int
    @State private var tab = 0

    private var m: Meeting { store.s.meetings[index] }

    var body: some View {
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
            TextField("Title", text: $store.s.meetings[index].title)
                .font(.system(size: 28, design: .serif)).textFieldStyle(.plain)
            Text("\(m.date.formatted(date: .abbreviated, time: .shortened)) · \(MeetingNotes.clock(m.duration)) · \(m.mode.rawValue) · \(m.source)")
                .font(.callout).foregroundStyle(.secondary)
            if let status = m.status {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(status) }.foregroundStyle(.secondary)
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
