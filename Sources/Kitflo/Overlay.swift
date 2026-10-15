import AppKit
import SwiftUI

/// The little pill that floats at the bottom of the screen.
final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: PillView())
        reposition()
        orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.reposition() }
    }

    override var canBecomeKey: Bool { false }

    func reposition() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.minY + 10))
    }
}

struct PillView: View {
    let flow = Flow.shared

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                switch flow.phase {
                case .idle where MeetingRecorder.shared.recording && flow.toast == nil:
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("REC").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                case .idle:
                    if let t = flow.toast {
                        Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1).fixedSize()
                    }
                case .listening:
                    if flow.locked {
                        Button { flow.cancel() } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        }.buttonStyle(.plain)
                    }
                    Bars(levels: flow.levels)
                    if flow.locked { Circle().fill(.red).frame(width: 7, height: 7) }
                case .thinking:
                    Dots()
                }
            }
            .padding(.horizontal, compact ? 0 : 14)
            .frame(width: flow.toast != nil && flow.phase == .idle ? nil : width, height: compact ? 6 : 34)
            .background(Capsule().fill(.black.opacity(compact ? 0.35 : 0.92)))
            .overlay(Capsule().strokeBorder(.white.opacity(compact ? 0.25 : 0.15), lineWidth: 1))
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: flow.toast)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: flow.phase)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: flow.locked)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 4)
    }

    private var compact: Bool { flow.phase == .idle && flow.toast == nil && !MeetingRecorder.shared.recording }

    private var width: CGFloat {
        switch flow.phase {
        case .idle: MeetingRecorder.shared.recording ? 70 : 44
        case .listening: flow.locked ? 172 : 140
        case .thinking: 84
        }
    }
}

struct Bars: View {
    let levels: [Float]
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(.white)
                    .frame(width: 2.5, height: 3 + CGFloat(levels[i]) * 18)
                    .animation(.easeOut(duration: 0.08), value: levels[i])
            }
        }
    }
}

struct Dots: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(.white)
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * (0.5 + 0.5 * sin(t * 6 - Double(i) * 0.9)))
                }
            }
        }
    }
}
